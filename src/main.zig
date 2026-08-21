const std = @import("std");

pub const version = "0.1.0";

pub fn main(init: std.process.Init.Minimal) !void {
    var it = try std.process.Args.Iterator.initAllocator(init.args, std.heap.page_allocator);
    defer it.deinit();
    _ = it.skip();

    if (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) return printVersion();
        if (std.mem.eql(u8, arg, "--help")) return printHelp();
    }
    try printVersion();
}

fn printVersion() !void {
    std.debug.print("berth {s}\n", .{version});
}

fn printHelp() !void {
    std.debug.print(
        \\berth {s} - one daemon, both worlds
        \\
        \\usage: berth [--version] [--help]
        \\
        \\pre-alpha: the proxy, scanner, and dashboard arrive milestone by
        \\milestone. see the repository issue tracker for the build plan.
        \\
    , .{version});
}

test "version parses as semver" {
    var it = std.mem.splitScalar(u8, version, '.');
    const major = try std.fmt.parseInt(u32, it.next() orelse return error.TestUnexpectedResult, 10);
    const minor = try std.fmt.parseInt(u32, it.next() orelse return error.TestUnexpectedResult, 10);
    const patch = try std.fmt.parseInt(u32, it.next() orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(u32, 0), major);
    try std.testing.expect(minor <= 99);
    try std.testing.expect(patch <= 99);
}
