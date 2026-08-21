const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    RouteConflict,
    DbFailed,
    OutOfMemory,
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

fn transient() c.sqlite3_destructor_type {
    return @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
}

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
    const rc = c.sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), transient());
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
        return store;
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
