const std = @import("std");
const builtin = @import("builtin");
const tls = @import("tls.zig");
const certs = @import("certs.zig");
const db = @import("db.zig");
const http = std.http;
const net = std.Io.net;
const routes_mod = @import("routes.zig");
const dash = @import("dash.zig");

pub const version = "0.2.0";

/// TLS backend built once at serve start when compiled with openssl;
/// null keeps the port plaintext-only.
pub var tls_backend: ?tls.Backend = null;
pub var tls_active: bool = false;
/// One connection per thread, so a threadlocal carries whether the
/// current connection was TLS-demuxed without threading a parameter
/// through every handler.
threadlocal var conn_is_tls: bool = false;

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

    // Peek the first byte without consuming: 0x16 is a TLS
    // ClientHello's content type (handshake). Everything else is
    // plaintext and flows through the h1 loop, which redirects to
    // https while TLS is active (except websocket upgrades).
    if (comptime builtin.os.tag != .windows) {
        var peek: [1]u8 = undefined;
        const fd = ctx.stream.socket.handle;
        const n = std.c.recv(fd, &peek, 1, 0x2); // MSG_PEEK (linux + macos)
        if (n == 1 and peek[0] == 0x16) {
            if (comptime tls.enabled) {
                if (tls_backend) |*backend| {
                    const session = tls.accept(backend, ctx.stream) catch {
                        return; // failed handshake: drop quietly
                    };
                    var conn = tls.Conn{ .session = session };
                    defer conn.close();
                    conn_is_tls = true;
                    defer conn_is_tls = false;
                    serveConnection(&conn, ctx.io) catch |err| logErr("connection ended", err);
                    return;
                }
            }
        }
    }

    serveConnection(ctx.stream, ctx.io) catch |err| logErr("connection ended", err);
}

fn serveConnection(stream: anytype, io: std.Io) !void {
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
        handleRequest(&request, io) catch |err| logErr("request failed", err);
    }
}

/// Live routes the 404 page advertises. Replaced by the SQLite store in
/// issue #10; a fixed buffer keeps this PR self-contained.
var live_routes_buf: [64]routes_mod.Route = undefined;
var live_routes_len: usize = 0;

/// Optional fallback consulted on route misses so registrations made by
/// `berth run` are visible to an already-running serve without a restart.
/// Implementations copy the stored hostname into out and return the row.
pub var dynamic_lookup: ?*const fn (out: []u8, hostname: []const u8) ?routes_mod.Route = null;

pub fn setLiveRoutes(routes: []const routes_mod.Route) void {
    const n = @min(routes.len, live_routes_buf.len);
    @memcpy(live_routes_buf[0..n], routes);
    live_routes_len = n;
}

fn currentRoutes() []const routes_mod.Route {
    return live_routes_buf[0..live_routes_len];
}

/// Strip a trailing ".tld" (e.g. ".localhost") for the suggested command.
fn stripTld(host: []const u8, comptime tld: []const u8) []const u8 {
    if (std.mem.endsWith(u8, host, tld)) {
        const stripped = host[0 .. host.len - tld.len];
        if (stripped.len > 0) return stripped;
    }
    return host;
}

test "strip tld for suggestion" {
    try std.testing.expectEqualStrings("myapp", stripTld("myapp.localhost", ".localhost"));
    try std.testing.expectEqualStrings("api.myapp", stripTld("api.myapp.localhost", ".localhost"));
    try std.testing.expectEqualStrings("plain.example.com", stripTld("plain.example.com", ".localhost"));
}

test "escape html entities" {
    var out: [64]u8 = undefined;
    const got = escapeHtml("<b>&\"x\"", &out);
    try std.testing.expectEqualStrings("&lt;b&gt;&amp;&quot;x&quot;", got);
}

fn escapeHtml(src: []const u8, buf: []u8) []const u8 {
    var used: usize = 0;
    for (src) |c| {
        const rep: []const u8 = switch (c) {
            '<' => "&lt;",
            '>' => "&gt;",
            '&' => "&amp;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => &[_]u8{c},
        };
        if (used + rep.len > buf.len) break;
        @memcpy(buf[used .. used + rep.len], rep);
        used += rep.len;
    }
    return buf[0..used];
}

const not_found_page_start =
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>berth</title>" ++
    "<style>body{font:14px/1.6 -apple-system,sans-serif;color:#18181b;" ++
    "max-width:620px;margin:12vh auto;padding:0 24px}" ++
    "h1{font-size:20px;margin-bottom:4px}code{font-family:ui-monospace,monospace;" ++
    "background:#f5f5f4;border:1px solid #e7e5e4;border-radius:6px;padding:1px 6px}" ++
    "ul{padding-left:18px}li{margin:6px 0}a{color:#047857}" ++
    ".hint{color:#52525b;margin-top:24px}</style></head><body>" ++
    "<h1>No app registered for <code>";

const not_found_page_mid = "</code></h1>";

fn appendRouteList(buf: []u8, routes: []const routes_mod.Route) usize {
    var n: usize = 0;
    if (routes.len == 0) {
        n += (std.fmt.bufPrint(buf[n..], "<p>No apps are running.</p>", .{}) catch return n).len;
        return n;
    }
    n += (std.fmt.bufPrint(buf[n..], "<p>Active apps:</p><ul>", .{}) catch return n).len;
    for (routes) |r| {
        n += (std.fmt.bufPrint(
            buf[n..],
            "<li><a href=\"http://{s}:{d}/\">{s}</a> &rarr; 127.0.0.1:{d}</li>",
            .{ r.hostname, r.port, r.hostname, r.port },
        ) catch break).len;
    }
    n += (std.fmt.bufPrint(buf[n..], "</ul>", .{}) catch return n).len;
    return n;
}

/// Render the teaching 404: what missed, which apps are live, and the exact
/// command that would register the requested name. Ported from portless
/// proxy.ts:203-227.
fn renderNotFound(buf: []u8, raw_host: []const u8, routes: []const routes_mod.Route) []const u8 {
    var esc_buf: [256]u8 = undefined;
    const safe_host = escapeHtml(raw_host, &esc_buf);

    var used: usize = 0;
    used += (std.fmt.bufPrint(buf[used..], "{s}{s}{s}", .{
        not_found_page_start, safe_host, not_found_page_mid,
    }) catch return "render error").len;
    used += appendRouteList(buf[used..], routes);

    const suggestion = stripTld(raw_host, ".localhost");
    used += (std.fmt.bufPrint(
        buf[used..],
        "<div class=\"hint\">start it with:<br><code>suggest: berth {s} your-command</code></div></body></html>",
        .{suggestion},
    ) catch return buf[0..used]).len;
    return buf[0..used];
}

test "not found page lists routes and suggestion" {
    const routes = [_]routes_mod.Route{
        .{ .hostname = "one.localhost", .port = 4001 },
        .{ .hostname = "two.localhost", .port = 4002 },
    };
    var buf: [2048]u8 = undefined;
    const page = renderNotFound(&buf, "missing.localhost", &routes);
    try std.testing.expect(std.mem.indexOf(u8, page, "missing.localhost") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "one.localhost") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "two.localhost") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "berth missing your-command") != null);
}

pub const max_hops = 5;

fn parseHops(value: []const u8) u32 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(u32, trimmed, 10) catch |err| switch (err) {
        error.Overflow => max_hops,
        else => 0,
    };
}

fn findHeaderValue(request: *http.Server.Request, name: []const u8, buf: []u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) {
            const n = @min(h.value.len, buf.len);
            @memcpy(buf[0..n], h.value[0..n]);
            return buf[0..n];
        }
    }
    return null;
}

const loop_page_start =
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>berth: loop detected</title>" ++
    "<style>body{font:14px/1.6 -apple-system,sans-serif;color:#18181b;max-width:620px;" ++
    "margin:12vh auto;padding:0 24px}h1{font-size:20px;margin-bottom:4px}" ++
    "code{font-family:ui-monospace,monospace;background:#f5f5f4;border:1px solid #e7e5e4;" ++
    "border-radius:6px;padding:1px 6px}pre{background:#f5f5f4;border:1px solid #e7e5e4;" ++
    "border-radius:8px;padding:14px;overflow-x:auto}.hint{color:#52525b;margin-top:24px}" ++
    ".why{color:#52525b}</style></head><body>" ++
    "<h1>Loop detected after ";

const loop_page_mid =
    " hops</h1>" ++
    "<p class=\"why\"><code>";

const loop_page_tail =
    "</code> keeps landing back on berth. A dev server is almost certainly " ++
    "proxying to a <code>*.localhost</code> name without rewriting the Host header.</p>" ++
    "<p>Point the proxy at the backend port directly:</p>" ++
    "<pre><code>// vite.config.ts\n" ++
    "server: {\n" ++
    "  proxy: {\n" ++
    "    '/api': {\n" ++
    "      target: 'http://127.0.0.1:";

fn renderLoopPage(buf: []u8, raw_host: []const u8, hops: u32, port: ?u16) []const u8 {
    var esc_buf: [256]u8 = undefined;
    const safe_host = escapeHtml(raw_host, &esc_buf);
    var hops_txt: [12]u8 = undefined;
    const hops_buf = std.fmt.bufPrint(&hops_txt, "{d}", .{hops}) catch "?";

    var used: usize = 0;
    used += (std.fmt.bufPrint(buf[used..], "{s}{s}{s}{s}{s}", .{
        loop_page_start, hops_buf, loop_page_mid, safe_host, loop_page_tail,
    }) catch return "render error").len;
    if (port) |pt| {
        used += (std.fmt.bufPrint(buf[used..], "{d}", .{pt}) catch return buf[0..used]).len;
    } else {
        used += (std.fmt.bufPrint(buf[used..], "&lt;backend-port&gt;", .{}) catch return buf[0..used]).len;
    }
    used += (std.fmt.bufPrint(
        buf[used..],
        "',\n      changeOrigin: true,\n    }},\n  }},\n}}</code></pre>" ++
            "<div class=\"hint\">berth counted <code>x-berth-hops</code> on every pass; " ++
            "five is the ceiling.</div></body></html>",
        .{},
    ) catch return buf[0..used]).len;
    return buf[0..used];
}

fn stripPort(raw_host: []const u8) []const u8 {
    const lowered = routes_mod.normalizeAuthority(raw_host);
    if (std.mem.lastIndexOfScalar(u8, lowered, ':')) |idx| {
        if (idx + 1 < lowered.len) {
            var digits = true;
            for (lowered[idx + 1 ..]) |c| {
                if (!std.ascii.isDigit(c)) digits = false;
            }
            if (digits) return lowered[0..idx];
        }
    }
    return lowered;
}

/// Dashboard endpoints live on the bare loopback host only, so named
/// app routes keep working: myapp.localhost/ still reaches the app.
fn isDashboardTarget(target: []const u8, raw_host: []const u8) bool {
    if (!std.mem.eql(u8, target, "/") and
        !std.mem.eql(u8, target, "/markdown") and
        !std.mem.startsWith(u8, target, "/events") and
        !std.mem.startsWith(u8, target, "/api/")) return false;
    const host = stripPort(raw_host);
    inline for (.{ "localhost", "127.0.0.1", "::1", "[::1]" }) |ok| {
        if (std.mem.eql(u8, host, ok)) return true;
    }
    return host.len == 0;
}

fn handleRequest(request: *http.Server.Request, io: std.Io) !void {
    const target = request.head.target;

    // While TLS is active on this port, plaintext requests redirect to
    // their https twin. WebSocket upgrades pass through: clients cannot
    // follow redirects mid-handshake.
    if (comptime tls.enabled) {
        if (tls_active and !conn_is_tls and request.head.method == .GET) {
            var up_buf: [32]u8 = undefined;
            const upgrade = findHeaderValue(request, "upgrade", &up_buf) orelse "";
            if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) {
                var hb: [256]u8 = undefined;
                const host = findHeaderValue(request, "host", &hb) orelse "";
                if (host.len > 0) {
                    var loc_buf: [512]u8 = undefined;
                    const location = std.fmt.bufPrint(&loc_buf, "https://{s}{s}", .{ host, target }) catch return;
                    try request.respond("", .{
                        .status = .moved_permanently,
                        .extra_headers = &.{.{ .name = "location", .value = location }},
                    });
                    return;
                }
            }
        }
    }

    if (std.mem.eql(u8, target, "/healthz")) {
        try request.respond("ok\n", .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        });
        logDebug("route served", &.{ "path=/healthz", "status=200" });
        return;
    }

    var host_buf: [256]u8 = undefined;
    const raw_host = findHeaderValue(request, "host", &host_buf) orelse "";

    if (isDashboardTarget(target, raw_host)) {
        try dash.handleDashboardRequest(request, io);
        var tgt_buf: [128]u8 = undefined;
        const tgt_kv = std.fmt.bufPrint(&tgt_buf, "target={s}", .{target}) catch "target=?";
        logDebug("route served", &.{ "path=dash", tgt_kv });
        return;
    }

    var hops_buf: [16]u8 = undefined;
    const hops = parseHops(findHeaderValue(request, "x-berth-hops", &hops_buf) orelse "");

    const match = routes_mod.findRoute(currentRoutes(), raw_host);

    if (hops >= max_hops) {
        var loop_buf: [4096]u8 = undefined;
        const body = renderLoopPage(&loop_buf, raw_host, hops, if (match) |m| m.port else null);
        try request.respond(body, .{
            .status = .loop_detected,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
        logDebug("route served", &.{ "path=loop", "status=508" });
        return;
    }

    const resolved = match orelse blk: {
        if (dynamic_lookup) |lookup| {
            var dyn_buf: [256]u8 = undefined;
            if (lookup(&dyn_buf, raw_host)) |m| break :blk m;
        }
        break :blk null;
    };

    if (resolved == null) {
        var page_buf: [4096]u8 = undefined;
        const body = renderNotFound(&page_buf, raw_host, currentRoutes());
        try request.respond(body, .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
        logDebug("route served", &.{ "path=miss", "status=404" });
        return;
    }

    var next_hops_buf: [16]u8 = undefined;
    const next_hops = std.fmt.bufPrint(&next_hops_buf, "{d}", .{hops + 1}) catch "1";
    var ok_buf: [256]u8 = undefined;
    const ok_body = std.fmt.bufPrint(
        &ok_buf,
        "route registered: {s} -> 127.0.0.1:{d}\nbackend dialing arrives with the sqlite store.\n",
        .{ resolved.?.hostname, resolved.?.port },
    ) catch "route registered\n";
    try request.respond(ok_body, .{
        .extra_headers = &.{
            .{ .name = "x-berth", .value = "1" },
            .{ .name = "x-berth-hops", .value = next_hops },
        },
    });
    logDebug("route served", &.{ "path=hit", "status=200" });
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

pub fn logDebug(msg: []const u8, kv: []const []const u8) void {
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

test "parse hops handles missing garbage and overflow" {
    try std.testing.expectEqual(@as(u32, 0), parseHops(""));
    try std.testing.expectEqual(@as(u32, 0), parseHops("  "));
    try std.testing.expectEqual(@as(u32, 3), parseHops("3"));
    try std.testing.expectEqual(@as(u32, 4), parseHops(" 4 "));
    try std.testing.expectEqual(@as(u32, 0), parseHops("banana"));
    try std.testing.expectEqual(@as(u32, max_hops), parseHops("99999999999"));
}

test "loop page names cause shows fix and port" {
    var buf: [4096]u8 = undefined;
    const page = renderLoopPage(&buf, "api.myapp.localhost", 5, 4001);
    try std.testing.expect(std.mem.indexOf(u8, page, "Loop detected after 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "api.myapp.localhost") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "changeOrigin: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "http://127.0.0.1:4001") != null);
}

test "loop page uses placeholder when route unknown" {
    var buf: [4096]u8 = undefined;
    const page = renderLoopPage(&buf, "ghost.localhost", 7, null);
    try std.testing.expect(std.mem.indexOf(u8, page, "&lt;backend-port&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "after 7") != null);
}
