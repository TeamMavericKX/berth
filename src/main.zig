const std = @import("std");
const proxy = @import("proxy.zig");
const db = @import("db.zig");
const routes = @import("routes.zig");
const hostsync = @import("hostsync.zig");

pub const version = proxy.version;

pub fn main(init: std.process.Init) !void {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.skip();

    // Logging gate: debug lines exist only when BERTH_LOG asks for them.
    if (init.environ_map.get("BERTH_LOG") != null) {
        proxy.debug_enabled = true;
    }

    const cmd = it.next() orelse return printHelp();

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "version")) {
        return printVersion();
    }
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        return printHelp();
    }
    if (std.mem.eql(u8, cmd, "serve")) {
        return cmdServe(init.io, init.gpa, init.environ_map, &it);
    }

    usageFail("unknown command", cmd);
}

fn cmdServe(io: std.Io, init_gpa: std.mem.Allocator, env: *const std.process.Environ.Map, it: *std.process.Args.Iterator) !void {
    var cfg = proxy.Config{};

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const raw = it.next() orelse {
                usageFail("--port requires a number", "");
            };
            cfg.port = std.fmt.parseInt(u16, raw, 10) catch {
                usageFail("port must be a number between 1 and 65535", raw);
            };
        } else if (std.mem.eql(u8, arg, "--host")) {
            cfg.host = it.next() orelse usageFail("--host requires an address", "");
        } else {
            usageFail("unknown flag for serve", arg);
        }
    }

    // Loopback refusal is a usage error: the user asked for something
    // berth refuses by design. Exit 1 per docs/conventions.md.
    if (proxy.configRefusal(cfg)) |host| {
        std.debug.print(
            \\cannot bind {s}: berth binds loopback only
            \\  non-loopback exposure arrives later as an explicit flag.
            \\  use 127.0.0.1, ::1, or localhost
            \\
        , .{host});
        std.process.exit(1);
    }

    if (loadStoredRoutes(io, init_gpa, env)) |live| {
        syncHostsFile(io, init_gpa, env, live);
    }
    proxy.serve(io, cfg) catch |err| switch (err) {
        error.AddressInUse => std.process.exit(2),
        else => std.process.exit(2),
    };
}

/// Seed the proxy's in-memory route table from ~/.berth/berth.db. A missing
/// or unreadable store is not fatal: serve runs with an empty table and the
/// teaching 404s explain how to register. Hostnames stay allocated for the
/// life of the process which is fine for a daemon.
fn loadStoredRoutes(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]routes.Route {
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return null;
    db.ensureDataDir(io, gpa, home) catch return null;
    const path = db.defaultDbPath(gpa, home) catch return null;
    defer gpa.free(path);
    var store = db.Store.open(io, path) catch |err| {
        std.debug.print("berth: route store unavailable ({s}); starting empty\n", .{@errorName(err)});
        return null;
    };
    defer store.close();
    const listed = store.listRoutes(gpa) catch return null;
    const live = gpa.alloc(routes.Route, listed.len) catch return null;
    for (listed, 0..) |r, i| {
        live[i] = .{ .hostname = r.hostname, .port = r.port };
    }
    proxy.setLiveRoutes(live);
    return live;
}

/// Mirror stored routes into /etc/hosts inside the managed marker block.
/// BERTH_SYNC_HOSTS=0 opts out; an unwritable hosts file degrades to a
/// warning that shows the exact block to add by hand.
fn syncHostsFile(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, live: []const routes.Route) void {
    const enabled = if (env.get("BERTH_SYNC_HOSTS")) |v|
        !std.mem.eql(u8, v, "0")
    else
        true;
    const outcome = hostsync.sync(io, gpa, "/etc/hosts", live, enabled) catch |err| {
        var names = gpa.alloc([]const u8, live.len) catch return;
        defer gpa.free(names);
        for (live, 0..) |r, i| names[i] = r.hostname;
        const block = hostsync.buildBlock(gpa, names) catch return;
        defer gpa.free(block);
        std.debug.print(
            "berth: cannot update /etc/hosts ({s})\n" ++
                "  resolution needs these entries; add them manually or rerun once with sudo:\n{s}",
            .{ @errorName(err), block },
        );
        return;
    };
    switch (outcome) {
        .synced => std.debug.print("berth: synced {d} host entr{s} into /etc/hosts\n", .{
            live.len,
            if (live.len == 1) "y" else "ies",
        }),
        .unchanged, .opted_out, .unsupported_platform => {},
    }
}

fn usageFail(msg: []const u8, detail: []const u8) noreturn {
    if (detail.len > 0) {
        std.debug.print("{s}: '{s}'\n  run: berth --help\n", .{ msg, detail });
    } else {
        std.debug.print("{s}\n  run: berth --help\n", .{msg});
    }
    std.process.exit(1);
}

fn printVersion() !void {
    std.debug.print("berth {s}\n", .{version});
}

fn printHelp() !void {
    std.debug.print(
        \\berth {s} - one daemon, both worlds
        \\
        \\usage:
        \\  berth serve [--host 127.0.0.1] [--port 8080]   run the proxy (loopback only)
        \\  berth version                                  print version
        \\  berth help                                     this text
        \\
        \\the proxy routes by Host header; named URLs arrive in M1.
        \\agents: markdown endpoints arrive in M2.
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
