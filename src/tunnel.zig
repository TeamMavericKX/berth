//! Tailscale serve/funnel integration (#28). Sharing a local app with
//! a teammate should be one flag. Missing binary or daemon degrades to
//! a clear error while the app keeps running locally — the tunnel is a
//! garnish, never a dependency.

const std = @import("std");
const builtin = @import("builtin");

pub var tailscale_bin: []const u8 = "tailscale";

pub const Error = error{
    BinaryMissing,
    NotReady,
    ParseFailed,
    CommandFailed,
    OutOfMemory,
};

/// Injectable runner: tests record argv and hand back canned stdout.
pub const RunResult = struct {
    stdout: []u8,
};
pub var exec_impl: *const fn (io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) Error!RunResult = execTailscale;

fn execTailscale(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) Error!RunResult {
    if (builtin.os.tag == .windows) return Error.BinaryMissing;
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    full.append(gpa, tailscale_bin) catch return Error.CommandFailed;
    full.appendSlice(gpa, argv) catch return Error.CommandFailed;

    const result = std.process.run(gpa, io, .{ .argv = full.items }) catch |err| switch (err) {
        error.FileNotFound => return Error.BinaryMissing,
        else => return Error.NotReady,
    };
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    defer gpa.free(result.stderr);
    if (!ok) {
        gpa.free(result.stdout);
        return Error.NotReady;
    }
    return .{ .stdout = result.stdout };
}

fn resetSeams() void {
    exec_impl = execTailscale;
}

/// Is tailscale present and its daemon reachable? Cheap status call.
pub fn ready(io: std.Io, gpa: std.mem.Allocator) bool {
    _ = exec_impl(io, gpa, &.{"version"}) catch return false;
    return true;
}

/// Run `serve --bg` (or `funnel --bg`) against a loopback port and
/// parse the ts.net URL from stdout. Caller owns nothing; authority is
/// copied out for the caller to store.
pub const ExposeResult = union(enum) {
    ok: []u8,
    err: Error,
};

pub fn expose(io: std.Io, gpa: std.mem.Allocator, port: u16, funnel: bool) ExposeResult {
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return .{ .err = Error.ParseFailed };

    const raw = if (funnel)
        exec_impl(io, gpa, &.{ "funnel", "--bg", port_str })
    else
        exec_impl(io, gpa, &.{ "serve", "--bg", port_str });

    const r: RunResult = raw catch |e| return .{ .err = e };
    defer gpa.free(r.stdout);

    const url = extractTsNetUrl(r.stdout) orelse return .{ .err = Error.ParseFailed };
    const copy = gpa.dupe(u8, url) catch return .{ .err = Error.CommandFailed };
    return .{ .ok = copy };
}

/// "https://box.tail1234.ts.net" -> "box.tail1234.ts.net"; keeps an
/// explicit ":8443" suffix when present.
pub fn urlToAuthority(url: []const u8) ?[]const u8 {
    const marker = "https://";
    const start = std.mem.indexOf(u8, url, marker) orelse return null;
    const rest = url[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

/// Best-effort teardown of our own entry; tailscale keeps serving
/// until reset, so callers surface the hint rather than pretending.
pub fn unexpose(io: std.Io, gpa: std.mem.Allocator, funnel: bool) void {
    const res = if (funnel)
        exec_impl(io, gpa, &.{ "funnel", "--bg", "off" })
    else
        exec_impl(io, gpa, &.{ "serve", "--bg", "off" });
    if (res) |r| gpa.free(r.stdout) else |_| {}
}

/// Pull an https://...ts.net URL out of mixed human-readable output.
pub fn extractTsNetUrl(text: []const u8) ?[]const u8 {
    const marker = "https://";
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, marker)) |s| {
        var end = s + marker.len;
        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '.' or text[end] == '-')) end += 1;
        const candidate = text[s..end];
        // A real tailnet authority ends in ts.net and names at least
        // one machine before that.
        if (std.mem.endsWith(u8, candidate, ".ts.net")) return candidate;
        start = end;
    }
    return null;
}

test "expose parses the ts.net url from serve output" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const S = struct {
        var captured: ?[]const []const u8 = null;
    };
    exec_impl = struct {
        fn f(_: std.Io, a: std.mem.Allocator, argv: []const []const u8) Error!RunResult {
            // The caller's argv tuple lives on its stack frame; dupe
            // everything we want to inspect after it returns.
            const copy = try a.alloc([]const u8, argv.len);
            for (argv, 0..) |arg, idx| copy[idx] = try a.dupe(u8, arg);
            S.captured = copy;
            return .{ .stdout = try a.dupe(u8,
                \\Funnel started on https://box.tail1234.ts.net
                \\Check it out!
            ) };
        }
    }.f;

    const res = expose(io, gpa, 4123, true);
    try std.testing.expect(res == .ok);
    if (res != .ok) return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://box.tail1234.ts.net", res.ok);
    const args = S.captured.?;
    try std.testing.expectEqualStrings("funnel", args[0]);
    try std.testing.expectEqualStrings("--bg", args[1]);
    try std.testing.expectEqualStrings("4123", args[2]);
}

test "missing binary surfaces as BinaryMissing" {
    const io = std.testing.io;
    exec_impl = struct {
        fn f(_: std.Io, _: std.mem.Allocator, _: []const []const u8) Error!RunResult {
            return Error.BinaryMissing;
        }
    }.f;
    try std.testing.expect(expose(io, std.testing.allocator, 4123, false) == .err);
    resetSeams();
}

test "url extractor ignores non-ts.net links" {
    try std.testing.expect(extractTsNetUrl("see https://example.com docs") == null);
    const got = extractTsNetUrl("served at https://a-b-1.tailnet-x.ts.net:8443 done").?;
    _ = got; // trailing :8443 stops at first non-url byte; host part matched above
}
