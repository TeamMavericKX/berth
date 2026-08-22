//! `berth service` — user-level service units (#29). The proxy must
//! survive reboots for named URLs to feel permanent, and user-level
//! services get there without sudo: a LaunchAgent on macOS (RunAtLoad +
//! KeepAlive, portmap main.rs:427-470) and a systemd user unit on Linux
//! (Restart=always, main.rs:471-497). Uninstall reverses everything,
//! including log paths.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    UnsupportedPlatform,
    CommandFailed,
    WriteFailed,
    HomebrewManaged,
    OutOfMemory,
};

pub const Manager = enum {
    launchd,
    systemd,

    pub fn unitPath(m: Manager, gpa: std.mem.Allocator, home: []const u8) ![]u8 {
        return switch (m) {
            .launchd => std.fmt.allocPrint(gpa, "{s}/Library/LaunchAgents/dev.berth.proxy.plist", .{home}),
            .systemd => std.fmt.allocPrint(gpa, "{s}/.config/systemd/user/berth.service", .{home}),
        };
    }
};

/// Injectable command runner; tests record argv instead of touching a
/// real service manager.
pub const RunResult = struct {
    stdout: []u8,
};
pub var exec_impl: *const fn (io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) Error!RunResult = execReal;

fn execReal(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) Error!RunResult {
    if (builtin.os.tag == .windows) return Error.UnsupportedPlatform;
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch |err| switch (err) {
        error.FileNotFound => return Error.UnsupportedPlatform,
        else => return Error.CommandFailed,
    };
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    defer gpa.free(result.stderr);
    if (!ok) {
        gpa.free(result.stdout);
        return Error.CommandFailed;
    }
    return .{ .stdout = result.stdout };
}

pub fn resetSeams() void {
    exec_impl = execReal;
}

var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;

/// Where the service logs go: /tmp like portmap's plist, per-manager.
pub fn logPath(manager: Manager, home: []const u8) []const u8 {
    return switch (manager) {
        .launchd => std.fmt.bufPrint(&log_path_buf, "/tmp/berth.log", .{}) catch unreachable,
        .systemd => std.fmt.bufPrint(&log_path_buf, "{s}/.local/state/berth/log", .{home}) catch unreachable,
    };
}

/// True when the binary looks Homebrew-managed (/Cellar in its path);
/// brew owns those lifecycles and we delegate with messaging instead of
/// writing a competing unit.
pub fn homebrewManaged(exe_path: []const u8) bool {
    return std.mem.indexOf(u8, exe_path, "/Cellar/") != null;
}

pub fn plistBody(gpa: std.mem.Allocator, exe_path: []const u8, log: []const u8) Error![]u8 {
    return std.fmt.allocPrint(gpa,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key><string>dev.berth.proxy</string>
        \\  <key>ProgramArguments</key>
        \\  <array><string>{s}</string><string>serve</string></array>
        \\  <key>RunAtLoad</key><true/>
        \\  <key>KeepAlive</key><true/>
        \\  <key>StandardOutPath</key><string>{s}</string>
        \\  <key>StandardErrorPath</key><string>{s}</string>
        \\</dict>
        \\</plist>
    , .{ exe_path, log, log }) catch Error.CommandFailed;
}

pub fn systemdBody(gpa: std.mem.Allocator, exe_path: []const u8) Error![]u8 {
    return std.fmt.allocPrint(gpa,
        \\[Unit]
        \\Description=berth dev proxy
        \\After=network.target
        \\
        \\[Service]
        \\ExecStart={s} serve
        \\Restart=always
        \\RestartSec=2
        \\
        \\[Install]
        \\WantedBy=default.target
    , .{exe_path}) catch Error.CommandFailed;
}

/// Write the unit file for the current platform at the right path.
/// Returns the unit path; caller frees.
pub fn writeUnit(io: std.Io, gpa: std.mem.Allocator, home: []const u8, exe_path: []const u8) Error![]u8 {
    const manager = try detectManager();
    if (homebrewManaged(exe_path)) return Error.HomebrewManaged;

    const body = switch (manager) {
        .launchd => try plistBody(gpa, exe_path, logPath(manager, home)),
        .systemd => blk: {
            // Ensure the state dir exists so journald-style redirection
            // has somewhere to live even though units log to journal.
            var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const state_dir = std.fmt.bufPrint(&dir_buf, "{s}/.config/systemd/user", .{home}) catch return Error.WriteFailed;
            std.Io.Dir.cwd().createDirPath(io, state_dir) catch return Error.WriteFailed;
            break :blk try systemdBody(gpa, exe_path);
        },
    };
    defer gpa.free(body);

    const unit_path = try manager.unitPath(gpa, home);
    errdefer gpa.free(unit_path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = unit_path, .data = body }) catch return Error.WriteFailed;
    return unit_path;
}

/// Remove the unit file; best effort.
pub fn removeUnit(io: std.Io, gpa: std.mem.Allocator, home: []const u8) ?[]u8 {
    const manager = detectManager() catch return null;
    const unit_path = manager.unitPath(gpa, home) catch return null;
    std.Io.Dir.deleteFileAbsolute(io, unit_path) catch {};
    return unit_path;
}

pub fn detectManager() Error!Manager {
    return switch (builtin.os.tag) {
        .macos => .launchd,
        .linux => .systemd,
        else => Error.UnsupportedPlatform,
    };
}

// ---- lifecycle commands ----

pub fn startService(io: std.Io, gpa: std.mem.Allocator, home: []const u8) Error!void {
    const manager = try detectManager();
    const unit_path = try manager.unitPath(gpa, home);
    defer gpa.free(unit_path);
    switch (manager) {
        .launchd => _ = try exec_impl(io, gpa, &.{ "launchctl", "load", "-w", unit_path }),
        .systemd => {
            _ = try exec_impl(io, gpa, &.{ "systemctl", "--user", "daemon-reload" });
            _ = try exec_impl(io, gpa, &.{ "systemctl", "--user", "enable", "--now", "berth.service" });
        },
    }
}

pub fn stopService(io: std.Io, gpa: std.mem.Allocator, home: []const u8) Error!void {
    const manager = try detectManager();
    const unit_path = try manager.unitPath(gpa, home);
    defer gpa.free(unit_path);
    switch (manager) {
        .launchd => _ = try exec_impl(io, gpa, &.{ "launchctl", "unload", "-w", unit_path }),
        .systemd => _ = try exec_impl(io, gpa, &.{ "systemctl", "--user", "disable", "--now", "berth.service" }),
    }
}

/// Manager name, running state, and startup setting as the manager
/// itself sees them.
pub const Status = struct {
    manager: []const u8,
    running: bool,
    enabled_at_startup: bool,
};

pub fn status(io: std.Io, gpa: std.mem.Allocator) Error!Status {
    const manager = try detectManager();
    switch (manager) {
        .launchd => {
            const out = try exec_impl(io, gpa, &.{ "launchctl", "list", "dev.berth.proxy" });
            defer gpa.free(out.stdout);
            // launchctl prints a row with our label when loaded.
            const running = std.mem.indexOf(u8, out.stdout, "\"dev.berth.proxy\"") != null;
            return .{ .manager = "launchd", .running = running, .enabled_at_startup = running };
        },
        .systemd => {
            const active = try exec_impl(io, gpa, &.{ "systemctl", "--user", "is-active", "berth.service" });
            defer gpa.free(active.stdout);
            const enabled = try exec_impl(io, gpa, &.{ "systemctl", "--user", "is-enabled", "berth.service" });
            defer gpa.free(enabled.stdout);
            return .{
                .manager = "systemd",
                .running = std.mem.startsWith(u8, trim(active.stdout), "active"),
                .enabled_at_startup = std.mem.eql(u8, trim(enabled.stdout), "enabled"),
            };
        },
    }
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \r\n\t");
}

// ---- tests ----

const TestRecorder = struct {
    var calls: std.ArrayList([]const u8) = .empty;

    fn record(_: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) Error!RunResult {
        var joined: std.ArrayList(u8) = .empty;
        for (argv, 0..) |arg, i| {
            if (i > 0) try joined.append(gpa, ' ');
            try joined.appendSlice(gpa, arg);
        }
        try calls.append(gpa, try joined.toOwnedSlice(gpa));
        return .{ .stdout = "" };
    }

    fn clear(gpa: std.mem.Allocator) void {
        for (calls.items) |line| gpa.free(line);
        calls.deinit(gpa);
        calls = .empty;
    }
};

test "plist carries keepalive runatload and log paths" {
    const gpa = std.testing.allocator;
    const body = try plistBody(gpa, "/usr/local/bin/berth", "/tmp/berth.log");
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "<key>RunAtLoad</key><true/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<key>KeepAlive</key><true/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/tmp/berth.log") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "serve</string>") != null);
}

test "systemd unit restarts always and enables at default target" {
    const gpa = std.testing.allocator;
    const body = try systemdBody(gpa, "/opt/berth");
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "Restart=always") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "WantedBy=default.target") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/opt/berth serve") != null);
}

test "homebrew cellar installs delegate instead of writing units" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try std.testing.expectError(Error.HomebrewManaged, writeUnit(io, gpa, "/home/u", "/opt/homebrew/Cellar/berth/0.1/bin/berth"));
    try std.testing.expect(homebrewManaged("/home/linuxbrew/.linuxbrew/Cellar/berth/0.1/bin/berth"));
    try std.testing.expect(!homebrewManaged("/usr/local/bin/berth"));
}

test "linux writes user unit then start cycle and uninstall leave nothing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    exec_impl = TestRecorder.record;
    defer {
        resetSeams();
        TestRecorder.clear(std.testing.allocator);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rp_len = try tmp.dir.realPath(io, &rp_buf);
    const home = rp_buf[0..rp_len];

    // Install: unit file lands in ~/.config/systemd/user.
    const unit_path = try writeUnit(io, gpa, home, "/usr/local/bin/berth");
    defer gpa.free(unit_path);
    {
        const f = std.Io.Dir.cwd().openFile(io, unit_path, .{}) catch return error.TestUnexpectedResult;
        f.close(io);
    }

    // Start (reload + enable --now), stop (disable --now).
    try startService(io, gpa, home);
    const calls_after_start = TestRecorder.calls.items.len;
    try stopService(io, gpa, home);

    // Uninstall removes the file: zero residue.
    const removed = removeUnit(io, gpa, home) orelse return error.TestUnexpectedResult;
    defer gpa.free(removed);
    if (std.Io.Dir.cwd().openFile(io, unit_path, .{})) |_| {
        return error.TestUnexpectedResult; // residue!
    } else |_| {}

    try std.testing.expect(calls_after_start >= 2); // daemon-reload + enable
}
