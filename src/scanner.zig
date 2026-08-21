const std = @import("std");

pub const default_range_start = 1000;
pub const default_range_end = 9999;
pub const connect_timeout_ms = 500;
pub const max_concurrent = 20;

const c = std.c;
const sock_stream: c_uint = 1; // SOCK.STREAM on every posix we target

/// Probe one port on loopback. IPv4 first; IPv6 is tried only when the
/// IPv4 attempt fails, so services bound to ::1 alone are still found.
pub fn probePort(io: std.Io, port: u16) bool {
    // Raw-socket probing is POSIX-only; Windows support lands with a
    // native winsock backend later.
    switch (@import("builtin").os.tag) {
        .windows => return false,
        else => {},
    }
    _ = io;
    if (tryConnect4(port)) return true;
    return tryConnect6(port);
}

// BSD sockaddrs lead with a length byte; linux does not.
const bsd_sockaddr = switch (@import("builtin").os.tag) {
    .macos, .ios, .maccatalyst, .tvos, .watchos, .visionos => true,
    else => false,
};
const af_inet: u16 = 2;
const af_inet6: u16 = if (bsd_sockaddr) 30 else 10;

const SockaddrIn4 = if (bsd_sockaddr)
    extern struct {
        len: u8 = 16,
        family: u8 = af_inet,
        port: u16,
        addr: u32,
        zero: [8]u8 = @splat(0),
    }
else
    extern struct {
        family: u16 = af_inet,
        port: u16,
        addr: u32,
        zero: [8]u8 = @splat(0),
    };

const SockaddrIn6 = if (bsd_sockaddr)
    extern struct {
        len: u8 = 28,
        family: u8 = af_inet6,
        port: u16,
        flowinfo: u32 = 0,
        addr: [16]u8,
        scope_id: u32 = 0,
    }
else
    extern struct {
        family: u16 = af_inet6,
        port: u16,
        flowinfo: u32 = 0,
        addr: [16]u8,
        scope_id: u32 = 0,
    };

const loopback6 = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const loopback4: u32 = @bitCast([4]u8{ 127, 0, 0, 1 });

fn tryConnect4(port: u16) bool {
    var addr = SockaddrIn4{
        .port = std.mem.nativeToBig(u16, port),
        .addr = loopback4,
    };
    return tryConnect(af_inet, @ptrCast(&addr), @sizeOf(SockaddrIn4));
}

fn tryConnect6(port: u16) bool {
    var addr = SockaddrIn6{
        .port = std.mem.nativeToBig(u16, port),
        .addr = loopback6,
    };
    return tryConnect(af_inet6, @ptrCast(&addr), @sizeOf(SockaddrIn6));
}

/// O_NONBLOCK numerically; std.c.O is a packed struct on linux.
const o_nonblock: c_int = if (@import("builtin").os.tag == .macos) 0o400000 else 0o4000;

fn tryConnect(family: c_uint, addr: *const c.sockaddr, len: c.socklen_t) bool {
    const fd = c.socket(family, sock_stream, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);

    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return false;
    if (c.fcntl(fd, c.F.SETFL, flags | o_nonblock) < 0) return false;

    if (c.connect(fd, addr, len) == 0) return true;
    if (c.errno(-1) != .INPROGRESS) return false;

    var fds = [1]c.pollfd{.{ .fd = fd, .events = c.POLL.OUT, .revents = 0 }};
    const ready = c.poll(&fds, 1, connect_timeout_ms);
    if (ready <= 0) return false;
    if (fds[0].revents & c.POLL.ERR != 0) return false;

    // Reconnecting surfaces the pending error as EISCONN on success.
    if (c.connect(fd, addr, len) == 0) return true;
    return c.errno(-1) == .ISCONN;
}

const Scanner = struct {
    io: std.Io,
    cursor: std.atomic.Value(usize),
    end: usize,
    exclude: u16,
    mutex: std.Io.Mutex = .init,
    open: std.ArrayList(u16) = .empty,
    gpa: std.mem.Allocator,

    fn nextPort(self: *Scanner) ?u16 {
        while (true) {
            const i = self.cursor.fetchAdd(1, .monotonic);
            if (i > self.end) return null;
            const port: u16 = @intCast(i);
            if (port == self.exclude) continue;
            return port;
        }
    }

    fn worker(self: *Scanner) void {
        while (self.nextPort()) |port| {
            if (!probePort(self.io, port)) continue;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.open.append(self.gpa, port) catch return;
        }
    }
};

/// Scan [start, end] with a bounded worker pool; returns ascending open ports.
pub fn scanRange(
    io: std.Io,
    gpa: std.mem.Allocator,
    start: u16,
    end: u16,
    exclude_port: ?u16,
) ![]u16 {
    var scanner = Scanner{
        .io = io,
        .gpa = gpa,
        .cursor = .init(start),
        .end = end,
        .exclude = exclude_port orelse 0,
    };

    const workers = @min(max_concurrent, end - start + 1);
    var threads: [max_concurrent]std.Thread = undefined;
    var spawned: usize = 0;
    for (threads[0..workers]) |*t| {
        t.* = std.Thread.spawn(.{}, Scanner.worker, .{&scanner}) catch break;
        spawned += 1;
    }
    for (threads[0..spawned]) |t| t.join();

    const found = try scanner.open.toOwnedSlice(gpa);
    std.mem.sort(u16, found, {}, std.sort.asc(u16));
    return found;
}

test "finds known-open and skips closed ports" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const net = std.Io.net;
    const addr = net.IpAddress.parseIp4("127.0.0.1", 45901) catch unreachable;
    var holder = addr.listen(io, .{}) catch return error.SkipZigTest;
    defer holder.deinit(io);

    const open = try scanRange(io, gpa, 45900, 45910, null);
    defer gpa.free(open);
    try std.testing.expectEqualSlices(u16, &.{45901}, open);
}

test "excluded port never appears even when open" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const net = std.Io.net;
    const addr = net.IpAddress.parseIp4("127.0.0.1", 45921) catch unreachable;
    var holder = addr.listen(io, .{}) catch return error.SkipZigTest;
    defer holder.deinit(io);

    const open = try scanRange(io, gpa, 45920, 45925, 45921);
    defer gpa.free(open);
    try std.testing.expectEqual(@as(usize, 0), open.len);
}

test "results come back sorted across many opens" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const net = std.Io.net;
    var holders: [3]net.Server = undefined;
    const ports = [3]u16{ 45941, 45935, 45948 };
    for (ports, 0..) |p, i| {
        const a = net.IpAddress.parseIp4("127.0.0.1", p) catch unreachable;
        holders[i] = a.listen(io, .{}) catch return error.SkipZigTest;
    }
    defer for (&holders) |*h| h.deinit(io);

    const open = try scanRange(io, gpa, 45930, 45950, null);
    defer gpa.free(open);
    try std.testing.expectEqualSlices(u16, &.{ 45935, 45941, 45948 }, open);
}

test "empty range yields empty result" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const open = try scanRange(io, gpa, 45960, 45962, null);
    defer gpa.free(open);
    try std.testing.expectEqual(@as(usize, 0), open.len);
}
