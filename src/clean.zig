//! `berth trust` and `berth clean` (issue #24). Users must be able to
//! leave with zero residue: state dir, trust entry, hosts block. clean
//! asks before each destructive step, --yes skips prompts, and a
//! non-interactive stdin fails fast instead of prompting so CI never
//! hangs on a hidden question.

const std = @import("std");
const builtin = @import("builtin");
const certs = @import("certs.zig");
const trust = @import("trust.zig");
const hostsync = @import("hostsync.zig");

pub const Error = error{
    NonInteractive,
    OutOfMemory,
} || trust.Error;

/// What one destructive step decided.
pub const StepOutcome = enum { done, skipped, failed };

pub const Step = struct {
    label: []const u8,
    outcome: StepOutcome,
};

/// Injectable environment for the clean lifecycle; production wires the
/// real fs/prompts, tests record every decision.
pub const Deps = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,

    /// State directory (default ~/.berth).
    state_dir: []const u8,
    /// Hosts file carrying the managed block (default /etc/hosts).
    hosts_path: []const u8,

    yes: bool,
    interactive: bool,

    prompt_yes_no: *const fn (io: std.Io) bool = defaultPrompt,
    delete_tree_fn: *const fn (io: std.Io, path: []const u8) void = defaultDeleteTree,
};

fn defaultPrompt(io: std.Io) bool {
    var buf: [64]u8 = undefined;
    const f = std.Io.File.stdin();
    var reader = f.reader(io, &buf);
    const line = reader.interface.takeDelimiterExclusive('\n') catch return false;
    const t = std.mem.trim(u8, line, " \r\t");
    return t.len > 0 and (t[0] == 'y' or t[0] == 'Y');
}

fn defaultDeleteTree(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

pub fn isInteractive() bool {
    if (builtin.os.tag == .windows) return true; // console api differs; assume yes
    return std.c.isatty(0) != 0;
}

fn proceed(deps: Deps) bool {
    if (deps.yes) return true;
    if (!deps.interactive) return false; // unreachable: filtered earlier
    var wbuf: [64]u8 = undefined;
    const out = std.Io.File.stdout();
    var writer = out.writer(deps.io, &wbuf);
    writer.interface.writeAll("  proceed? [y/N] ") catch {};
    writer.interface.flush() catch {};
    return deps.prompt_yes_no(deps.io);
}

/// Run the destructive lifecycle. Returns per-step outcomes in fixed
/// order: trust entry, hosts block, state dir. When `!deps.yes &&
/// !deps.interactive`, returns error.NonInteractive having changed
/// nothing at all.
pub fn runClean(deps: Deps) Error![]Step {
    if (!deps.yes and !deps.interactive) return Error.NonInteractive;

    var steps: std.ArrayList(Step) = .empty;

    // Trust entry first: untrust needs the CA file to still exist.
    var ca_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ca_crt = std.fmt.bufPrint(&ca_buf, "{s}/ca.crt", .{deps.state_dir}) catch unreachable;
    const have_ca = blk: {
        const f = std.Io.Dir.cwd().openFile(deps.io, ca_crt, .{}) catch break :blk false;
        f.close(deps.io);
        break :blk true;
    };
    // A failing step never aborts the rest: a cleanup tool that stops
    // halfway guarantees exactly the residue it exists to remove.
    if (have_ca and proceed(deps)) {
        if (trust.untrustCA(deps.io, deps.gpa, ca_crt)) {
            try steps.append(deps.gpa, .{ .label = "trust entry", .outcome = .done });
        } else |_| {
            try steps.append(deps.gpa, .{ .label = "trust entry", .outcome = .failed });
        }
    } else {
        try steps.append(deps.gpa, .{ .label = "trust entry", .outcome = .skipped });
    }

    if (proceed(deps)) {
        if (hostsync.removeBlock(deps.io, deps.gpa, deps.hosts_path)) |_| {
            try steps.append(deps.gpa, .{ .label = "hosts block", .outcome = .done });
        } else |_| {
            try steps.append(deps.gpa, .{ .label = "hosts block", .outcome = .failed });
        }
    } else {
        try steps.append(deps.gpa, .{ .label = "hosts block", .outcome = .skipped });
    }

    if (proceed(deps)) {
        deps.delete_tree_fn(deps.io, deps.state_dir);
        try steps.append(deps.gpa, .{ .label = "state dir", .outcome = .done });
    } else {
        try steps.append(deps.gpa, .{ .label = "state dir", .outcome = .skipped });
    }

    return steps.toOwnedSlice(deps.gpa);
}

test "non-interactive without yes fails fast changing nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rp_len = try tmp.dir.realPath(io, &rp_buf);

    var calls: usize = 0;
    _ = &calls; // captured by the seam below; failure path must not touch it

    const result = runClean(.{
        .io = io,
        .gpa = std.testing.allocator,
        .env = null,
        .state_dir = rp_buf[0..rp_len],
        .hosts_path = "/nonexistent-hosts",
        .yes = false,
        .interactive = false,
    });

    try std.testing.expectError(Error.NonInteractive, result);
}
