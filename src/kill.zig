//! Graceful stop ladder: TERM every listener on a port, poll for exit,
//! KILL survivors only. Portmap's process ladder, ported to /proc walks
//! so no external lsof dependency exists.

const std = @import("std");
const builtin = @import("builtin");

pub const Result = enum {
    not_found,
    killed,
    force_killed,
    err,

    /// Plain-text body the dashboard kill endpoint returns.
    pub fn label(self: Result) []const u8 {
        return switch (self) {
            .not_found => "no listener\n",
            .killed => "killed\n",
            .force_killed => "force-killed\n",
            .err => "kill failed\n",
        };
    }

    pub fn status(self: Result) std.http.Status {
        return switch (self) {
            .not_found => .not_found,
            .killed, .force_killed => .ok,
            .err => .internal_server_error,
        };
    }
};

pub const Config = struct {
    /// How long SIGTERM targets get to exit on their own.
    term_timeout_ms: u64 = 2000,
    /// How long SIGKILL survivors get before we give up.
    kill_timeout_ms: u64 = 1000,
    poll_interval_ms: u64 = 100,
};

/// Full ladder for one port. Every pid holding a LISTEN socket on
/// `port` receives SIGTERM; after `term_timeout_ms` survivors receive
/// SIGKILL. Returns what actually happened.
pub fn killPort(io: std.Io, gpa: std.mem.Allocator, port: u16, cfg: Config) Result {
    switch (builtin.os.tag) {
        .linux => {},
        // /proc walking is linux-only; other platforms have no ladder yet.
        else => return .not_found,
    }

    const pids = listeningPids(io, gpa, port) catch return .err;
    defer gpa.free(pids);
    if (pids.len == 0) return .not_found;

    const remaining = gpa.dupe(i32, pids) catch return .err;
    defer gpa.free(remaining);

    for (pids) |pid| sendTerm(pid);

    if (!waitForExit(io, remaining, cfg.term_timeout_ms, cfg.poll_interval_ms)) {
        for (remaining) |pid| sendKill(pid);
        if (!waitForExit(io, remaining, cfg.kill_timeout_ms, cfg.poll_interval_ms)) {
            return .err;
        }
        return .force_killed;
    }
    return .killed;
}

fn sendTerm(pid: i32) void {
    std.posix.kill(pid, .TERM) catch {};
}

fn sendKill(pid: i32) void {
    std.posix.kill(pid, .KILL) catch {};
}

/// Poll until every listed pid is gone or the timeout elapses.
/// Mutates `pids` in place, compacting survivors forward; returns
/// true when none remain.
fn waitForExit(io: std.Io, pids: []i32, timeout_ms: u64, interval_ms: u64) bool {
    var elapsed: u64 = 0;
    while (true) {
        var alive_count: usize = 0;
        for (pids) |pid| {
            if (pidAlive(pid)) {
                pids[alive_count] = pid;
                alive_count += 1;
            }
        }
        if (alive_count == 0) return true;
        if (elapsed >= timeout_ms) return false;
        io.sleep(.fromMilliseconds(@intCast(interval_ms)), .real) catch return false;
        elapsed += interval_ms;
    }
}

/// Ownership-independent existence check. Zombies count as dead:
/// our own reaped-pending children must not wedge the ladder.
pub fn pidAlive(pid: i32) bool {
    switch (builtin.os.tag) {
        .linux => {},
        else => return false,
    }
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{pid}) catch return false;

    var stat_buf: [4096]u8 = undefined;
    const stat = readSmallProcFile(path, &stat_buf) orelse return false;
    // Format: pid (comm) state ... where comm may contain spaces and
    // parens, so the state char is the first non-space after LAST ')'.
    const close_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return false;
    const rest = std.mem.trimStart(u8, stat[close_paren + 1 ..], " ");
    if (rest.len == 0) return false;
    return rest[0] != 'Z';
}

fn readSmallProcFile(path: [*:0]const u8, buf: []u8) ?[]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    // procfs reports st_size 0, so readFileAlloc is useless here.
    const n = std.c.read(fd, buf.ptr, buf.len - 1);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

/// Every pid with a LISTEN socket on port. Deduplicated across both
/// the v4 and v6 tables and across shared inodes. Caller frees.
pub fn listeningPids(io: std.Io, gpa: std.mem.Allocator, port: u16) ![]i32 {
    switch (builtin.os.tag) {
        .linux => {},
        else => return &.{},
    }

    var inodes: std.ArrayList([]const u8) = .empty;
    defer {
        for (inodes.items) |inode| gpa.free(inode);
        inodes.deinit(gpa);
    }
    try collectListenInodes(gpa, port, &inodes);

    var pids: std.ArrayList(i32) = .empty;
    errdefer pids.deinit(gpa);
    for (inodes.items) |inode| {
        try appendPidsForInode(io, gpa, inode, &pids);
    }
    return pids.toOwnedSlice(gpa);
}

fn collectListenInodes(gpa: std.mem.Allocator, port: u16, out: *std.ArrayList([]const u8)) !void {
    const tables = [_][*:0]const u8{ "/proc/net/tcp", "/proc/net/tcp6" };
    for (tables) |path| {
        const bytes = readProcTable(gpa, path) orelse continue;
        defer gpa.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        _ = lines.next(); // header
        while (lines.next()) |line| {
            var local_port: u16 = 0;
            var state: []const u8 = "";
            var inode: []const u8 = "";
            var idx: usize = 0;
            var cols = std.mem.splitScalar(u8, std.mem.trim(u8, line, " "), ' ');
            while (cols.next()) |raw| {
                // /proc/net/tcp pads columns with extra spaces; treat
                // runs of separators as one or every index shifts.
                if (raw.len == 0) continue;
                switch (idx) {
                    1 => {
                        const colon = std.mem.lastIndexOfScalar(u8, raw, ':') orelse break;
                        local_port = std.fmt.parseInt(u16, raw[colon + 1 ..], 16) catch break;
                    },
                    3 => state = raw,
                    9 => inode = raw,
                    else => {},
                }
                idx += 1;
            }
            if (local_port == port and std.mem.eql(u8, state, "0A")) {
                const duped = try gpa.dupe(u8, inode);
                errdefer gpa.free(duped);
                var seen = false;
                for (out.items) |existing| {
                    if (std.mem.eql(u8, existing, duped)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try out.append(gpa, duped) else gpa.free(duped);
            }
        }
    }
}

fn appendPidsForInode(io: std.Io, gpa: std.mem.Allocator, inode: []const u8, out: *std.ArrayList(i32)) !void {
    const proc_dir = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return;
    defer proc_dir.close(io);

    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "socket:[{s}]", .{inode}) catch return;

    var it = proc_dir.iterate();
    while (it.next(io) catch null) |entry| {
        // procfs reports DT_UNKNOWN for directories; filter by name only.
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        var already = false;
        for (out.items) |existing| {
            if (existing == pid) {
                already = true;
                break;
            }
        }
        if (already) continue;

        var fd_path: [64]u8 = undefined;
        const fd_dir_path = std.fmt.bufPrint(&fd_path, "/proc/{d}/fd", .{pid}) catch continue;
        var fd_dir = std.Io.Dir.openDirAbsolute(io, fd_dir_path, .{ .iterate = true }) catch continue;
        defer fd_dir.close(io);

        var fd_it = fd_dir.iterate();
        while (fd_it.next(io) catch null) |fd_entry| {
            var target: [256]u8 = undefined;
            const n = fd_dir.readLink(io, fd_entry.name, &target) catch continue;
            if (std.mem.eql(u8, target[0..n], needle)) {
                try out.append(gpa, pid);
                break;
            }
        }
    }
}

fn readProcTable(gpa: std.mem.Allocator, path: [*:0]const u8) ?[]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);

    var list: std.ArrayList(u8) = .empty;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        list.appendSlice(gpa, chunk[0..@intCast(n)]) catch {
            gpa.free(list.items);
            return null;
        };
    }
    return list.toOwnedSlice(gpa) catch null;
}

test "result labels and statuses map to endpoint contract" {
    try std.testing.expectEqualStrings("no listener\n", Result.not_found.label());
    try std.testing.expectEqualStrings("killed\n", Result.killed.label());
    try std.testing.expectEqualStrings("force-killed\n", Result.force_killed.label());
    try std.testing.expectEqualStrings("kill failed\n", Result.err.label());
    try std.testing.expectEqual(std.http.Status.not_found, Result.not_found.status());
    try std.testing.expectEqual(std.http.Status.ok, Result.killed.status());
    try std.testing.expectEqual(std.http.Status.ok, Result.force_killed.status());
    try std.testing.expectEqual(std.http.Status.internal_server_error, Result.err.status());
}

test "pid alive detects self and rejects bogus pid" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const own_pid: i32 = @intCast(std.os.linux.getpid());
    try std.testing.expect(pidAlive(own_pid));
    try std.testing.expect(!pidAlive(-1));
    try std.testing.expect(!pidAlive(4194303));
}

test "find listener pid locates own listening socket" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const io = std.testing.io;
    const net = std.Io.net;
    const addr = net.IpAddress.parseIp4("127.0.0.1", 46701) catch unreachable;
    var holder = addr.listen(io, .{}) catch return error.SkipZigTest;
    defer holder.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const own_pid: i32 = @intCast(std.os.linux.getpid());
    const pids = try listeningPids(io, arena_state.allocator(), 46701);
    try std.testing.expect(pids.len >= 1);
    var found_self = false;
    for (pids) |pid| {
        if (pid == own_pid) found_self = true;
    }
    try std.testing.expect(found_self);

    const none = try listeningPids(io, arena_state.allocator(), 46702);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "ladder kills spawned fixture gracefully then reports not found" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const port: u16 = 46711;

    var child = std.process.spawn(io, .{
        .argv = &.{ "python3", "-m", "http.server", "46711", "--bind", "127.0.0.1" },
        .stdout = .close,
        .stderr = .close,
    }) catch return error.SkipZigTest;

    // Wait for the fixture to bind before asserting on it.
    var found = false;
    var waited: u64 = 0;
    while (waited < 5000) : (waited += 100) {
        io.sleep(.fromMilliseconds(100), .real) catch break;
        const pids = listeningPids(io, gpa, port) catch continue;
        defer gpa.free(pids);
        if (pids.len > 0) {
            found = true;
            break;
        }
    }
    if (!found) return error.SkipZigTest;

    const result = killPort(io, gpa, port, .{});
    try std.testing.expectEqual(Result.killed, result);

    // Second run finds nothing left to signal.
    try std.testing.expectEqual(Result.not_found, killPort(io, gpa, port, .{}));

    _ = child.wait(io) catch {};
    // Zombie must never wedge pidAlive.
    try std.testing.expect(!pidAlive(child.id orelse -1));
}

test "ladder escalates to sigkill when fixture ignores term" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const port: u16 = 46712;

    var child = std.process.spawn(io, .{
        .argv = &.{
            "python3",
            "-c",
            "import signal,http.server;" ++
                "signal.signal(signal.SIGTERM,signal.SIG_IGN);" ++
                "s=http.server.HTTPServer(('127.0.0.1',46712)," ++
                "http.server.SimpleHTTPRequestHandler);s.serve_forever()",
        },
        .stdout = .close,
        .stderr = .close,
    }) catch return error.SkipZigTest;

    var found = false;
    var waited: u64 = 0;
    while (waited < 5000) : (waited += 100) {
        io.sleep(.fromMilliseconds(100), .real) catch break;
        const pids = listeningPids(io, gpa, port) catch continue;
        defer gpa.free(pids);
        if (pids.len > 0) {
            found = true;
            break;
        }
    }
    if (!found) return error.SkipZigTest;

    try std.testing.expectEqual(Result.force_killed, killPort(io, gpa, port, .{}));
    try std.testing.expectEqual(Result.not_found, killPort(io, gpa, port, .{}));

    _ = child.wait(io) catch {};
}
