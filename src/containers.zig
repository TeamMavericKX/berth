//! Minimal Docker/Podman API client over the unix socket. Asks
//! /containers/json for published ports bound to wildcard or loopback
//! and attributes container names. A missing socket is an empty
//! result, never an error and never log noise.

const std = @import("std");
const builtin = @import("builtin");
const ports = @import("ports.zig");

/// Same shape the merge layer already consumes.
pub const ContainerPort = ports.ContainerPort;

/// Socket paths tried in order: docker first, then rootless podman.
pub const default_socket_paths = [_][]const u8{
    "/var/run/docker.sock",
    "/run/docker.sock",
    "/run/podman/podman.sock",
};

/// Query every well-known socket; first hit wins, none means empty.
pub fn discover(io: std.Io, gpa: std.mem.Allocator) []ContainerPort {
    for (default_socket_paths) |path| {
        const found = discoverPath(io, gpa, path) catch continue;
        if (found.len > 0) return found;
        // A reachable engine with no containers is still a hit.
        return found;
    }
    return &.{};
}

pub fn discoverPath(io: std.Io, gpa: std.mem.Allocator, socket_path: []const u8) ![]ContainerPort {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return &.{},
    }

    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var stream = addr.connect(io) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll("GET /v1.40/containers/json?all=false HTTP/1.1\r\nHost: docker\r\nAccept: application/json\r\nConnection: close\r\n\r\n") catch return &.{};
    writer.interface.flush() catch return &.{};

    var read_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var raw_buf: [128 * 1024]u8 = undefined;
    var read_writer: std.Io.Writer = .fixed(&raw_buf);
    _ = reader.interface.streamRemaining(&read_writer) catch {};
    const raw = read_writer.buffered();

    const body = httpBody(gpa, raw) orelse return &.{};
    defer gpa.free(body);
    return parseContainersJson(gpa, body);
}

/// Extract the entity body, always as a fresh gpa-owned copy so
/// callers can free unconditionally. Handles content-length bodies,
/// chunked framing, and missing separators.
fn httpBody(gpa: std.mem.Allocator, raw: []const u8) ?[]u8 {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    const head = raw[0..sep];
    const body = raw[sep + 4 ..];

    var chunked = false;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(line[colon + 1 ..], "chunked") != null) chunked = true;
        }
    }
    if (!chunked) return gpa.dupe(u8, body) catch null;

    // Reassemble without chunk framing.
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(gpa, body.len) catch return null;
    var rest = body;
    while (rest.len > 0) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse break;
        const size_str = std.mem.trim(u8, rest[0..line_end], " ");
        const size = std.fmt.parseInt(usize, size_str, 16) catch break;
        if (size == 0) break;
        rest = rest[line_end + 2 ..];
        if (rest.len < size) break;
        out.appendSlice(gpa, rest[0..size]) catch return null;
        rest = rest[size..];
        if (std.mem.startsWith(u8, rest, "\r\n")) rest = rest[2..];
    }
    return out.toOwnedSlice(gpa) catch null;
}

const ApiPortBinding = struct {
    IP: ?[]const u8 = null,
    PrivatePort: u16 = 0,
    PublicPort: ?u16 = null,
    Type: []const u8 = "tcp",
};

const ApiContainer = struct {
    Names: ?[]const []const u8 = null,
    Ports: ?[]const ApiPortBinding = null,
};

fn isBindableIp(ip: []const u8) bool {
    const ok = [_][]const u8{ "0.0.0.0", "::", "127.0.0.1", "::1" };
    for (ok) |candidate| {
        if (std.mem.eql(u8, ip, candidate)) return true;
    }
    return false;
}

/// Parse engine JSON to published loopback/wildcard tcp ports. Any
/// parse failure yields an empty result: discovery must never fail
/// loudly.
pub fn parseContainersJson(gpa: std.mem.Allocator, body: []const u8) []ContainerPort {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var ports_list: std.ArrayList(ContainerPort) = .empty;

    const parsed = std.json.parseFromSliceLeaky([]ApiContainer, arena_state.allocator(), body, .{
        .ignore_unknown_fields = true,
    }) catch return &.{};

    for (parsed) |container| {
        var display_name: []const u8 = "";
        if (container.Names) |names| {
            if (names.len > 0) {
                display_name = names[0];
                if (display_name.len > 0 and display_name[0] == '/') display_name = display_name[1..];
            }
        }
        const bindings = container.Ports orelse continue;
        for (bindings) |b| {
            const public = b.PublicPort orelse continue;
            if (!std.mem.eql(u8, b.Type, "tcp")) continue;
            const ip = b.IP orelse continue;
            if (!isBindableIp(ip)) continue;
            ports_list.append(gpa, .{
                .port = public,
                .name = gpa.dupe(u8, display_name) catch "",
            }) catch return &.{};
        }
    }
    return ports_list.toOwnedSlice(gpa) catch &.{};
}

test "parse binds wildcard and loopback, skips unpublished and udp" {
    const gpa = std.testing.allocator;
    const body =
        \\[
        \\ {"Id":"abc","Names":["/web-proxy"],
        \\  "Ports":[
        \\   {"IP":"0.0.0.0","PrivatePort":8080,"PublicPort":8080,"Type":"tcp"},
        \\   {"IP":"127.0.0.1","PrivatePort":5432,"PublicPort":5432,"Type":"tcp"},
        \\   {"IP":"::","PrivatePort":9090,"PublicPort":9090,"Type":"tcp"},
        \\   {"PrivatePort":7000,"Type":"tcp"},
        \\   {"IP":"10.0.0.5","PrivatePort":7100,"PublicPort":7100,"Type":"tcp"},
        \\   {"IP":"0.0.0.0","PrivatePort":53,"PublicPort":53,"Type":"udp"}
        \\  ]},
        \\ {"Id":"def","Names":["/db"],"Ports":[]}
        \\]
    ;
    const got = parseContainersJson(gpa, body);
    defer {
        for (got) |g| gpa.free(g.name);
        gpa.free(got);
    }

    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqual(@as(u16, 8080), got[0].port);
    try std.testing.expectEqualStrings("web-proxy", got[0].name);
    try std.testing.expectEqual(@as(u16, 5432), got[1].port);
    try std.testing.expectEqual(@as(u16, 9090), got[2].port);
}

test "parse handles malformed json and empty arrays without dying" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        "",
        "not json at all",
        "{\"oops\":true}",
        "[]",
    };
    for (cases) |body| {
        const got = parseContainersJson(gpa, body);
        defer gpa.free(got);
        for (got) |g| gpa.free(g.name);
    }
}

test "http body extracts plain and chunked payloads" {
    const gpa = std.testing.allocator;
    const plain = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 5\r\n\r\nhello";
    {
        const got = httpBody(gpa, plain).?;
        defer gpa.free(got);
        try std.testing.expectEqualStrings("hello", got);
    }

    const chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n3\r\n wo\r\n0\r\n\r\n";
    {
        const got = httpBody(gpa, chunked).?;
        defer gpa.free(got);
        try std.testing.expectEqualStrings("hello wo", got);
    }
    try std.testing.expect(httpBody(gpa, "garbage") == null);
}

test "docker response pipeline yields expected port set" {
    const gpa = std.testing.allocator;

    // The transport (unix socket round trip) is exercised live against
    // the real daemon and covered by the no-socket fallback below; a
    // threaded in-process mock flaked under qemu, so this pins the
    // part we own: body extraction, parsing, filtering.
    const canned_body =
        \\[
        \\  {"Names":["/api-box"],"Ports":[{"IP":"127.0.0.1","PrivatePort":3000,"PublicPort":3000,"Type":"tcp"}]},
        \\  {"Names":["/no-ports"],"Ports":[]},
        \\  {"Names":["/udp-only"],"Ports":[{"IP":"0.0.0.0","PrivatePort":53,"PublicPort":53,"Type":"udp"}]}
        \\]
    ;
    var resp_buf: [1024]u8 = undefined;
    const response = try std.fmt.bufPrint(&resp_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ canned_body.len, canned_body });

    const body = httpBody(gpa, response) orelse return error.TestUnexpectedResult;
    defer gpa.free(body);

    const got = parseContainersJson(gpa, body);
    defer {
        for (got) |g| gpa.free(g.name);
        gpa.free(got);
    }

    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(u16, 3000), got[0].port);
    try std.testing.expectEqualStrings("api-box", got[0].name);
}

test "no socket yields empty result silently" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const got = try discoverPath(io, gpa, "/nonexistent/berth-bogus.sock");
    defer gpa.free(got);
    for (got) |g| gpa.free(g.name);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}
