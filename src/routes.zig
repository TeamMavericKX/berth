//! Route types and host matching. The four-tier match order is load-bearing:
//! it disambiguates apps sharing a tunnel hostname on different ports while
//! keeping wildcard subdomains as the last resort. Ported from portless
//! findRoute (proxy.ts:113-122); receipts in docs/research/portless-dossier.md.

const std = @import("std");

pub const Route = struct {
    /// Canonical hostname, e.g. "myapp.localhost". Lowercase.
    hostname: []const u8,
    /// Backend port on loopback.
    port: u16,
    /// Optional tunnel authority like "node.tailnet.ts.net" or
    /// "node.tailnet.ts.net:8443". Populated by tunnel integration in M4;
    /// matching supports it from day one so the schema never migrates.
    tunnel_authority: ?[]const u8 = null,
};

/// Normalize an authority for comparison: lowercase, and treat an explicit
/// ":443" as the default HTTPS port that URL parsing strips. Without this a
/// mixed-case Host or an explicit :443 misses exact matches.
pub fn normalizeAuthority(authority: []const u8) []const u8 {
    // Buffer is caller-owned in spirit; we return slices into it via a
    // thread-local scratch to keep the match function allocation-free.
    const S = struct {
        threadlocal var buf: [256]u8 = undefined;
        threadlocal var len: usize = 0;
    };
    const lower_len = @min(authority.len, S.buf.len);
    for (authority[0..lower_len], 0..) |c, i| S.buf[i] = std.ascii.toLower(c);
    var out = S.buf[0..lower_len];
    if (std.mem.endsWith(u8, out, ":443")) out = out[0 .. out.len - 4];
    S.len = out.len;
    return S.buf[0..S.len];
}

fn authorityOf(route: Route) ?[]const u8 {
    const ta = route.tunnel_authority orelse return null;
    return normalizeAuthority(ta);
}

/// Find the route matching a request's Host (or :authority) header.
///
/// Match order:
///   1. exact hostname
///   2. tunnel authority including port
///   3. tunnel hostname ignoring port
///   4. wildcard subdomain: host ends with "." + route.hostname
pub fn findRoute(routes: []const Route, raw_host: []const u8) ?Route {
    if (routes.len == 0) return null;
    const authority = normalizeAuthority(raw_host);
    const hostname = firstSegmentBeforePort(authority);

    for (routes) |r| {
        if (std.mem.eql(u8, r.hostname, hostname)) return r;
    }
    for (routes) |r| {
        if (authorityOf(r)) |ta| {
            if (std.mem.eql(u8, ta, authority)) return r;
        }
    }
    for (routes) |r| {
        if (authorityOf(r)) |ta| {
            if (std.mem.eql(u8, firstSegmentBeforePort(ta), hostname)) return r;
        }
    }
    for (routes) |r| {
        if (hostIsSubdomain(hostname, r.hostname)) return r;
    }
    return null;
}

fn firstSegmentBeforePort(authority: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return authority;
    // Guard against IPv6-ish literals without brackets; route hostnames are
    // DNS names in practice, so a trailing :digits is always a port here.
    if (idx + 1 >= authority.len) return authority;
    for (authority[idx + 1 ..]) |c| {
        if (!std.ascii.isDigit(c)) return authority;
    }
    return authority[0..idx];
}

fn hostIsSubdomain(host: []const u8, base: []const u8) bool {
    if (host.len <= base.len) return false;
    if (!std.mem.endsWith(u8, host, base)) return false;
    return host[host.len - base.len - 1] == '.';
}

test "normalize lowercases and strips explicit 443" {
    try expectEql("myapp.localhost", normalizeAuthority("MyApp.LocalHost"));
    try expectEql("node.ts.net", normalizeAuthority("Node.ts.net:443"));
    try expectEql("node.ts.net:8443", normalizeAuthority("NODE.TS.NET:8443"));
}

fn expectEql(expected: []const u8, actual: []const u8) !void {
    try std.testing.expectEqualStrings(expected, actual);
}

test "tier one exact hostname wins" {
    const routes = [_]Route{
        .{ .hostname = "api.app.localhost", .port = 4001 },
        .{ .hostname = "app.localhost", .port = 4000 },
    };
    const got = findRoute(&routes, "app.localhost").?;
    try std.testing.expectEqual(@as(u16, 4000), got.port);
}

test "exact match is case insensitive" {
    const routes = [_]Route{.{ .hostname = "app.localhost", .port = 4000 }};
    const got = findRoute(&routes, "APP.LOCALHOST").?;
    try std.testing.expectEqual(@as(u16, 4000), got.port);
}

test "explicit port 443 on host still matches exactly" {
    const routes = [_]Route{.{ .hostname = "app.localhost", .port = 4000 }};
    const got = findRoute(&routes, "app.localhost:443").?;
    try std.testing.expectEqual(@as(u16, 4000), got.port);
}

test "non-default port on host does not break exact match" {
    const routes = [_]Route{.{ .hostname = "app.localhost", .port = 4000 }};
    const got = findRoute(&routes, "app.localhost:8080").?;
    try std.testing.expectEqual(@as(u16, 4000), got.port);
}

test "tier two tunnel authority with port disambiguates" {
    const routes = [_]Route{
        .{ .hostname = "a.app.localhost", .port = 4001, .tunnel_authority = "node.ts.net:8443" },
        .{ .hostname = "b.app.localhost", .port = 4002, .tunnel_authority = "node.ts.net:10000" },
    };
    const got = findRoute(&routes, "node.ts.net:10000").?;
    try std.testing.expectEqual(@as(u16, 4002), got.port);
}

test "tier three tunnel hostname ignoring port keeps resolving" {
    const routes = [_]Route{
        .{ .hostname = "a.app.localhost", .port = 4001, .tunnel_authority = "node.ts.net:8443" },
        .{ .hostname = "other.app.localhost", .port = 4002 },
    };
    const got = findRoute(&routes, "NODE.TS.NET").?;
    try std.testing.expectEqual(@as(u16, 4001), got.port);
}

test "tier four wildcard subdomain matches last" {
    const routes = [_]Route{.{ .hostname = "app.localhost", .port = 4000 }};
    const got = findRoute(&routes, "api.app.localhost").?;
    try std.testing.expectEqual(@as(u16, 4000), got.port);

    const deep = findRoute(&routes, "a.b.app.localhost").?;
    try std.testing.expectEqual(@as(u16, 4000), deep.port);
}

test "wildcard does not match bare or prefix lookalikes" {
    const routes = [_]Route{.{ .hostname = "app.localhost", .port = 4000 }};
    try std.testing.expectEqual(@as(?Route, null), findRoute(&routes, "app.localhost.evil.io"));
    try std.testing.expectEqual(@as(?Route, null), findRoute(&routes, "notapp.localhost"));
}

test "empty route table finds nothing" {
    try std.testing.expectEqual(@as(?Route, null), findRoute(&.{}, "anything.localhost"));
}
