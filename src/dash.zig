const std = @import("std");
const http = std.http;
const ports = @import("ports.zig");
const kill_mod = @import("kill.zig");
const containers_mod = @import("containers.zig");
const scanner = @import("scanner.zig");

pub const PortEntry = ports.PortEntry;

pub const html = @embedFile("dash.html");

/// The dashboard owns one process-wide allocation domain. Everything it
/// touches allocates here, never through a caller-supplied allocator:
/// the refresh thread, request threads and mutation handlers all share
/// this state, so a single thread-safe domain is part of the contract.
///
/// Two pools with different lifetimes:
///   * `alloc` (plain page allocator) for values that escape a tick,
///     namely the published JSON payload, plus isolated request-scoped
///     reads on API threads (/proc tables, pid walks).
///   * `scratch` arena for everything inside one refresh tick (provider
///     rows, scan results, entry list, rendered text). Reset after each
///     render, so provider results only need to outlive the callback.
pub const alloc: std.mem.Allocator = std.heap.page_allocator;
var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// Injected by serve: returns registered apps from the route store.
/// Implementations allocate from the passed allocator; the memory only
/// needs to stay valid until the next refresh begins.
pub var registered_provider: ?*const fn (gpa: std.mem.Allocator) anyerror![]ports.RegisteredApp = null;

/// The port serve itself listens on; excluded from scan results.
pub const dashboard_port_default: u16 = 8080;

pub var dashboard_port: u16 = dashboard_port_default;

pub const scan_range_start = 1000;
pub const scan_range_end = 9999;

/// Latest rendered snapshot plus a generation counter bumped on every
/// publish so SSE clients detect changes by polling once per second.
pub const Hub = struct {
    mutex: std.Io.Mutex = .init,
    generation: u64 = 0,
    payload: []u8 = &.{},
    markdown: []u8 = &.{},
    io: std.Io,

    pub fn publish(self: *Hub, json: []u8, md: []u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.payload.len > 0) alloc.free(self.payload);
        if (self.markdown.len > 0) alloc.free(self.markdown);
        self.payload = json;
        self.markdown = md;
        self.generation += 1;
    }

    fn current(self: *Hub) struct { gen: u64, payload: []const u8, markdown: []const u8 } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .gen = self.generation, .payload = self.payload, .markdown = self.markdown };
    }
};

var hub_instance: ?*Hub = null;

pub fn setHub(h: *Hub) void {
    hub_instance = h;
}

fn hub() *Hub {
    return hub_instance.?;
}

/// Build entries from providers + a live scan and publish. Runs on the
/// refresh thread and after every mutation.
pub fn refreshOnce(io: std.Io) void {
    const scratch = scratch_state.allocator();
    defer _ = scratch_state.reset(.retain_capacity);

    var registered: []ports.RegisteredApp = &.{};
    if (registered_provider) |provider| {
        registered = provider(scratch) catch &.{};
    }
    var tags: []db.TagColor = &.{};
    if (tags_provider) |provider| {
        tags = provider(scratch) catch &.{};
    }

    const open = scanner.scanRange(io, scratch, scan_range_start, scan_range_end, dashboard_port) catch return;

    const cports = containers_mod.discover(io, scratch);

    const entries = ports.buildPortEntries(
        scratch,
        registered,
        cports,
        open,
        scan_range_start,
        scan_range_end,
    ) catch return;

    var json_writer = std.Io.Writer.Allocating.init(scratch);
    defer json_writer.deinit();
    renderEntriesJson(&json_writer.writer, entries, tags) catch return;

    var md_writer = std.Io.Writer.Allocating.init(scratch);
    defer md_writer.deinit();
    renderMarkdown(&md_writer.writer, entries, registered) catch return;

    // Only rendered text escapes the tick; give it a stable home.
    const json = alloc.dupe(u8, json_writer.written()) catch return;
    const md = alloc.dupe(u8, md_writer.written()) catch {
        alloc.free(json);
        return;
    };
    hub().publish(json, md);
}

/// Refresh thread body: initial snapshot immediately, then every 5s.
pub fn refreshLoop(io: std.Io) void {
    while (true) {
        refreshOnce(io);
        io.sleep(.fromMilliseconds(5000), .real) catch return;
    }
}

/// True when the client asked for markdown. Only an explicit
/// text/markdown token opts in; */* and text/html get the dashboard.
pub fn wantsMarkdown(accept: ?[]const u8) bool {
    const a = accept orelse return false;
    var buf: [256]u8 = undefined;
    if (a.len > buf.len) return false;
    const lower = std.ascii.lowerString(buf[0..a.len], a);
    return std.mem.indexOf(u8, lower, "text/markdown") != null;
}

fn acceptHeader(request: *http.Server.Request) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "accept")) return h.value;
    }
    return null;
}

/// Pipe-escape a cell so names cannot break the table layout.
fn mdCell(writer: *std.Io.Writer, raw: []const u8) !void {
    for (raw) |c| {
        switch (c) {
            '|' => try writer.writeAll("\\|"),
            '\n', '\r' => try writer.writeAll(" "),
            else => try writer.writeByte(c),
        }
    }
}

/// Agent-facing status page: registered apps, live ports, full API
/// reference with copy-paste curl lines. Pure for unit tests.
pub fn renderMarkdown(writer: *std.Io.Writer, entries: []const PortEntry, registered: []const ports.RegisteredApp) !void {
    try writer.print("# berth\n\nPortless dev proxy on this machine. Every registered app is reachable at its `http://<name>.localhost/` URL; this dashboard runs on port {d}. Ports {d}-{d} are scanned live every few seconds.\n\n", .{ dashboard_port, scan_range_start, scan_range_end });

    try writer.writeAll("## registered apps\n\n");
    var any_reg = false;
    for (entries) |e| {
        if (e.origin != .registered or e.name.len == 0) continue;
        any_reg = true;
        break;
    }
    if (any_reg) {
        try writer.writeAll("| name | url | category | port | alive |\n|---|---|---|---|---|\n");
        for (entries) |e| {
            if (e.origin != .registered or e.name.len == 0) continue;
            try writer.writeAll("| ");
            try mdCell(writer, e.name);
            try writer.writeAll(" | http://");
            try mdCell(writer, e.name);
            try writer.writeAll(".localhost/ | ");
            try mdCell(writer, e.category);
            try writer.print(" | {d} | {s} |\n", .{ e.port, if (e.alive) "yes" else "no" });
        }
    } else {
        try writer.writeAll("None yet. Start one via `berth run <name> -- <cmd>` or label a port with the edit endpoint below.\n");
    }

    try writer.writeAll("\n## live ports\n\n| port | name | origin | pid | tunnel |\n|---|---|---|---|---|\n");
    for (entries) |e| {
        try writer.print("| {d} | ", .{e.port});
        try mdCell(writer, e.name);
        try writer.print(" | {s} | ", .{@tagName(e.origin)});
        if (e.pid) |p| try writer.print("{d}", .{p}) else try writer.writeAll("-");
        try writer.writeAll(" | ");
        var tunneled = false;
        for (registered) |r| {
            if (r.port == e.port and r.tunnel != null) {
                try mdCell(writer, r.tunnel.?);
                tunneled = true;
                break;
            }
        }
        if (!tunneled) try writer.writeAll("-");
        try writer.writeAll(" |\n");
    }

    try writer.print("\n## api reference\n\nAll endpoints answer on the bare `localhost` host (port {d}).\n\n", .{dashboard_port});

    const blocks = [_]struct { head: []const u8, pre: []const u8, post: []const u8 }{
        .{ .head = "### GET /api/ports - every port berth sees, as JSON", .pre = "curl http://localhost:", .post = "/api/ports" },
        .{ .head = "### POST /api/edit?port=PORT&name=NAME&category=CATEGORY - label an app", .pre = "curl -X POST 'http://localhost:", .post = "/api/edit?port=4300&name=myapp&category=web'" },
        .{ .head = "### POST /api/kill?port=PORT - stop a listener (TERM, then KILL after 2s)", .pre = "curl -X POST 'http://localhost:", .post = "/api/kill?port=4300'" },
        .{ .head = "### GET /events - server-sent events: snapshot on change, keepalive every 15s", .pre = "curl -N http://localhost:", .post = "/events" },
        .{ .head = "### GET /markdown - this page", .pre = "curl http://localhost:", .post = "/markdown" },
    };
    for (blocks) |b| {
        try writer.writeAll(b.head);
        try writer.writeAll("\n\n    ");
        try writer.writeAll(b.pre);
        try writer.print("{d}", .{dashboard_port});
        try writer.writeAll(b.post);
        try writer.writeAll("\n\n");
    }

    try writer.writeAll("### proxying\n\nAny `<name>.localhost` URL proxies to that app's port:\n\n    curl http://myapp.localhost/some/path\n");
}

/// Render entries as the SSE data payload. Pure for unit tests.
pub fn renderEntriesJson(
    writer: *std.Io.Writer,
    entries: []const PortEntry,
    tags: []const db.TagColor,
) !void {
    try writer.writeAll("{\"tags\":{");
    for (tags, 0..) |t, i| {
        if (i > 0) try writer.writeAll(",");
        try writeJsonString(writer, t.category);
        try writer.writeAll(":");
        try writeJsonString(writer, t.color);
    }
    try writer.writeAll("},\"entries\":[");
    for (entries, 0..) |e, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"port\":{d},\"name\":", .{e.port});
        try writeJsonString(writer, e.name);
        try writer.writeAll(",\"category\":");
        try writeJsonString(writer, e.category);
        try writer.print(",\"origin\":\"{s}\",\"alive\":{},\"pid\":", .{ e.origin.label(), e.alive });
        if (e.pid) |pid| {
            try writer.print("{d}", .{pid});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"tunnel\":");
        if (e.tunnel) |t| {
            try writeJsonString(writer, t);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
}

pub fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => {
            if (ch < 0x20) {
                try writer.print("\\u{x:0>4}", .{ch});
            } else {
                try writer.writeByte(ch);
            }
        },
    };
    try writer.writeByte('"');
}

/// Single entry point for every dashboard endpoint: "/" serves the
/// embedded HTML, "/events" the SSE stream, "/api/*" data + mutations.
pub fn handleDashboardRequest(request: *http.Server.Request, io: std.Io) !void {
    // Match paths without their query string.
    const path = if (std.mem.indexOfScalar(u8, request.head.target, '?')) |q|
        request.head.target[0..q]
    else
        request.head.target;
    const target = path;

    if (std.mem.eql(u8, target, "/")) {
        if (request.head.method != .GET) {
            return request.respond("method not allowed\n", .{ .status = .method_not_allowed, .keep_alive = false });
        }
        const snap = hub().current();
        if (wantsMarkdown(acceptHeader(request))) {
            try request.respond(snap.markdown, .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/markdown; charset=utf-8" },
                    .{ .name = "vary", .value = "accept" },
                },
            });
            return;
        }
        try request.respond(html, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "vary", .value = "accept" },
            },
        });
        return;
    }

    if (std.mem.eql(u8, target, "/markdown")) {
        if (request.head.method != .GET) {
            return request.respond("method not allowed\n", .{ .status = .method_not_allowed, .keep_alive = false });
        }
        const snap = hub().current();
        try request.respond(snap.markdown, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/markdown; charset=utf-8" },
                .{ .name = "vary", .value = "accept" },
            },
        });
        return;
    }

    if (std.mem.startsWith(u8, target, "/events")) {
        if (request.head.method != .GET) {
            return request.respond("method not allowed\n", .{ .status = .method_not_allowed, .keep_alive = false });
        }
        return handleEvents(request, io);
    }
    if (std.mem.eql(u8, target, "/api/ports")) {
        return handleApiPorts(request);
    }
    if (std.mem.eql(u8, target, "/api/kill")) {
        return handleApiKill(io, request);
    }
    if (std.mem.eql(u8, target, "/api/edit")) {
        return handleApiEdit(io, request);
    }
    try request.respond("not found\n", .{ .status = .not_found, .keep_alive = false });
}

/// SSE stream: initial snapshot, then scan events on generation change
/// (polled at 1s, so mutations land within one second) and a keepalive
/// comment every 15s. Exits when the client disconnects.
pub fn handleEvents(request: *http.Server.Request, io: std.Io) !void {
    var buffer: [16 * 1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&buffer, .{ .respond_options = .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    } });
    const w = &body_writer.writer;

    try w.writeAll("retry: 3000\n\n");
    // Force the first snapshot out immediately.
    var last_sent: u64 = hub().current().gen +% 1;
    // Keepalive cadence is independent of scan traffic so a quiet
    // server still proves the stream is alive every 15 seconds.
    var since_keepalive: usize = 0;
    var scratch: [32 * 1024]u8 = undefined;

    while (true) {
        const snap = hub().current();
        if (snap.gen != last_sent) {
            last_sent = snap.gen;
            const n = @min(snap.payload.len, scratch.len);
            @memcpy(scratch[0..n], snap.payload[0..n]);
            w.print("event: scan\ndata: {s}\n\n", .{scratch[0..n]}) catch return;
            w.flush() catch return;
            body_writer.flush() catch return;
        }
        io.sleep(.fromMilliseconds(1000), .real) catch return;
        since_keepalive += 1;
        if (since_keepalive >= 15) {
            since_keepalive = 0;
            w.writeAll(": keepalive\n\n") catch return;
            w.flush() catch return;
            body_writer.flush() catch return;
        }
    }
}

/// Injected by serve: every stored category color. Arena-backed like
/// registered_provider.
pub var tags_provider: ?*const fn (gpa: std.mem.Allocator) anyerror![]db.TagColor = null;

pub const db = @import("db.zig");

/// Hook wired by serve: persists name/category for the app on port.
pub var edit_hook: ?*const fn (
    gpa: std.mem.Allocator,
    port: u16,
    name: []const u8,
    category: []const u8,
) anyerror!void = null;

/// Extract a decimal query param value from a raw target like
/// "/api/kill?port=4300". Returns null when absent or malformed.
pub fn queryParam(target: []const u8, key: []const u8, buf: []u8) ?[]const u8 {
    var rest = target;
    while (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        rest = rest[q + 1 ..];
        var pairs = std.mem.splitScalar(u8, rest, '&');
        while (pairs.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], key)) {
                const n = @min(pair[eq + 1 ..].len, buf.len);
                @memcpy(buf[0..n], pair[eq + 1 ..][0..n]);
                return buf[0..n];
            }
        }
        return null;
    }
    return null;
}

/// POST /api/ports returns the current snapshot; POST /api/kill sends
/// SIGTERM to the listener on port. Both re-publish so streams see the
/// change within one second.
/// Shared secret for mutations when set (BERTH_TOKEN). Null keeps
/// origin-only gating.
pub var auth_token: ?[]const u8 = null;

/// True when an Origin header is absent or points at a loopback host
/// served locally. Foreign origins are the browser CSRF vector this
/// gate exists to close.
pub fn originAllowed(origin: ?[]const u8) bool {
    const o = origin orelse return true;
    const scheme_sep = std.mem.indexOf(u8, o, "://") orelse return false;
    var host = o[scheme_sep + 3 ..];
    // Origin carries no path; tolerate trailing junk defensively anyway.
    if (std.mem.indexOfScalar(u8, host, '/')) |slash| host = host[0..slash];

    if (host.len > 0 and host[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return false;
        return std.mem.eql(u8, host[0 .. close + 1], "[::1]");
    }
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    return std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1");
}

fn headerValue(request: *http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// Constant-time bearer token comparison.
fn bearerMatches(request: *http.Server.Request, expected: []const u8) bool {
    const value = headerValue(request, "authorization") orelse return false;
    const prefix = "bearer ";
    if (value.len <= prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix)) return false;
    const got = std.mem.trim(u8, value[prefix.len..], " ");
    if (got.len != expected.len) return false;
    var diff: u8 = 0;
    for (got, expected) |a, b| diff |= a ^ b;
    return diff == 0;
}

/// Mutations answer only to same-origin browsers or, when a token is
/// configured, to callers bearing it. Reads stay open.
pub fn mutationAuthorized(request: *http.Server.Request) bool {
    if (auth_token) |t| return bearerMatches(request, t);
    return originAllowed(headerValue(request, "origin"));
}

pub fn handleApiKill(io: std.Io, request: *http.Server.Request) !void {
    if (!mutationAuthorized(request)) {
        return request.respond("forbidden\n", .{ .status = .forbidden, .keep_alive = false });
    }
    var qbuf: [32]u8 = undefined;
    const port_str = queryParam(request.head.target, "port", &qbuf) orelse {
        return request.respond("missing port\n", .{ .status = .bad_request, .keep_alive = false });
    };
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        return request.respond("bad port\n", .{ .status = .bad_request, .keep_alive = false });
    };

    const result = switch (@import("builtin").os.tag) {
        .windows => kill_mod.Result.not_found,
        else => kill_mod.killPort(io, alloc, port, .{}),
    };
    refreshOnce(io);
    try request.respond(result.label(), .{
        .status = result.status(),
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

pub fn handleApiEdit(io: std.Io, request: *http.Server.Request) !void {
    if (!mutationAuthorized(request)) {
        return request.respond("forbidden\n", .{ .status = .forbidden, .keep_alive = false });
    }
    var qbuf: [128]u8 = undefined;
    var nbuf: [128]u8 = undefined;
    var cbuf: [64]u8 = undefined;
    const port_str = queryParam(request.head.target, "port", &qbuf) orelse {
        return request.respond("missing port\n", .{ .status = .bad_request, .keep_alive = false });
    };
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        return request.respond("bad port\n", .{ .status = .bad_request, .keep_alive = false });
    };
    const name = queryParam(request.head.target, "name", &nbuf) orelse "";
    const category = queryParam(request.head.target, "category", &cbuf) orelse "other";

    const hook = edit_hook orelse {
        return request.respond("no store\n", .{ .status = .internal_server_error, .keep_alive = false });
    };
    hook(alloc, port, name, category) catch {
        return request.respond("save failed\n", .{ .status = .conflict, .keep_alive = false });
    };
    refreshOnce(io);
    try request.respond("saved\n", .{ .keep_alive = false });
}

pub fn handleApiPorts(request: *http.Server.Request) !void {
    const snap = hub().current();
    try request.respond(snap.payload, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

test "json snapshot renders entries with escaping and pid null" {
    var buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const entries = [_]PortEntry{
        .{ .port = 4300, .name = "my app", .category = "web", .origin = .registered, .alive = true, .pid = 42 },
        .{ .port = 4400, .origin = .anonymous, .alive = false },
    };
    const tags = [_]db.TagColor{.{ .category = "web", .color = "#2563eb" }};
    try renderEntriesJson(&writer, entries[0..], tags[0..]);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"tags\":{\"web\":\"#2563eb\"}") != null);

    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"port\":4300") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"my app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"origin\":\"registered\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"alive\":true,\"pid\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"origin\":\"anonymous\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"pid\":null") != null);
}

test "json string escapes quotes and control chars" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeJsonString(&writer, "a\"b\\c\nd\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", writer.buffered());
}

test "query param extracts port and name" {
    var buf: [64]u8 = undefined;
    const t = "/api/kill?port=4300";
    try std.testing.expectEqualStrings("4300", queryParam(t, "port", &buf).?);
    const t2 = "/api/edit?port=4300&name=my%20app&category=web";
    try std.testing.expectEqualStrings("4300", queryParam(t2, "port", &buf).?);
    try std.testing.expectEqualStrings("my%20app", queryParam(t2, "name", &buf).?);
    try std.testing.expectEqualStrings("web", queryParam(t2, "category", &buf).?);
    try std.testing.expectEqual(@as(?[]const u8, null), queryParam("/api/kill", "port", &buf));
}

test "wants markdown only on explicit token" {
    try std.testing.expect(wantsMarkdown("text/markdown"));
    try std.testing.expect(wantsMarkdown("Text/Markdown"));
    try std.testing.expect(wantsMarkdown("application/json, text/markdown;q=0.9"));
    try std.testing.expect(!wantsMarkdown(null));
    try std.testing.expect(!wantsMarkdown(""));
    try std.testing.expect(!wantsMarkdown("*/*"));
    try std.testing.expect(!wantsMarkdown("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"));
}

test "markdown status page renders tables api reference and escapes pipes" {
    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const entries = [_]PortEntry{
        .{ .port = 4300, .name = "in|voice", .category = "api", .origin = .registered, .alive = true, .pid = 42 },
        .{ .port = 4400, .origin = .anonymous, .alive = true },
    };
    const reg = [_]ports.RegisteredApp{
        .{ .name = "in|voice", .port = 4300, .category = "api", .pid = 42 },
        .{ .name = "tunneled", .port = 4400, .category = "other", .pid = null, .tunnel = "box.tail.ts.net" },
    };
    try renderMarkdown(&writer, entries[0..], &reg);
    const out = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "# berth\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "| in\\|voice | http://in\\|voice.localhost/ | api | 4300 | yes |") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "| 4400 |  | anonymous | - |") != null);
    // Tunnel authority surfaces on the row of its port.
    try std.testing.expect(std.mem.indexOf(u8, out, "box.tail.ts.net") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "## api reference") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "curl http://localhost:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/api/edit?port=4300&name=myapp&category=web") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "http://myapp.localhost/some/path") != null);

    // Empty catalog renders the hint instead of a bare table header.
    var w2: std.Io.Writer = .fixed(&buf);
    try renderMarkdown(&w2, &.{}, &.{});
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "None yet.") != null);
}

test "origin allowlist admits loopback and rejects everything else" {
    try std.testing.expect(originAllowed(null));
    try std.testing.expect(originAllowed("http://localhost"));
    try std.testing.expect(originAllowed("http://localhost:8080"));
    try std.testing.expect(originAllowed("https://127.0.0.1"));
    try std.testing.expect(originAllowed("http://127.0.0.1:3000"));
    try std.testing.expect(originAllowed("https://[::1]:8817"));

    try std.testing.expect(!originAllowed("http://evil.com"));
    try std.testing.expect(!originAllowed("https://evil.com:8080"));
    // Suffix tricks must never pass as loopback.
    try std.testing.expect(!originAllowed("http://localhost.evil.com"));
    try std.testing.expect(!originAllowed("http://127.0.0.1.evil.com"));
    try std.testing.expect(!originAllowed("not-a-url"));
    try std.testing.expect(!originAllowed(""));
}

test "bearer comparison matches exactly" {
    const expected = "sekret";
    const pairs = [_]struct { got: []const u8, want: bool }{
        .{ .got = "sekret", .want = true },
        .{ .got = "sekrt", .want = false },
        .{ .got = "sekrets", .want = false },
        .{ .got = "", .want = false },
    };
    for (pairs) |p| {
        if (p.got.len != expected.len) {
            try std.testing.expect(!p.want);
            continue;
        }
        var diff: u8 = 0;
        for (p.got, expected) |a, b| diff |= a ^ b;
        try std.testing.expectEqual(p.want, diff == 0);
    }
}
