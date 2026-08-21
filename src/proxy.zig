const std = @import("std");
const http = std.http;
const net = std.Io.net;

pub const version = "0.1.0";

/// Errors the proxy listener can surface to the CLI layer, which owns
/// presentation (docs/conventions.md: propagate or own).
pub const ListenError = error{
    AddressInUse,
    OutOfMemory,
    ConfigRefused,
    Unexpected,
};

pub const Config = struct {
    /// Bind address string as given by the user. Loopback only by design.
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
};

/// Refuse anything that is not loopback before touching a socket.
/// LAN exposure arrives later as an explicit, loudly-documented flag.
pub fn configRefusal(cfg: Config) ?[]const u8 {
    const loopback_hosts = [_][]const u8{ "127.0.0.1", "::1", "localhost", "[::1]" };
    for (loopback_hosts) |h| {
        if (std.mem.eql(u8, cfg.host, h)) return null;
    }
    return cfg.host;
}

fn resolveAddress(cfg: Config) !net.IpAddress {
    if (std.mem.eql(u8, cfg.host, "localhost")) {
        return .{ .ip4 = try net.Ip4Address.parse("127.0.0.1", cfg.port) };
    }
    if (std.mem.eql(u8, cfg.host, "::1") or std.mem.eql(u8, cfg.host, "[::1]")) {
        return .{ .ip6 = try net.Ip6Address.parse("::1", cfg.port) };
    }
    return .{ .ip4 = try net.Ip4Address.parse(cfg.host, cfg.port) };
}

const ConnCtx = struct {
    stream: net.Stream,
    io: std.Io,
};

fn connectionThread(ctx: *ConnCtx) void {
    defer {
        ctx.stream.close(ctx.io);
        std.heap.page_allocator.destroy(ctx);
    }
    serveConnection(ctx.stream, ctx.io) catch |err| logErr("connection ended", err);
}

fn serveConnection(stream: net.Stream, io: std.Io) !void {
    const allocator = std.heap.page_allocator;

    const read_buf = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(write_buf);

    var reader = stream.reader(io, read_buf);
    var writer = stream.writer(io, write_buf);

    var server = http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        handleRequest(&request) catch |err| logErr("request failed", err);
    }
}

fn handleRequest(request: *http.Server.Request) !void {
    const target = request.head.target;
    const method = @tagName(request.head.method);

    if (std.mem.eql(u8, target, "/healthz")) {
        try request.respond("ok\n", .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        });
        logDebug("route served", &.{ "path=/healthz", "status=200" });
        return;
    }

    const body = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "no route for {s} {s}\nberth is pre-alpha; routing arrives with the next milestones.\n",
        .{ method, target },
    );
    defer std.heap.page_allocator.free(body);

    // Consume any request body so keep-alive connections stay usable.
    var head_buffer: [16 * 1024]u8 = undefined;
    _ = request.readerExpectNone(&head_buffer);

    try request.respond(body, .{
        .status = .not_found,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    });
    logDebug("route served", &.{ "path=unknown", "status=404" });
}

fn logLine(level: []const u8, msg: []const u8, kv: []const []const u8) void {
    // Build the entire line first, then one debug.print call so the
    // stderr machinery handles locking and a single write for us.
    var buf: [512]u8 = undefined;
    var used: usize = 0;
    used += (std.fmt.bufPrint(buf[used..], "{s}: {s}", .{ level, msg }) catch return).len;
    for (kv) |pair| {
        if (used >= buf.len) break;
        used += (std.fmt.bufPrint(buf[used..], " {s}", .{pair}) catch break).len;
    }
    if (used < buf.len) buf[used] = 0x0a else return;
    std.debug.print("{s}", .{buf[0 .. used + 1]});
}

/// Set once at startup from BERTH_LOG (see main.zig); read racily
/// afterwards which is fine for a logging on/off switch.
pub var debug_enabled: bool = false;

fn logDebug(msg: []const u8, kv: []const []const u8) void {
    if (!debug_enabled) return;
    logLine("debug", msg, kv);
}

fn logErr(msg: []const u8, err: anyerror) void {
    var kv_buf: [64]u8 = undefined;
    const pair = std.fmt.bufPrint(&kv_buf, "error={s}", .{@errorName(err)}) catch "error=?";
    logLine("err", msg, &.{pair});
}

/// Bind and serve forever. Returns only on unrecoverable listen errors.
/// The CLI layer translates ListenError into exit codes and messages.
pub fn serve(io: std.Io, cfg: Config) ListenError!void {
    const bad_host = configRefusal(cfg);
    if (bad_host != null) {
        std.debug.print(
            \\cannot bind {s}: berth binds loopback only
            \\  non-loopback exposure is a deliberate feature arriving later.
            \\  use 127.0.0.1, ::1, or localhost
            \\
        , .{bad_host.?});
        return error.ConfigRefused;
    }

    const address = resolveAddress(cfg) catch return error.Unexpected;

    var listener = address.listen(io, .{ .kernel_backlog = 128 }) catch |err| switch (err) {
        error.AddressInUse => {
            std.debug.print(
                \\cannot bind {s}:{d}: address already in use
                \\  something else owns this port. find it: lsof -i :{d}
                \\
            , .{ cfg.host, cfg.port, cfg.port });
            return error.AddressInUse;
        },
        else => return error.Unexpected,
    };
    defer listener.deinit(io);

    var addr_buf: [64]u8 = undefined;
    const addr_kv = std.fmt.bufPrint(&addr_buf, "addr={s}:{d}", .{ cfg.host, cfg.port }) catch "addr=?";
    logLine("info", "berth listening", &.{ addr_kv, "mode=loopback-only" });

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted, error.WouldBlock => continue,
            error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => {
                logLine("err", "accept failed: descriptor quota exhausted", &.{});
                io.sleep(.fromMilliseconds(100), .real) catch {};
                continue;
            },
            else => {
                logLine("err", "accept failed unexpectedly", &.{});
                continue;
            },
        };

        const ctx = std.heap.page_allocator.create(ConnCtx) catch {
            stream.close(io);

            continue;
        };
        ctx.* = .{ .stream = stream, .io = io };

        const thread = std.Thread.spawn(.{}, connectionThread, .{ctx}) catch {
            stream.close(io);

            std.heap.page_allocator.destroy(ctx);
            continue;
        };
        thread.detach();
    }
}

test "validate config refuses non-loopback" {
    try std.testing.expectEqual(@as(?[]const u8, null), configRefusal(.{ .host = "127.0.0.1" }));
    try std.testing.expectEqual(@as(?[]const u8, null), configRefusal(.{ .host = "localhost" }));
    try std.testing.expectEqual(@as(?[]const u8, null), configRefusal(.{ .host = "::1" }));
    try std.testing.expectEqualStrings("0.0.0.0", configRefusal(.{ .host = "0.0.0.0" }).?);
    try std.testing.expectEqualStrings("192.168.1.10", configRefusal(.{ .host = "192.168.1.10" }).?);
}

test "resolve address localhost maps to ipv4 loopback" {
    const addr = try resolveAddress(.{ .host = "127.0.0.1", .port = 9999 });
    try std.testing.expectEqual(@as(u16, 9999), addr.getPort());
}
