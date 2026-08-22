const std = @import("std");

/// One row in every berth view: CLI table, dashboard, markdown. The
/// source chain decides `origin`; only registered apps can be down.
pub const PortEntry = struct {
    port: u16,
    name: []const u8 = "",
    category: []const u8 = "other",
    origin: Origin,
    alive: bool,
    pid: ?i32 = null,

    pub const Origin = enum {
        registered,
        container,
        catalog,
        anonymous,

        pub fn label(self: Origin) []const u8 {
            return switch (self) {
                .registered => "registered",
                .container => "container",
                .catalog => "catalog",
                .anonymous => "anonymous",
            };
        }
    };
};

/// Well-known dev-server ports shown even when nothing listens.
pub const catalog_entry = struct {
    port: u16,
    name: []const u8,
    category: []const u8,
};

pub const default_catalog = [_]catalog_entry{
    .{ .port = 3000, .name = "react", .category = "web" },
    .{ .port = 5173, .name = "vite", .category = "web" },
    .{ .port = 8000, .name = "django", .category = "web" },
    .{ .port = 8080, .name = "tomcat", .category = "web" },
    .{ .port = 4000, .name = "phoenix", .category = "web" },
};

pub const RegisteredApp = struct {
    name: []const u8,
    port: u16,
    category: []const u8,
    pid: ?i32,
    /// tailscale authority like "box.tail1234.ts.net" when exposed.
    tunnel: ?[]const u8 = null,
};

pub const ContainerPort = struct {
    port: u16,
    name: []const u8,
};

/// Priority chain per port: registered > container > catalog > anonymous.
/// Registered apps whose process is gone stay visible as down entries.
/// Container ports outside [scan_start, scan_end] are appended so nothing
/// discovered goes missing from the view.
pub fn buildPortEntries(
    gpa: std.mem.Allocator,
    registered: []const RegisteredApp,
    containers: []const ContainerPort,
    open_ports: []const u16,
    scan_start: u16,
    scan_end: u16,
) ![]PortEntry {
    var entries: std.ArrayList(PortEntry) = .empty;
    errdefer entries.deinit(gpa);

    // Index open ports for membership tests.
    var open_set: std.AutoHashMapUnmanaged(u16, void) = .empty;
    defer open_set.deinit(gpa);
    for (open_ports) |p| try open_set.put(gpa, p, {});

    for (registered) |app| {
        try entries.append(gpa, .{
            .port = app.port,
            .name = app.name,
            .category = app.category,
            .origin = .registered,
            .alive = open_set.contains(app.port),
            .pid = app.pid,
        });
    }

    // Containers win over catalog/anonymous but never overwrite registered.
    for (containers) |cn| {
        if (findRegistered(entries.items, cn.port)) continue;
        try upsertContainer(gpa, &entries, cn);
    }

    for (default_catalog) |known| {
        if (findRegistered(entries.items, known.port)) continue;
        if (findContainer(entries.items, known.port)) continue;
        if (open_set.contains(known.port)) {
            try appendUnique(gpa, &entries, .{
                .port = known.port,
                .name = known.name,
                .category = known.category,
                .origin = .catalog,
                .alive = true,
            });
        }
    }

    for (open_ports) |p| {
        if (p < scan_start or p > scan_end) continue;
        if (entries.items.len != 0 and findAny(entries.items, p)) continue;
        try appendUnique(gpa, &entries, .{
            .port = p,
            .origin = .anonymous,
            .alive = true,
        });
    }

    sortAliveFirst(entries.items);
    return entries.toOwnedSlice(gpa);
}

fn findRegistered(entries: []const PortEntry, port: u16) bool {
    for (entries) |e| {
        if (e.origin == .registered and e.port == port) return true;
    }
    return false;
}

fn findContainer(entries: []const PortEntry, port: u16) bool {
    for (entries) |e| {
        if (e.origin == .container and e.port == port) return true;
    }
    return false;
}

fn findAny(entries: []const PortEntry, port: u16) bool {
    for (entries) |e| {
        if (e.port == port) return true;
    }
    return false;
}

fn upsertContainer(gpa: std.mem.Allocator, entries: *std.ArrayList(PortEntry), cn: ContainerPort) !void {
    for (entries.items) |*e| {
        if (e.port == cn.port and e.origin != .registered) {
            e.origin = .container;
            e.name = cn.name;
            e.alive = true;
            return;
        }
    }
    try appendUnique(gpa, entries, .{
        .port = cn.port,
        .name = cn.name,
        .origin = .container,
        .alive = true,
    });
}

fn appendUnique(gpa: std.mem.Allocator, entries: *std.ArrayList(PortEntry), entry: PortEntry) !void {
    for (entries.items) |e| {
        if (e.port == entry.port) return;
    }
    try entries.append(gpa, entry);
}

/// Live entries sorted by port first; down apps trail after them.
fn sortAliveFirst(entries: []PortEntry) void {
    std.mem.sort(PortEntry, entries, {}, struct {
        fn less(_: void, a: PortEntry, b: PortEntry) bool {
            if (a.alive != b.alive) return a.alive;
            return a.port < b.port;
        }
    }.less);
}

test "registered beats container beats catalog beats anonymous" {
    const registered = [_]RegisteredApp{
        .{ .name = "myapp", .port = 4300, .category = "web", .pid = 100 },
    };
    const containers = [_]ContainerPort{
        .{ .port = 4300, .name = "clashing-box" },
        .{ .port = 4400, .name = "redis-box" },
    };
    const open = [_]u16{ 4300, 4400, 4500 };

    const entries = try buildPortEntries(std.testing.allocator, &registered, &containers, &open, 4000, 4999);
    defer std.testing.allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    // 4300: registered wins over the clashing container.
    try std.testing.expectEqualStrings("myapp", entries[0].name);
    try std.testing.expectEqual(PortEntry.Origin.registered, entries[0].origin);
    try std.testing.expect(entries[0].alive);
    // 4400: container wins over nothing else.
    try std.testing.expectEqualStrings("redis-box", entries[1].name);
    try std.testing.expectEqual(PortEntry.Origin.container, entries[1].origin);
    // 4500: plain anonymous.
    try std.testing.expectEqual(PortEntry.Origin.anonymous, entries[2].origin);
    try std.testing.expectEqualStrings("", entries[2].name);
}

test "catalog name appears only when port is live" {
    const open_live = [_]u16{5173};
    const entries = try buildPortEntries(std.testing.allocator, &.{}, &.{}, &open_live, 1000, 9999);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("vite", entries[0].name);
    try std.testing.expectEqual(PortEntry.Origin.catalog, entries[0].origin);

    // Same port closed: no catalog ghost rows.
    const none = try buildPortEntries(std.testing.allocator, &.{}, &.{}, &.{}, 1000, 9999);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "down registered apps render after live entries sorted by port" {
    const registered = [_]RegisteredApp{
        .{ .name = "dead-one", .port = 4805, .category = "web", .pid = null },
        .{ .name = "dead-two", .port = 4801, .category = "web", .pid = 7 },
        .{ .name = "alive", .port = 4810, .category = "web", .pid = 8 },
    };
    const open = [_]u16{4810};
    const entries = try buildPortEntries(std.testing.allocator, &registered, &.{}, &open, 4000, 4999);
    defer std.testing.allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expect(entries[0].alive);
    try std.testing.expectEqual(@as(u16, 4810), entries[0].port);
    // Down block sorted by port ascending.
    try std.testing.expect(!entries[1].alive);
    try std.testing.expectEqual(@as(u16, 4801), entries[1].port);
    try std.testing.expect(!entries[2].alive);
    try std.testing.expectEqual(@as(u16, 4805), entries[2].port);
    // Dead pid with no listener is down even when pid recorded.
    try std.testing.expect(!entries[1].alive);
}

test "out of range container ports still appear" {
    const containers = [_]ContainerPort{
        .{ .port = 55, .name = "sys-box" },
        .{ .port = 44200, .name = "in-range" },
    };
    const open = [_]u16{44200};
    const entries = try buildPortEntries(std.testing.allocator, &.{}, &containers, &open, 4000, 4999);
    defer std.testing.allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    // Out-of-range container appended despite scan window.
    const ports = [_]u16{ entries[0].port, entries[1].port };
    try std.testing.expectEqualSlices(u16, &.{ 55, 44200 }, &ports);
}
