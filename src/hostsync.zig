const std = @import("std");
const routes_mod = @import("routes.zig");

pub const start_marker = "# berth-start";
pub const end_marker = "# berth-end";

pub const Outcome = enum { synced, unchanged, opted_out, unsupported_platform };

pub const Error = error{
    NotWritable,
    OutOfMemory,
};

/// The managed block: one 127.0.0.1 line per hostname, wrapped in the
/// marker comments that make cleanup safe.
pub fn buildBlock(allocator: std.mem.Allocator, hostnames: []const []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, start_marker ++ "\n");
    for (hostnames) |h| {
        try out.appendSlice(allocator, "127.0.0.1 ");
        try out.appendSlice(allocator, h);
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, end_marker ++ "\n");
    return out.toOwnedSlice(allocator);
}

fn isMarkerLine(line: []const u8, marker: []const u8) bool {
    return std.mem.eql(u8, line, marker);
}

/// Splice `block` into `contents`, removing any previous berth block.
/// Everything outside the markers survives byte-for-byte.
pub fn applyBlock(
    allocator: std.mem.Allocator,
    contents: []const u8,
    block: []const u8,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var it = std.mem.splitScalar(u8, contents, '\n');
    var in_block = false;
    var saw_block = false;
    var pending_line: ?[]const u8 = null;

    while (it.next()) |line| {
        if (!in_block and isMarkerLine(line, start_marker)) {
            if (pending_line) |pl| {
                if (pl.len > 0) {
                    try out.appendSlice(allocator, pl);
                    try out.appendSlice(allocator, "\n");
                }
                pending_line = null;
            }
            trimTrailingNewlines(&out);
            if (out.items.len > 0) try out.appendSlice(allocator, "\n\n");
            try out.appendSlice(allocator, block);
            in_block = true;
            saw_block = true;
            continue;
        }
        if (in_block) {
            if (isMarkerLine(line, end_marker)) in_block = false;
            continue;
        }
        if (pending_line) |pl| {
            if (pl.len > 0) {
                try out.appendSlice(allocator, pl);
                try out.appendSlice(allocator, "\n");
            }
        }
        pending_line = line;
    }
    if (pending_line) |pl| {
        if (pl.len > 0) {
            try out.appendSlice(allocator, pl);
            try out.appendSlice(allocator, "\n");
        }
    }

    if (!saw_block) {
        trimTrailingNewlines(&out);
        if (out.items.len > 0) try out.appendSlice(allocator, "\n\n");
        try out.appendSlice(allocator, block);
    }

    return out.toOwnedSlice(allocator);
}

fn trimTrailingNewlines(out: *std.ArrayList(u8)) void {
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        _ = out.pop();
    }
}

/// Replace the managed block in the hosts file at hosts_path atomically:
/// write a sibling temp file, then rename over the target. Returns
/// .unchanged without touching anything when content already matches.
pub fn sync(
    io: std.Io,
    gpa: std.mem.Allocator,
    hosts_path: []const u8,
    routes: []const routes_mod.Route,
    enabled: bool,
) Error!Outcome {
    if (!enabled) return .opted_out;
    switch (@import("builtin").os.tag) {
        .windows => return .unsupported_platform,
        else => {},
    }

    var hostnames = try gpa.alloc([]const u8, routes.len);
    defer gpa.free(hostnames);
    for (routes, 0..) |r, i| hostnames[i] = r.hostname;

    const block = try buildBlock(gpa, hostnames);
    defer gpa.free(block);

    const old = std.Io.Dir.cwd().readFileAlloc(io, hosts_path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        error.AccessDenied, error.PermissionDenied => return error.NotWritable,
        else => return error.NotWritable,
    };
    defer gpa.free(old);

    const updated = try applyBlock(gpa, old, block);
    defer gpa.free(updated);

    if (std.mem.eql(u8, old, updated)) return .unchanged;

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.berth-tmp", .{hosts_path});
    defer gpa.free(tmp_path);

    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io, tmp_path, .{
        .truncate = true,
        .permissions = .default_file,
    }) catch return error.NotWritable;
    var wbuf: [4096]u8 = undefined;
    var writer = file.writer(io, &wbuf);
    writer.interface.writeAll(updated) catch {
        file.close(io);
        return error.NotWritable;
    };
    writer.interface.flush() catch {
        file.close(io);
        return error.NotWritable;
    };
    file.close(io);

    std.Io.Dir.renameAbsolute(tmp_path, hosts_path, io) catch return error.NotWritable;
    return .synced;
}

/// Strip the managed block entirely; everything outside the markers
/// survives byte-for-byte. Shared write path with sync().
pub fn removeBlock(io: std.Io, gpa: std.mem.Allocator, hosts_path: []const u8) Error!Outcome {
    const old = std.Io.Dir.cwd().readFileAlloc(io, hosts_path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .unchanged, // nothing to clean
        else => return error.NotWritable,
    };
    defer gpa.free(old);

    const updated = try stripBlock(gpa, old);
    defer gpa.free(updated);
    if (std.mem.eql(u8, old, updated)) return .unchanged;

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.berth-tmp", .{hosts_path});
    defer gpa.free(tmp_path);

    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io, tmp_path, .{
        .truncate = true,
        .permissions = .default_file,
    }) catch return error.NotWritable;
    var wbuf: [4096]u8 = undefined;
    var writer = file.writer(io, &wbuf);
    writer.interface.writeAll(updated) catch {
        file.close(io);
        return error.NotWritable;
    };
    writer.interface.flush() catch {
        file.close(io);
        return error.NotWritable;
    };
    file.close(io);

    std.Io.Dir.renameAbsolute(tmp_path, hosts_path, io) catch return error.NotWritable;
    return .synced;
}

fn stripBlock(allocator: std.mem.Allocator, contents: []const u8) Error![]u8 {
    const start_idx = std.mem.indexOf(u8, contents, start_marker) orelse
        return allocator.dupe(u8, contents); // no block: byte-identical

    const end_idx = std.mem.indexOfPos(u8, contents, start_idx, end_marker) orelse
        return allocator.dupe(u8, contents); // unterminated block: leave alone

    // Extend to full lines: back up to the newline before start_marker,
    // advance past the newline after end_marker.
    var cut_begin = start_idx;
    while (cut_begin > 0 and contents[cut_begin - 1] != '\n') cut_begin -= 1;
    var cut_end = end_idx + end_marker.len;
    if (cut_end < contents.len and contents[cut_end] == '\n') cut_end += 1;

    return std.mem.concat(allocator, u8, &.{ contents[0..cut_begin], contents[cut_end..] });
}

test "block lists every hostname on loopback" {
    const block = try buildBlock(std.testing.allocator, &.{ "a.localhost", "b.crab" });
    defer std.testing.allocator.free(block);
    try std.testing.expectEqualStrings(
        "# berth-start\n127.0.0.1 a.localhost\n127.0.0.1 b.crab\n# berth-end\n",
        block,
    );
}

test "apply replaces stale block and preserves user entries" {
    const original =
        "127.0.0.1 localhost\n" ++
        "# berth-start\n127.0.0.1 old.host\n# berth-end\n" ++
        "::1 localhost\n";
    const block = "# berth-start\n127.0.0.1 new.host\n# berth-end\n";
    const updated = try applyBlock(std.testing.allocator, original, block);
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualStrings(
        "127.0.0.1 localhost\n" ++
            "\n" ++
            "# berth-start\n127.0.0.1 new.host\n# berth-end\n" ++
            "::1 localhost\n",
        updated,
    );
}

test "apply inserts block into file without markers" {
    const updated = try applyBlock(
        std.testing.allocator,
        "127.0.0.1 localhost\n",
        "# berth-start\n# berth-end\n",
    );
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualStrings(
        "127.0.0.1 localhost\n\n# berth-start\n# berth-end\n",
        updated,
    );
}

test "sync twice produces byte-identical file" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const hosts_path = try std.fmt.allocPrint(alloc, "{s}/hosts", .{path_buf[0..n]});
    defer alloc.free(hosts_path);

    const f = try tmp.dir.createFile(io, "hosts", .{ .truncate = true });
    var wbuf: [64]u8 = undefined;
    var w = f.writer(io, &wbuf);
    try w.interface.writeAll("127.0.0.1 localhost\n");
    try w.interface.flush();
    f.close(io);

    const routes = [_]routes_mod.Route{
        .{ .hostname = "app.localhost", .port = 4001 },
    };

    const first = try sync(io, alloc, hosts_path, &routes, true);
    try std.testing.expectEqual(Outcome.synced, first);
    const after_first = try std.Io.Dir.cwd().readFileAlloc(io, hosts_path, alloc, .limited(65536));
    defer alloc.free(after_first);

    const second = try sync(io, alloc, hosts_path, &routes, true);
    try std.testing.expectEqual(Outcome.unchanged, second);
    const after_second = try std.Io.Dir.cwd().readFileAlloc(io, hosts_path, alloc, .limited(65536));
    defer alloc.free(after_second);

    try std.testing.expectEqualStrings(after_first, after_second);
}

test "sync replaces stale entries from an earlier run" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const hosts_path = try std.fmt.allocPrint(alloc, "{s}/hosts", .{path_buf[0..n]});
    defer alloc.free(hosts_path);

    const stale =
        "127.0.0.1 localhost\n" ++
        "# berth-start\n127.0.0.1 dead.app.localhost\n# berth-end\n";
    const f = try tmp.dir.createFile(io, "hosts", .{ .truncate = true });
    var sbuf: [256]u8 = undefined;
    var sw = f.writer(io, &sbuf);
    try sw.interface.writeAll(stale);
    try sw.interface.flush();
    f.close(io);

    const routes = [_]routes_mod.Route{
        .{ .hostname = "live.app.localhost", .port = 4002 },
    };
    _ = try sync(io, alloc, hosts_path, &routes, true);

    const now = try std.Io.Dir.cwd().readFileAlloc(io, hosts_path, alloc, .limited(65536));
    defer alloc.free(now);
    try std.testing.expect(std.mem.indexOf(u8, now, "dead.app.localhost") == null);
    try std.testing.expect(std.mem.indexOf(u8, now, "live.app.localhost") != null);
    try std.testing.expect(std.mem.indexOf(u8, now, "127.0.0.1 localhost") != null);
}

test "unwritable target returns NotWritable instead of crashing" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const locked_dir = try std.fmt.allocPrint(alloc, "{s}/locked", .{path_buf[0..n]});
    defer alloc.free(locked_dir);
    try std.Io.Dir.cwd().createDirPath(io, locked_dir);
    const locked_z = try std.fmt.allocPrintSentinel(alloc, "{s}", .{locked_dir}, 0);
    defer alloc.free(locked_z);
    if (std.c.chmod(locked_z.ptr, 0o500) != 0) return error.SkipZigTest;

    const hosts_path = try std.fmt.allocPrint(alloc, "{s}/hosts", .{locked_dir});
    defer alloc.free(hosts_path);

    const routes = [_]routes_mod.Route{
        .{ .hostname = "app.localhost", .port = 4001 },
    };
    const result = sync(io, alloc, hosts_path, &routes, true);
    try std.testing.expectError(error.NotWritable, result);

    _ = std.c.chmod(locked_z.ptr, 0o700);
}

test "strip removes only the managed block byte-exactly" {
    const a = std.testing.allocator;
    const original = "127.0.0.1 localhost\n" ++
        "# berth-start\n127.0.0.1 old.host\n# berth-end\n" ++
        "::1 localhost\n";
    const stripped = try stripBlock(a, original);
    defer a.free(stripped);
    try std.testing.expectEqualStrings("127.0.0.1 localhost\n::1 localhost\n", stripped);

    // No block at all: caller sees unchanged without any rewrite.
    const plain = "127.0.0.1 localhost\n";
    const untouched = try stripBlock(a, plain);
    defer a.free(untouched);
    try std.testing.expectEqualStrings(plain, untouched);
}
