const std = @import("std");

pub const max_port_attempts = 50;
pub const port_range_start = 4000;
pub const port_range_end = 4999;

/// Turn a user-facing name into a route hostname. Names that already carry
/// a dot pass through untouched so custom TLDs keep working.
pub fn deriveHostname(buf: []u8, name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.') != null) {
        const n = @min(name.len, buf.len);
        @memcpy(buf[0..n], name[0..n]);
        return buf[0..n];
    }
    var clean_buf: [256]u8 = undefined;
    const sanitized = sanitizeInto(&clean_buf, name);
    const suffix = ".localhost";
    if (sanitized.len + suffix.len > buf.len) return buf[0..0];
    @memcpy(buf[0..sanitized.len], sanitized);
    @memcpy(buf[sanitized.len .. sanitized.len + suffix.len], suffix);
    return buf[0 .. sanitized.len + suffix.len];
}

pub fn sanitizeInto(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |c| {
        if (n >= buf.len) break;
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '.';
        buf[n] = if (ok) std.ascii.toLower(c) else '-';
        n += 1;
    }
    var start: usize = 0;
    while (start < n and buf[start] == '-') start += 1;
    while (n > start and buf[n - 1] == '-') n -= 1;
    return buf[start..n];
}

/// Name resolution order: --name flag, then package.json walking up,
/// then the directory's basename. Returns null when nothing applies.
pub fn inferName(
    io: std.Io,
    gpa: std.mem.Allocator,
    cwd: []const u8,
    explicit: ?[]const u8,
) ?[]u8 {
    if (explicit) |name| {
        if (name.len == 0) return null;
        return gpa.dupe(u8, name) catch null;
    }

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var current = cwd;

    while (true) {
        const pkg_path = std.fmt.bufPrint(&dir_buf, "{s}/package.json", .{current}) catch break;
        if (readPkgName(io, gpa, pkg_path)) |name| return name;

        const slash = std.mem.lastIndexOfScalar(u8, current, '/') orelse break;
        if (slash == 0) break;
        current = current[0..slash];
    }

    const base = std.fs.path.basename(cwd);
    if (base.len == 0) return null;
    return gpa.dupe(u8, base) catch null;
}

fn readPkgName(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024)) catch return null;
    defer gpa.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return null;
    defer parsed.deinit();

    const name_val = parsed.value.object.get("name") orelse return null;
    if (name_val != .string) return null;
    const raw = name_val.string;

    // npm scope names register as their bare package name.
    const bare = if (raw.len > 0 and raw[0] == '@')
        if (std.mem.indexOfScalar(u8, raw, '/')) |slash| raw[slash + 1 ..] else raw
    else
        raw;
    if (bare.len == 0) return null;
    return gpa.dupe(u8, bare) catch null;
}

/// Uniform pseudo-random candidates across the dev-server range.
pub const PortCandidates = struct {
    state: u64,

    pub fn init(seed: u64) PortCandidates {
        return .{ .state = seed };
    }

    pub fn next(self: *PortCandidates) ?u16 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        const spread: u64 = port_range_end - port_range_start + 1;
        const v = (self.state >> 33) % spread;
        return port_range_start + @as(u16, @intCast(v));
    }
};

/// Bind-probe a port: free means we could own it for a moment.
pub fn tryBind(io: std.Io, port: u16) bool {
    const net = std.Io.net;
    const addr = net.IpAddress.parseIp4("127.0.0.1", port) catch return false;
    var listener = addr.listen(io, .{}) catch return false;
    listener.deinit(io);
    return true;
}

/// First bindable port from the candidate stream, giving up after
/// max_port_attempts probes. Null means the range is exhausted.
pub fn findFreePort(io: std.Io, candidates: anytype) ?u16 {
    var tries: usize = 0;
    while (tries < max_port_attempts) : (tries += 1) {
        const port = candidates.next() orelse return null;
        if (tryBind(io, port)) return port;
    }
    return null;
}

test "derive hostname appends localhost and sanitizes" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("myapp.localhost", deriveHostname(&buf, "myapp"));
    try std.testing.expectEqualStrings("my-app.localhost", deriveHostname(&buf, "My App!"));
    try std.testing.expectEqualStrings("api.myapp.crab", deriveHostname(&buf, "api.myapp.crab"));
}

test "sanitize strips trailing dashes and lowercases" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("my-app", sanitizeInto(&buf, "_My App!_"));
    try std.testing.expectEqualStrings("", sanitizeInto(&buf, "___"));
}

test "find free port gives up after exactly fifty probes" {
    const io = std.testing.io;

    const Scripted = struct {
        ports: []const u16,
        calls: usize = 0,
        pub fn next(self: *@This()) ?u16 {
            if (self.calls >= self.ports.len) return null;
            const p = self.ports[self.calls];
            self.calls += 1;
            return p;
        }
    };

    const net = std.Io.net;
    const held_addr = net.IpAddress.parseIp4("127.0.0.1", 4555) catch unreachable;
    var holder = held_addr.listen(io, .{}) catch return error.SkipZigTest;
    defer holder.deinit(io);

    const taken = [_]u16{4555} ** max_port_attempts;
    var all_taken = Scripted{ .ports = &taken };
    try std.testing.expectEqual(@as(?u16, null), findFreePort(io, &all_taken));
    try std.testing.expectEqual(max_port_attempts, all_taken.calls);

    var free_late = Scripted{ .ports = &.{ 4555, 4555, 4556 } };
    const picked = findFreePort(io, &free_late);
    try std.testing.expectEqual(@as(?u16, 4556), picked);
    try std.testing.expectEqual(@as(usize, 3), free_late.calls);
}

test "port candidates stay inside the dev range" {
    var cands = PortCandidates.init(42);
    for (0..200) |_| {
        const p = cands.next().?;
        try std.testing.expect(p >= port_range_start and p <= port_range_end);
    }
}
