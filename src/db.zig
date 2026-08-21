const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    RouteConflict,
    NameTaken,
    PortTaken,
    DbFailed,
    OutOfMemory,
};

pub const App = struct {
    id: i64,
    name: []const u8,
    port: u16,
    category: []const u8,
    created_at: i64,
};

pub const TagColor = struct {
    category: []const u8,
    color: []const u8,
};

pub const Route = struct {
    hostname: []const u8,
    port: u16,
    pid: i32,
    created_at: i64,
};

const schema_sql =
    \\CREATE TABLE IF NOT EXISTS routes(
    \\  hostname TEXT PRIMARY KEY,
    \\  port INTEGER NOT NULL,
    \\  pid INTEGER NOT NULL,
    \\  created_at INTEGER NOT NULL
    \\) STRICT, WITHOUT ROWID;
;

/// SQLITE_TRANSIENT is ((void*)-1), which no Zig pointer type can hold on
/// aarch64 without tripping alignment checks. Declaring the bind with an
/// isize destructor slot keeps the ABI honest and the cast trivial.
const transient_sentinel: isize = -1;

extern fn sqlite3_bind_text(
    stmt: ?*c.sqlite3_stmt,
    idx: c_int,
    data: [*]const u8,
    byte_len: c_int,
    destructor: isize,
) c_int;

fn diag(db: ?*c.sqlite3) []const u8 {
    const msg = c.sqlite3_errmsg(db);
    if (msg == null) return "unknown";
    return std.mem.span(msg);
}

fn check(rc: c_int, db: ?*c.sqlite3) Error!void {
    if (rc == c.SQLITE_OK or rc == c.SQLITE_DONE or rc == c.SQLITE_ROW) return;
    std.debug.print("berth: sqlite: {s}\n", .{diag(db)});
    return error.DbFailed;
}

fn bindText(stmt: ?*c.sqlite3_stmt, idx: c_int, text: []const u8) Error!void {
    const rc = sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), transient_sentinel);
    if (rc != c.SQLITE_OK) return error.DbFailed;
}

fn columnText(stmt: ?*c.sqlite3_stmt, idx: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, idx);
    if (ptr == null) return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

fn pidAlive(pid: i32) bool {
    switch (@import("builtin").os.tag) {
        .windows => return false,
        else => {},
    }
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}

pub fn dataDirPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".berth" });
}

pub fn defaultDbPath(allocator: std.mem.Allocator, home: []const u8) ![:0]u8 {
    const dir = try dataDirPath(allocator, home);
    defer allocator.free(dir);
    return std.fs.path.joinZ(allocator, &.{ dir, "berth.db" });
}

/// Create <home>/.berth with 0700 so the state directory is private to
/// the user.
pub fn ensureDataDir(io: std.Io, gpa: std.mem.Allocator, home: []const u8) !void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "{s}/.berth", .{home});
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    switch (@import("builtin").os.tag) {
        .windows => {},
        else => {
            const dir_z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{dir}, 0);
            defer gpa.free(dir_z);
            if (std.c.chmod(dir_z.ptr, 0o700) != 0) return error.AccessDenied;
        },
    }
}

/// Ordered migrations from an empty database. Each runs inside a
/// transaction and is recorded in schema_migrations, so reopening applies
/// every entry at most once, in file order.
const migrations = [_][:0]const u8{
    \\CREATE TABLE IF NOT EXISTS apps(
    \\  id INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL,
    \\  port INTEGER NOT NULL UNIQUE,
    \\  category TEXT NOT NULL DEFAULT 'other',
    \\  created_at INTEGER NOT NULL
    \\) STRICT;
    ,
    \\CREATE TABLE IF NOT EXISTS tag_colors(
    \\  category TEXT PRIMARY KEY,
    \\  color TEXT NOT NULL
    \\) STRICT, WITHOUT ROWID;
    ,
    \\CREATE UNIQUE INDEX IF NOT EXISTS apps_name_unique
    \\  ON apps(name) WHERE name != '';
};

pub const Store = struct {
    handle: ?*c.sqlite3 = null,
    io: std.Io = undefined,

    /// Open (creating on demand) the database at path. The file is created
    /// 0600 before SQLite touches it; SQLite never widens existing perms.
    pub fn open(io: std.Io, path: [:0]const u8) Error!Store {
        const cwd = std.Io.Dir.cwd();
        if (cwd.openFile(io, path, .{ .mode = .read_write })) |f| {
            f.close(io);
        } else |_| {
            const perms: std.Io.File.Permissions = switch (@import("builtin").os.tag) {
                .windows => .default_file,
                else => .fromMode(0o600),
            };
            const f = cwd.createFile(io, path, .{
                .read = true,
                .truncate = false,
                .permissions = perms,
            }) catch return error.DbFailed;
            f.close(io);
        }

        var store = Store{ .io = io };
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_FULLMUTEX;
        const rc = c.sqlite3_open_v2(path.ptr, &store.handle, flags, null);
        if (rc != c.SQLITE_OK) {
            std.debug.print("berth: sqlite open: {s}\n", .{diag(store.handle)});
            return error.DbFailed;
        }
        store.exec(schema_sql) catch |err| {
            store.close();
            return err;
        };
        store.migrate() catch |err| {
            store.close();
            return err;
        };
        return store;
    }

    fn migrate(self: *Store) Error!void {
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS schema_migrations(
            \\  version INTEGER PRIMARY KEY,
            \\  applied_at INTEGER NOT NULL
            \\) STRICT, WITHOUT ROWID;
        );
        for (migrations, 1..) |sql, ver| {
            var seen: bool = false;
            {
                var stmt: ?*c.sqlite3_stmt = null;
                const rc = c.sqlite3_prepare_v2(
                    self.handle,
                    "SELECT 1 FROM schema_migrations WHERE version=?1",
                    -1,
                    &stmt,
                    null,
                );
                try check(rc, self.handle);
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_int64(stmt, 1, @intCast(ver));
                const step_rc = c.sqlite3_step(stmt);
                try check(step_rc, self.handle);
                seen = step_rc == c.SQLITE_ROW;
            }
            if (seen) continue;

            try self.exec("BEGIN IMMEDIATE");
            var committed: bool = false;
            defer if (!committed) self.exec("ROLLBACK") catch {};
            try self.exec(sql);
            {
                var stmt: ?*c.sqlite3_stmt = null;
                const rc = c.sqlite3_prepare_v2(
                    self.handle,
                    "INSERT INTO schema_migrations(version,applied_at) VALUES(?1,?2)",
                    -1,
                    &stmt,
                    null,
                );
                try check(rc, self.handle);
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_int64(stmt, 1, @intCast(ver));
                _ = c.sqlite3_bind_int64(stmt, 2, std.Io.Clock.now(.real, self.io).toSeconds());
                try check(c.sqlite3_step(stmt), self.handle);
            }
            try self.exec("COMMIT");
            committed = true;
        }
    }

    pub fn close(self: *Store) void {
        _ = c.sqlite3_close_v2(self.handle);
        self.handle = null;
    }

    pub fn exec(self: *Store, sql: [:0]const u8) Error!void {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, &errmsg);
        if (errmsg != null) c.sqlite3_free(errmsg);
        try check(rc, self.handle);
    }

    /// Register hostname -> port held by pid. A row whose recorded process
    /// is still alive blocks registration with RouteConflict; a stale row
    /// (dead pid) is taken over silently with fresh values.
    pub fn insertRoute(self: *Store, hostname: []const u8, port: u16, pid: i32) Error!void {
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.handle, "SELECT pid FROM routes WHERE hostname=?1", -1, &stmt, null);
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, hostname);

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const holder_pid: i32 = c.sqlite3_column_int(stmt, 0);
            if (pidAlive(holder_pid)) return error.RouteConflict;
            _ = try self.updateRoute(hostname, port, pid);
            return;
        }
        try check(rc, self.handle);

        return self.writeNew(hostname, port, pid);
    }

    fn writeNew(self: *Store, hostname: []const u8, port: u16, pid: i32) Error!void {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            "INSERT INTO routes(hostname,port,pid,created_at) VALUES(?1,?2,?3,?4)",
            -1,
            &stmt,
            null,
        );
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, hostname);
        _ = c.sqlite3_bind_int(stmt, 2, @intCast(port));
        _ = c.sqlite3_bind_int(stmt, 3, pid);
        _ = c.sqlite3_bind_int64(stmt, 4, std.Io.Clock.now(.real, self.io).toSeconds());
        const step_rc = c.sqlite3_step(stmt);
        try check(step_rc, self.handle);
    }

    /// Overwrite port and pid for an existing hostname. Returns false when
    /// no row exists; callers wanting create-or-update semantics use
    /// insertRoute instead.
    pub fn updateRoute(self: *Store, hostname: []const u8, port: u16, pid: i32) Error!bool {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            "UPDATE routes SET port=?2,pid=?3 WHERE hostname=?1",
            -1,
            &stmt,
            null,
        );
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, hostname);
        _ = c.sqlite3_bind_int(stmt, 2, @intCast(port));
        _ = c.sqlite3_bind_int(stmt, 3, pid);
        const step_rc = c.sqlite3_step(stmt);
        try check(step_rc, self.handle);
        return c.sqlite3_changes(self.handle) > 0;
    }

    /// Copy the matching row into caller memory. hostname_out receives the
    /// stored hostname; the returned Route.hostname aliases hostname_out.
    pub fn lookupRoute(
        self: *Store,
        hostname_out: []u8,
        hostname: []const u8,
    ) Error!?Route {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            "SELECT hostname,port,pid,created_at FROM routes WHERE hostname=?1",
            -1,
            &stmt,
            null,
        );
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, hostname);

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc == c.SQLITE_DONE) return null;
        try check(step_rc, self.handle);

        const stored = columnText(stmt, 0);
        const n = @min(stored.len, hostname_out.len);
        @memcpy(hostname_out[0..n], stored[0..n]);
        return Route{
            .hostname = hostname_out[0..n],
            .port = @intCast(std.math.clamp(c.sqlite3_column_int(stmt, 1), 0, std.math.maxInt(u16))),
            .pid = c.sqlite3_column_int(stmt, 2),
            .created_at = c.sqlite3_column_int64(stmt, 3),
        };
    }

    /// All rows, hostnames duplicated into allocator-owned memory. Caller
    /// frees each Route.hostname then the returned slice.
    pub fn listRoutes(self: *Store, allocator: std.mem.Allocator) Error![]Route {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            "SELECT hostname,port,pid,created_at FROM routes ORDER BY hostname",
            -1,
            &stmt,
            null,
        );
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);

        var routes: std.ArrayList(Route) = .empty;
        while (true) {
            const step_rc = c.sqlite3_step(stmt);
            if (step_rc == c.SQLITE_DONE) break;
            try check(step_rc, self.handle);
            const stored = columnText(stmt, 0);
            const dup = try allocator.dupe(u8, stored);
            try routes.append(allocator, .{
                .hostname = dup,
                .port = @intCast(std.math.clamp(c.sqlite3_column_int(stmt, 1), 0, std.math.maxInt(u16))),
                .pid = c.sqlite3_column_int(stmt, 2),
                .created_at = c.sqlite3_column_int64(stmt, 3),
            });
        }
        return routes.toOwnedSlice(allocator);
    }

    // ---- apps registry ----

    /// Insert an app row and return its id. The database rejects duplicate
    /// ports (UNIQUE) and duplicate non-empty names (partial unique index);
    /// both surface as typed errors.
    pub fn insertApp(self: *Store, name: []const u8, port: u16, category: []const u8) Error!i64 {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            "INSERT INTO apps(name,port,category,created_at) VALUES(?1,?2,?3,?4)",
            -1,
            &stmt,
            null,
        );
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, name);
        _ = c.sqlite3_bind_int(stmt, 2, @intCast(port));
        try bindText(stmt, 3, category);
        _ = c.sqlite3_bind_int64(stmt, 4, std.Io.Clock.now(.real, self.io).toSeconds());
        const step_rc = c.sqlite3_step(stmt);
        if (step_rc == c.SQLITE_CONSTRAINT) return mapConstraint(self.handle);
        try check(step_rc, self.handle);
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    fn mapConstraint(db: ?*c.sqlite3) Error {
        const msg = diag(db);
        if (std.mem.indexOf(u8, msg, "name") != null) return error.NameTaken;
        if (std.mem.indexOf(u8, msg, "port") != null) return error.PortTaken;
        return error.DbFailed;
    }

    fn queryApp(
        self: *Store,
        sql: [:0]const u8,
        key_idx: c_int,
        key_text: ?[]const u8,
        key_port: ?u16,
        name_out: []u8,
        category_out: []u8,
    ) Error!?App {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null);
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);
        if (key_text) |t| try bindText(stmt, key_idx, t);
        if (key_port) |p| _ = c.sqlite3_bind_int(stmt, key_idx, @intCast(p));

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc == c.SQLITE_DONE) return null;
        try check(step_rc, self.handle);

        const name = columnText(stmt, 1);
        const n = @min(name.len, name_out.len);
        @memcpy(name_out[0..n], name[0..n]);

        const cat = columnText(stmt, 3);
        const cn = @min(cat.len, category_out.len);
        @memcpy(category_out[0..cn], cat[0..cn]);

        return App{
            .id = c.sqlite3_column_int64(stmt, 0),
            .name = name_out[0..n],
            .port = @intCast(std.math.clamp(c.sqlite3_column_int(stmt, 2), 0, std.math.maxInt(u16))),
            .category = category_out[0..cn],
            .created_at = c.sqlite3_column_int64(stmt, 4),
        };
    }

    pub fn findAppByPort(
        self: *Store,
        name_out: []u8,
        category_out: []u8,
        port: u16,
    ) Error!?App {
        return self.queryApp(
            "SELECT id,name,port,category,created_at FROM apps WHERE port=?1",
            1,
            null,
            port,
            name_out,
            category_out,
        );
    }

    pub fn findAppByName(
        self: *Store,
        name_out: []u8,
        category_out: []u8,
        name: []const u8,
    ) Error!?App {
        return self.queryApp(
            "SELECT id,name,port,category,created_at FROM apps WHERE name=?1",
            1,
            name,
            null,
            name_out,
            category_out,
        );
    }

    /// All app rows ordered by name; strings duplicated into
    /// allocator-owned memory. Caller frees each name/category then slice.
    pub fn listApps(self: *Store, allocator: std.mem.Allocator) Error![]App {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            "SELECT id,name,port,category,created_at FROM apps ORDER BY name",
            -1,
            &stmt,
            null,
        );
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);

        var apps: std.ArrayList(App) = .empty;
        while (true) {
            const step_rc = c.sqlite3_step(stmt);
            if (step_rc == c.SQLITE_DONE) break;
            try check(step_rc, self.handle);
            const name = try allocator.dupe(u8, columnText(stmt, 1));
            errdefer allocator.free(name);
            const cat = try allocator.dupe(u8, columnText(stmt, 3));
            errdefer allocator.free(cat);
            try apps.append(allocator, .{
                .id = c.sqlite3_column_int64(stmt, 0),
                .name = name,
                .port = @intCast(std.math.clamp(c.sqlite3_column_int(stmt, 2), 0, std.math.maxInt(u16))),
                .category = cat,
                .created_at = c.sqlite3_column_int64(stmt, 4),
            });
        }
        return apps.toOwnedSlice(allocator);
    }

    /// Overwrite name, port and category for an id. Returns false when the
    /// id does not exist.
    pub fn updateApp(self: *Store, id: i64, name: []const u8, port: u16, category: []const u8) Error!bool {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            "UPDATE apps SET name=?2,port=?3,category=?4 WHERE id=?1",
            -1,
            &stmt,
            null,
        );
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, id);
        try bindText(stmt, 2, name);
        _ = c.sqlite3_bind_int(stmt, 3, @intCast(port));
        try bindText(stmt, 4, category);
        const step_rc = c.sqlite3_step(stmt);
        if (step_rc == c.SQLITE_CONSTRAINT) return mapConstraint(self.handle);
        try check(step_rc, self.handle);
        return c.sqlite3_changes(self.handle) > 0;
    }

    /// Remove an app. Returns true when a row was deleted.
    pub fn deleteApp(self: *Store, id: i64) Error!bool {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, "DELETE FROM apps WHERE id=?1", -1, &stmt, null);
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, id);
        try check(c.sqlite3_step(stmt), self.handle);
        return c.sqlite3_changes(self.handle) > 0;
    }

    // ---- tag colors ----

    /// Upsert the color for a category.
    pub fn setTagColor(self: *Store, category: []const u8, color: []const u8) Error!void {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            "INSERT INTO tag_colors(category,color) VALUES(?1,?2) ON CONFLICT(category) DO UPDATE SET color=excluded.color",
            -1,
            &stmt,
            null,
        );
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, category);
        try bindText(stmt, 2, color);
        try check(c.sqlite3_step(stmt), self.handle);
    }

    /// Copy the stored color into color_out; null when unset.
    pub fn getTagColor(self: *Store, category: []const u8, color_out: []u8) Error!?[]const u8 {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            "SELECT color FROM tag_colors WHERE category=?1",
            -1,
            &stmt,
            null,
        );
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, category);
        const step_rc = c.sqlite3_step(stmt);
        if (step_rc == c.SQLITE_DONE) return null;
        try check(step_rc, self.handle);
        const stored = columnText(stmt, 0);
        const n = @min(stored.len, color_out.len);
        @memcpy(color_out[0..n], stored[0..n]);
        return color_out[0..n];
    }

    /// Every stored category color. Strings are duped; with an arena
    /// caller they need no individual frees.
    pub fn listTagColors(self: *Store, allocator: std.mem.Allocator) Error![]TagColor {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            "SELECT category,color FROM tag_colors ORDER BY category",
            -1,
            &stmt,
            null,
        );
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);

        var colors: std.ArrayList(TagColor) = .empty;
        while (true) {
            const step_rc = c.sqlite3_step(stmt);
            if (step_rc == c.SQLITE_DONE) break;
            try check(step_rc, self.handle);
            try colors.append(allocator, .{
                .category = try allocator.dupe(u8, columnText(stmt, 0)),
                .color = try allocator.dupe(u8, columnText(stmt, 1)),
            });
        }
        return colors.toOwnedSlice(allocator);
    }

    /// Remove a route. Returns true when a row was deleted.
    pub fn deleteRoute(self: *Store, hostname: []const u8) Error!bool {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, "DELETE FROM routes WHERE hostname=?1", -1, &stmt, null);
        try check(rc, self.handle);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, hostname);
        const step_rc = c.sqlite3_step(stmt);
        try check(step_rc, self.handle);
        return c.sqlite3_changes(self.handle) > 0;
    }
};

fn testDbPath(alloc: std.mem.Allocator, comptime name: []const u8) !struct { path: [:0]u8, dir: []u8 } {
    const io = std.testing.io;
    var seed: [8]u8 = undefined;
    io.random(&seed);
    var hex_buf: [16]u8 = undefined;
    for (seed, 0..) |byte, i| {
        hex_buf[i * 2] = "0123456789abcdef"[byte >> 4];
        hex_buf[i * 2 + 1] = "0123456789abcdef"[byte & 15];
    }
    const dir = try std.fmt.allocPrint(alloc, "/tmp/opencode/berth-test-{s}", .{hex_buf});
    errdefer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fmt.allocPrintSentinel(alloc, "{s}/" ++ name ++ ".db", .{dir}, 0);
    return .{ .path = path, .dir = dir };
}

fn cleanupTestDir(alloc: std.mem.Allocator, dir: []u8) void {
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    alloc.free(dir);
}

test "store crud cycle in temp file" {
    const alloc = std.testing.allocator;
    const t = try testDbPath(alloc, "crud");
    defer cleanupTestDir(alloc, t.dir);
    defer alloc.free(t.path);
    const db_path = t.path;

    var store = try Store.open(std.testing.io, db_path);
    defer store.close();

    try store.insertRoute("one.localhost", 4001, 111);
    try store.insertRoute("two.localhost", 4002, 222);

    var name_buf: [256]u8 = undefined;
    const hit = (try store.lookupRoute(&name_buf, "one.localhost")).?;
    try std.testing.expectEqualStrings("one.localhost", hit.hostname);
    try std.testing.expectEqual(@as(u16, 4001), hit.port);
    try std.testing.expectEqual(@as(i32, 111), hit.pid);
    try std.testing.expect(hit.created_at > 0);

    const miss = try store.lookupRoute(&name_buf, "ghost.localhost");
    try std.testing.expectEqual(@as(?Route, null), miss);

    try std.testing.expect(try store.updateRoute("two.localhost", 4022, 223));
    try std.testing.expect(!try store.updateRoute("ghost.localhost", 1, 1));

    const listed = try store.listRoutes(alloc);
    defer {
        for (listed) |r| alloc.free(r.hostname);
        alloc.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqualStrings("one.localhost", listed[0].hostname);
    try std.testing.expectEqual(@as(u16, 4022), listed[1].port);

    try std.testing.expect(try store.deleteRoute("one.localhost"));
    try std.testing.expect(!try store.deleteRoute("one.localhost"));
    const after = try store.listRoutes(alloc);
    defer {
        for (after) |r| alloc.free(r.hostname);
        alloc.free(after);
    }
    try std.testing.expectEqual(@as(usize, 1), after.len);
}

test "insert conflicts on live pid and takes over dead pid" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const t = try testDbPath(alloc, "conflict");
    defer cleanupTestDir(alloc, t.dir);
    defer alloc.free(t.path);
    const db_path = t.path;

    var store = try Store.open(std.testing.io, db_path);
    defer store.close();

    const own_pid: i32 = switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .macos => std.c.getpid(),
        else => return error.SkipZigTest,
    };

    try store.insertRoute("live.localhost", 4001, own_pid);
    try std.testing.expectError(error.RouteConflict, store.insertRoute("live.localhost", 5000, own_pid));

    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const dead_pid: i32 = @intCast(child.id.?);
    _ = try child.wait(std.testing.io);

    try store.insertRoute("stale.localhost", 4002, dead_pid);
    try store.insertRoute("stale.localhost", 5000, own_pid);
    var name_buf: [256]u8 = undefined;
    const taken = (try store.lookupRoute(&name_buf, "stale.localhost")).?;
    try std.testing.expectEqual(@as(u16, 5000), taken.port);
    try std.testing.expectEqual(own_pid, taken.pid);
}

test "db file created on demand with private permissions" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const t = try testDbPath(alloc, "perms");
    defer cleanupTestDir(alloc, t.dir);
    defer alloc.free(t.path);
    const db_path = t.path;

    var store = try Store.open(std.testing.io, db_path);
    defer store.close();

    const f = try std.Io.Dir.cwd().openFile(std.testing.io, db_path, .{ .mode = .read_only });
    defer f.close(std.testing.io);
    const st = try f.stat(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0o600), st.permissions.toMode() & 0o777);
}

test "migrations apply in order exactly once" {
    const alloc = std.testing.allocator;
    const t = try testDbPath(alloc, "migrate");
    defer cleanupTestDir(alloc, t.dir);
    defer alloc.free(t.path);
    const db_path = t.path;

    var store = try Store.open(std.testing.io, db_path);
    _ = try store.insertApp("survivor", 4100, "web");
    store.close();

    // Reopen: runner must skip applied versions, data must survive.
    store = try Store.open(std.testing.io, db_path);
    defer store.close();

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(
        store.handle,
        "SELECT version FROM schema_migrations ORDER BY version",
        -1,
        &stmt,
        null,
    );
    try check(rc, store.handle);
    var versions: [8]i64 = undefined;
    var count: usize = 0;
    while (true) {
        const step_rc = c.sqlite3_step(stmt);
        if (step_rc == c.SQLITE_DONE) break;
        try check(step_rc, store.handle);
        versions[count] = c.sqlite3_column_int64(stmt, 0);
        count += 1;
    }
    _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(migrations.len, count);
    for (versions[0..count], 0..) |v, i| try std.testing.expectEqual(@as(i64, @intCast(i + 1)), v);

    var name_buf: [256]u8 = undefined;
    var cat_buf: [64]u8 = undefined;
    const found = (try store.findAppByName(&name_buf, &cat_buf, "survivor")).?;
    try std.testing.expectEqual(@as(u16, 4100), found.port);
}

test "duplicate non-empty name rejected at db level, empty names allowed" {
    const alloc = std.testing.allocator;
    const t = try testDbPath(alloc, "uniqname");
    defer cleanupTestDir(alloc, t.dir);
    defer alloc.free(t.path);
    const db_path = t.path;

    var store = try Store.open(std.testing.io, db_path);
    defer store.close();

    _ = try store.insertApp("api", 4201, "web");
    try std.testing.expectError(error.NameTaken, store.insertApp("api", 4202, "cli"));

    // Empty names bypass the partial index.
    _ = try store.insertApp("", 4203, "other");
    _ = try store.insertApp("", 4204, "other");

    // Port uniqueness is separate from name uniqueness.
    try std.testing.expectError(error.PortTaken, store.insertApp("other-app", 4201, "web"));
}

test "app crud find by port and by name plus tag colors" {
    const alloc = std.testing.allocator;
    const t = try testDbPath(alloc, "apps");
    defer cleanupTestDir(alloc, t.dir);
    defer alloc.free(t.path);
    const db_path = t.path;

    var store = try Store.open(std.testing.io, db_path);
    defer store.close();

    const id1 = try store.insertApp("frontend", 4301, "web");
    const id2 = try store.insertApp("backend", 4302, "api");

    var name_buf: [256]u8 = undefined;
    var cat_buf: [64]u8 = undefined;

    const by_port = (try store.findAppByPort(&name_buf, &cat_buf, 4302)).?;
    try std.testing.expectEqualStrings("backend", by_port.name);
    try std.testing.expectEqual(id2, by_port.id);

    const by_name = (try store.findAppByName(&name_buf, &cat_buf, "frontend")).?;
    try std.testing.expectEqualStrings("web", by_name.category);
    try std.testing.expectEqual(@as(u16, 4301), by_name.port);

    try std.testing.expectEqual(@as(?App, null), try store.findAppByPort(&name_buf, &cat_buf, 4999));
    try std.testing.expectEqual(@as(?App, null), try store.findAppByName(&name_buf, &cat_buf, "ghost"));

    // Default category when inserted without one is enforced by schema;
    // here we verify update + list + delete round trip.
    try std.testing.expect(try store.updateApp(id1, "front", 4301, "ui"));
    try std.testing.expect(!try store.updateApp(99999, "x", 1, "y"));
    try std.testing.expectError(error.PortTaken, store.updateApp(id1, "front", 4302, "ui"));

    const listed = try store.listApps(alloc);
    defer {
        for (listed) |a| {
            alloc.free(a.name);
            alloc.free(a.category);
        }
        alloc.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqualStrings("back", listed[0].name[0..4]);
    try std.testing.expectEqualStrings("front", listed[1].name);

    try std.testing.expect(try store.deleteApp(id2));
    try std.testing.expect(!try store.deleteApp(id2));

    // Tag colors upsert cleanly.
    try std.testing.expectEqual(@as(?[]const u8, null), try store.getTagColor("web", &cat_buf));
    try store.setTagColor("web", "#047857");
    try store.setTagColor("web", "#111111");
    const color = (try store.getTagColor("web", &cat_buf)).?;
    try std.testing.expectEqualStrings("#111111", color);
    try std.testing.expectEqual(@as(?[]const u8, null), try store.getTagColor("unset", &cat_buf));
}
