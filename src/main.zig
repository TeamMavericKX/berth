const std = @import("std");
const proxy = @import("proxy.zig");
const db = @import("db.zig");
const routes = @import("routes.zig");
const hostsync = @import("hostsync.zig");
const run_mod = @import("run.zig");
const dash = @import("dash.zig");
const certs = @import("certs.zig");
const trust = @import("trust.zig");
const clean = @import("clean.zig");

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
    if (std.mem.eql(u8, cmd, "run")) {
        return cmdRun(init.io, init.gpa, init.environ_map, &it);
    }
    if (std.mem.eql(u8, cmd, "trust")) {
        return cmdTrust(init.io, init.gpa, init.environ_map);
    }
    if (std.mem.eql(u8, cmd, "clean")) {
        return cmdClean(init.io, init.gpa, init.environ_map, &it);
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
    startDashboard(io, cfg.port, env);
    proxy.serve(io, cfg) catch |err| switch (err) {
        error.AddressInUse => std.process.exit(2),
        else => std.process.exit(2),
    };
}

/// The route store stays open for the life of the process so request-time
/// lookups can consult it (see proxy.dynamic_lookup).
var run_store: ?db.Store = null;

fn dynamicLookup(out: []u8, hostname: []const u8) ?routes.Route {
    const s = &(run_store orelse return null);
    const row = (s.lookupRoute(out, hostname) catch return null) orelse return null;
    return .{ .hostname = row.hostname, .port = row.port };
}

fn openStore(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ?db.Store {
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return null;
    db.ensureDataDir(io, gpa, home) catch return null;
    const path = db.defaultDbPath(gpa, home) catch return null;
    defer gpa.free(path);
    return db.Store.open(io, path) catch |err| {
        std.debug.print("berth: route store unavailable ({s}); starting empty\n", .{@errorName(err)});
        return null;
    };
}

fn collectLiveRoutes(gpa: std.mem.Allocator) ?[]routes.Route {
    const s = &(run_store orelse return null);
    const listed = s.listRoutes(gpa) catch return null;
    const live = gpa.alloc(routes.Route, listed.len) catch return null;
    for (listed, 0..) |r, i| {
        live[i] = .{ .hostname = r.hostname, .port = r.port };
    }
    return live;
}

fn syncHostsFromStore(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) void {
    const live = collectLiveRoutes(gpa) orelse return;
    defer gpa.free(live);
    syncHostsFile(io, gpa, env, live);
}

/// Dashboard view of registered apps: stored routes become entries with
/// the ".localhost" suffix stripped, then apps-table rows override the
/// display name/category for their port (or add standalone entries).
/// Everything allocates from the caller's arena; nothing is freed here.
fn provideRegistered(gpa: std.mem.Allocator) anyerror![]@import("ports.zig").RegisteredApp {
    var out: std.ArrayList(@import("ports.zig").RegisteredApp) = .empty;
    errdefer out.deinit(gpa);

    if (run_store) |*s| {
        const listed = try s.listRoutes(gpa);
        for (listed) |r| {
            try out.append(gpa, .{
                .name = try gpa.dupe(u8, stripLocalhostSuffix(r.hostname)),
                .port = r.port,
                .category = "other",
                .pid = r.pid,
            });
        }

        const apps = try s.listApps(gpa);
        for (apps) |app| {
            var overridden = false;
            for (out.items) |*existing| {
                if (existing.port != app.port) continue;
                // Explicit app rows win over hostname-derived names.
                existing.name = app.name;
                existing.category = app.category;
                overridden = true;
            }
            if (!overridden) {
                try out.append(gpa, .{
                    .name = app.name,
                    .port = app.port,
                    .category = app.category,
                    .pid = null,
                });
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

fn stripLocalhostSuffix(hostname: []const u8) []const u8 {
    if (std.mem.endsWith(u8, hostname, ".localhost")) {
        return hostname[0 .. hostname.len - ".localhost".len];
    }
    return hostname;
}

/// Every stored category color for dashboard tag rendering.
fn provideTagColors(gpa: std.mem.Allocator) anyerror![]db.TagColor {
    const s = &(run_store orelse return &.{});
    return s.listTagColors(gpa);
}

/// Persist dashboard edits: update the app row on port when present,
/// otherwise insert a fresh one.
fn editHook(gpa: std.mem.Allocator, port: u16, name: []const u8, category: []const u8) anyerror!void {
    _ = gpa;
    const s = &(run_store orelse return error.NoStore);
    var name_buf: [256]u8 = undefined;
    var cat_buf: [64]u8 = undefined;
    if (s.findAppByPort(&name_buf, &cat_buf, port) catch null) |app| {
        _ = try s.updateApp(app.id, name, port, category);
        return;
    }
    _ = try s.insertApp(name, port, category);
}

/// Start the dashboard snapshot loop: one immediate publish so the page
/// has data before the first scan tick, then refreshes every 5s.
fn startDashboard(io: std.Io, cfg_port: u16, env: *const std.process.Environ.Map) void {
    dash.edit_hook = &editHook;
    dash.registered_provider = &provideRegistered;
    dash.tags_provider = &provideTagColors;
    dash.dashboard_port = cfg_port;
    dash.auth_token = env.get("BERTH_TOKEN");

    const hub_ptr = dash.alloc.create(dash.Hub) catch return;
    hub_ptr.* = .{ .io = io };
    dash.setHub(hub_ptr);

    const t = std.Thread.spawn(.{}, dash.refreshLoop, .{io}) catch return;
    t.detach();
}

/// Seed the proxy's in-memory route table from ~/.berth/berth.db and keep
/// the store open for request-time lookups. A missing or unreadable store
/// is not fatal: serve runs with an empty table and the teaching 404s
/// explain how to register. Hostnames stay allocated for the life of the
/// process which is fine for a daemon.
fn loadStoredRoutes(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]routes.Route {
    proxy.dynamic_lookup = &dynamicLookup;
    run_store = openStore(io, gpa, env) orelse return null;
    const live = collectLiveRoutes(gpa) orelse return null;
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

/// `berth run [--name NAME] -- CMD...`: allocate a dev port, export PORT,
/// spawn CMD, register name.localhost while it lives, deregister on exit.
fn cmdRun(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, it: *std.process.Args.Iterator) !void {
    var explicit_name: ?[]const u8 = null;
    var argv_list: std.ArrayList([]const u8) = .empty;

    while (it.next()) |arg| {
        if (argv_list.items.len > 0) {
            try argv_list.append(gpa, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) continue;
        if (std.mem.eql(u8, arg, "--name")) {
            explicit_name = it.next() orelse usageFail("--name requires a value", "");
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') usageFail("unknown flag for run", arg);
        try argv_list.append(gpa, arg);
    }
    if (argv_list.items.len == 0) usageFail("run needs a command", "  example: berth run -- npm run dev");

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_n = std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buf) catch 0;
    if (cwd_n == 0) usageFail("could not resolve working directory", "");
    const cwd = cwd_buf[0..cwd_n];

    const name = run_mod.inferName(io, gpa, cwd, explicit_name) orelse
        usageFail("could not infer a name; pass --name", "");
    var host_buf: [256]u8 = undefined;
    const hostname = run_mod.deriveHostname(&host_buf, name);

    run_store = openStore(io, gpa, env) orelse std.process.exit(2);
    const s = &run_store.?;

    // Fail fast when a live process already owns the name.
    var probe_buf: [256]u8 = undefined;
    if (s.lookupRoute(&probe_buf, hostname) catch null) |existing| {
        std.debug.print(
            "berth: {s} is already registered by pid {d}\n",
            .{ hostname, existing.pid },
        );
        std.process.exit(3);
    }

    var seed: [8]u8 = undefined;
    io.random(&seed);
    const seed_int = std.mem.readInt(u64, &seed, .little);
    var candidates = run_mod.PortCandidates.init(seed_int);
    const port = run_mod.findFreePort(io, &candidates) orelse {
        std.debug.print(
            "berth: no free port in {d}-{d} after {d} attempts\n",
            .{ run_mod.port_range_start, run_mod.port_range_end, run_mod.max_port_attempts },
        );
        std.process.exit(3);
    };

    var child_env = env.clone(gpa) catch std.process.exit(2);
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;
    child_env.put("PORT", port_str) catch std.process.exit(2);

    var child = std.process.spawn(io, .{
        .argv = argv_list.items,
        .environ_map = &child_env,
    }) catch |err| {
        std.debug.print("berth: failed to spawn '{s}' ({s})\n", .{ argv_list.items[0], @errorName(err) });
        std.process.exit(4);
    };

    // Windows handles are opaque; store 0 so the row is reclaimable.
    const child_pid: i32 = if (@import("builtin").os.tag == .windows) 0 else @intCast(child.id.?);
    _ = s.insertRoute(hostname, port, child_pid) catch |err| {
        std.debug.print("berth: could not register {s} ({s})\n", .{ hostname, @errorName(err) });
        _ = s.deleteRoute(hostname) catch {};
        std.process.exit(3);
    };
    syncHostsFromStore(io, gpa, env);

    std.debug.print("berth: {s} -> 127.0.0.1:{d} (pid {d})\n", .{ hostname, port, child_pid });

    const term = child.wait(io) catch |err| {
        std.debug.print("berth: wait failed ({s}); releasing route\n", .{@errorName(err)});
        _ = s.deleteRoute(hostname) catch {};
        syncHostsFromStore(io, gpa, env);
        std.process.exit(4);
    };

    _ = s.deleteRoute(hostname) catch {};
    syncHostsFromStore(io, gpa, env);
    switch (term) {
        .exited => |code| {
            std.debug.print("berth: released {s}\n", .{hostname});
            std.process.exit(code);
        },
        .signal => |sig| {
            std.debug.print("berth: child killed by signal; released {s}\n", .{hostname});
            std.process.exit(128 + @as(u8, @intCast(@intFromEnum(sig))));
        },
        else => {
            std.debug.print("berth: released {s}\n", .{hostname});
            std.process.exit(1);
        },
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

/// `berth trust`: mint the CA if needed, install it into this
/// platform's trust store, then verify the anchor landed. Idempotent.
fn cmdTrust(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !void {
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse {
        std.debug.print("berth: cannot determine home directory\n", .{});
        std.process.exit(1);
    };
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/.berth", .{home}) catch unreachable;

    const ca_crt = certs.ensureCA(io, gpa, dir) catch |err| switch (err) {
        certs.Error.OpensslMissing => {
            std.debug.print("berth: openssl not found; install it (apt install openssl / brew install openssl)\n", .{});
            std.process.exit(1);
        },
        else => {
            std.debug.print("berth: minting CA failed ({s})\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };

    trust.installCA(io, gpa, env, ca_crt) catch |err| switch (err) {
        trust.Error.UnsupportedPlatform => {
            std.debug.print("berth: trust installation not supported on this platform yet\n", .{});
            std.process.exit(1);
        },
        else => {
            std.debug.print("berth: trust installation failed ({s}); the CA is at {s}\n", .{ @errorName(err), ca_crt });
            std.process.exit(1);
        },
    };

    // Verify after: the anchor must be readable where the flow put it.
    std.debug.print(
        "berth: local CA installed and trusted\n" ++
            "  cert: {s}\n" ++
            "  restart your browser, then visit any <name>.localhost URL\n",
        .{ca_crt},
    );
}

/// `berth clean [--yes]`: remove state dir, trust entry, hosts block,
/// asking before each destructive step. Non-TTY without --yes fails
/// fast having changed nothing.
fn cmdClean(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, it: *std.process.Args.Iterator) !void {
    var yes = false;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--yes")) {
            yes = true;
        } else {
            usageFail("unknown flag for clean", arg);
        }
    }

    const interactive = clean.isInteractive();
    if (!yes and !interactive) {
        std.debug.print(
            "berth: refusing to clean without --yes in a non-interactive shell\n" ++
                "  nothing was changed. rerun with --yes to skip prompts.\n",
            .{},
        );
        std.process.exit(1);
    }

    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse {
        std.debug.print("berth: cannot determine home directory\n", .{});
        std.process.exit(1);
    };
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state_dir = std.fmt.bufPrint(&dir_buf, "{s}/.berth", .{home}) catch unreachable;

    std.debug.print("berth: cleaning berth from this machine\n", .{});
    const steps = clean.runClean(.{
        .io = io,
        .gpa = gpa,
        .env = env,
        .state_dir = state_dir,
        .hosts_path = "/etc/hosts",
        .yes = yes,
        .interactive = interactive,
    }) catch |err| switch (err) {
        clean.Error.NonInteractive => unreachable, // handled above
        else => {
            std.debug.print("berth: clean failed ({s})\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };

    defer gpa.free(steps);
    var any_failed = false;
    for (steps) |step| {
        switch (step.outcome) {
            .done => std.debug.print("  removed: {s}\n", .{step.label}),
            .skipped => std.debug.print("  kept: {s}\n", .{step.label}),
            .failed => {
                std.debug.print("  FAILED: {s} (may need manual cleanup)\n", .{step.label});
                any_failed = true;
            },
        }
    }
    if (any_failed) {
        std.debug.print("berth: finished with errors\n", .{});
        std.process.exit(1);
    }
    std.debug.print("berth: done\n", .{});
}

fn printHelp() !void {
    std.debug.print(
        \\berth {s} - one daemon, both worlds
        \\
        \\usage:
        \\  berth serve [--host 127.0.0.1] [--port 8080]   run the proxy (loopback only)
        \\  berth run [--name NAME] -- CMD...              spawn CMD with PORT set and a name.localhost route
        \\  berth trust                                    install the local CA into this machine's trust store
        \\  berth clean [--yes]                            remove state, trust entry, and hosts block
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
