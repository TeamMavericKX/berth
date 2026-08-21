const std = @import("std");
const scanner = @import("scanner.zig");
pub fn main(init: std.process.Init) !void {
    const net = std.Io.net;
    // three live backends to find
    for ([_]u16{ 47101, 47202, 47303 }) |p| {
        const a = net.IpAddress.parseIp4("127.0.0.1", p) catch unreachable;
        _ = a.listen(init.io, .{}) catch continue;
    }
    const t0 = std.Io.Timestamp.now(init.io, .awake);
    const open = try scanner.scanRange(init.io, init.gpa, 1000, 9999, null);
    const t1 = std.Io.Timestamp.now(init.io, .awake);
    defer init.gpa.free(open);
    std.debug.print("full default scan 1000-9999: {d} ms, {d} open\n", .{ @divTrunc(t1.nanoseconds - t0.nanoseconds, 1_000_000), open.len });
}
