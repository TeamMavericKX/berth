//! Port injection for frameworks that ignore the PORT env var (#27).
//! Silent wrong-port failures are the worst failure mode in this
//! category: the app boots, berth routes to a dead port, and nothing
//! explains why. The comptime table names each framework's real flags;
//! anything this file cannot confidently parse stays untouched, which
//! is a deliberate refusal rather than a guess.

const std = @import("std");

pub const Framework = struct {
    /// Binary name as it appears in argv.
    name: []const u8,
    /// Subcommands where injection applies (empty means always).
    subcommands: []const []const u8,
    /// Flags that take a port value.
    value_flags: []const []const u8,
    /// Flag forcing strict-port semantics so the app fails loudly
    /// instead of silently drifting to another port.
    strict_flag: ?[]const u8 = null,
};

/// Frameworks known to ignore PORT, with their server subcommands and
/// value-taking port flags, from each CLI's documented surface.
pub const frameworks = [_]Framework{
    .{
        .name = "vite",
        .subcommands = &.{ "dev", "preview" },
        .value_flags = &.{ "--port", "-p" },
        .strict_flag = "--strictPort",
    },
    .{
        .name = "vp",
        .subcommands = &.{ "dev", "preview" },
        .value_flags = &.{ "--port", "-p" },
        .strict_flag = "--strictPort",
    },
    .{
        .name = "react-router",
        .subcommands = &.{"dev"},
        .value_flags = &.{"--port"},
    },
    .{
        .name = "rsbuild",
        .subcommands = &.{ "dev", "preview" },
        .value_flags = &.{"--port"},
    },
    .{
        .name = "astro",
        .subcommands = &.{ "dev", "preview" },
        .value_flags = &.{ "--port", "-p" },
    },
    .{
        .name = "ng",
        .subcommands = &.{"serve"},
        .value_flags = &.{"--port"},
    },
    .{
        .name = "react-native",
        .subcommands = &.{"start"},
        .value_flags = &.{ "--port", "--port=" },
    },
    .{
        .name = "expo",
        .subcommands = &.{"start"},
        .value_flags = &.{ "--port", "--port=" },
    },
};

/// Package runners whose prefixes we see through to find the real
/// framework binary underneath (cli-utils.ts:1143-1150).
pub const package_runners = [_][]const u8{ "npx", "bunx", "pnpx", "yarn", "pnpm" };

/// Runner keywords that precede the real binary name.
pub const runner_keywords = [_][]const u8{ "dlx", "x", "exec" };

/// Commands that run our target somewhere else entirely; injecting a
/// port there would be fiction.
pub const delegators = [_][]const u8{ "sudo", "ssh", "docker", "kubectl", "nohup", "setsid", "watchexec" };

pub const RefusalReason = enum {
    compound_command,
    env_prefix,
    comment,
    delegation,
    unknown_grammar,
};

pub const Decision = union(enum) {
    /// Nothing to do: no framework matched, or a port flag already
    /// exists and the user wins.
    none,
    /// Recognized but refused so users can audit the decision.
    refused: RefusalReason,
    /// Append `--flag PORT` (and the strict flag when known) at the
    /// end of the command line.
    inject: struct {
        strict_flag: ?[]const u8 = null,
    },
};

fn isValueFlag(fw: *const Framework, token: []const u8) bool {
    for (fw.value_flags) |f| {
        if (f[f.len - 1] == '=') {
            if (std.mem.startsWith(u8, token, f)) return true;
        } else if (std.mem.eql(u8, f, token)) return true;
        // "--port=1234" style carries its value inline.
        if (std.mem.startsWith(u8, token, f) and
            token.len > f.len and token[f.len] == '=') return true;
    }
    return false;
}

fn isDelegator(token: []const u8) bool {
    for (delegators) |d| if (std.mem.eql(u8, d, token)) return true;
    return false;
}

fn findFramework(name: []const u8) ?*const Framework {
    for (&frameworks) |*fw| if (std.mem.eql(u8, fw.name, name)) return fw;
    return null;
}

/// Pure decision over the command line after `berth run --`.
pub fn decide(argv: []const []const u8) Decision {
    if (argv.len == 0) return .none;

    // Whole-command refusals first: shell grammar changes what a port
    // even means, so we never parse inside these.
    for (argv) |tok| {
        if (tok.len == 0) continue;
        if (std.mem.indexOfAny(u8, tok, "&|;") != null) return .{ .refused = .compound_command };
        if (tok[0] == '#') return .{ .refused = .comment };
    }

    var i: usize = 0;

    // Env prefixes change the meaning of everything after them.
    if (std.mem.indexOfScalar(u8, argv[0], '=') != null) return .{ .refused = .env_prefix };

    // One delegator prefix is refused outright.
    if (isDelegator(argv[i])) return .{ .refused = .delegation };

    // See through package runners, their keywords, and their flags
    // (bunx --bun, pnpm --dir x): stop at the first non-flag token.
    while (i < argv.len and (isRunner(argv[i]) or isKeyword(argv[i]) or isFlagLike(argv[i]))) {
        i += 1;
    }
    if (i >= argv.len) return .{ .refused = .unknown_grammar };

    // The token here must be a known framework binary; anything else
    // (a package.json script, a random tool) stays untouched.
    const fw = findFramework(argv[i]) orelse return .{ .refused = .unknown_grammar };
    i += 1;

    // Optional server subcommand. A different subcommand means this
    // invocation does not serve (vite build); nothing to inject.
    if (i < argv.len and !isFlagLike(argv[i])) {
        var serves = fw.subcommands.len == 0;
        for (fw.subcommands) |sc| {
            if (std.mem.eql(u8, sc, argv[i])) serves = true;
        }
        if (!serves) return .none;
        i += 1;
    }

    // An explicit port already present means the user wins.
    while (i < argv.len) : (i += 1) {
        if (isValueFlag(fw, argv[i])) return .none;
    }

    return .{ .inject = .{ .strict_flag = fw.strict_flag } };
}

fn isFlagLike(tok: []const u8) bool {
    return tok.len > 0 and tok[0] == '-';
}

fn isRunner(token: []const u8) bool {
    for (package_runners) |r| if (std.mem.eql(u8, r, token)) return true;
    return false;
}

fn isKeyword(token: []const u8) bool {
    for (runner_keywords) |k| if (std.mem.eql(u8, k, token)) return true;
    return false;
}

fn expectInject(argv: []const []const u8, strict: ?[]const u8) !void {
    const d = decide(argv);
    try std.testing.expect(d == .inject);
    if (d == .inject) {
        try std.testing.expectEqualSlices(u8, strict orelse "", d.inject.strict_flag orelse "");
    }
}

fn expectRefused(argv: []const []const u8, reason: RefusalReason) !void {
    const d = decide(argv);
    try std.testing.expect(d == .refused);
    if (d == .refused) try std.testing.expectEqual(reason, d.refused);
}

test "every framework injects on its server subcommand" {
    inline for (&frameworks) |fw| {
        var buf: [2][]const u8 = .{ fw.name, fw.subcommands[0] };
        try expectInject(&buf, fw.strict_flag);
        // Bare invocation (no subcommand) also serves.
        const bare = [1][]const u8{fw.name};
        try expectInject(&bare, fw.strict_flag);
    }
}

test "runners are seen through to the framework" {
    try expectInject(&.{ "npx", "vite" }, "--strictPort");
    try expectInject(&.{ "pnpm", "dlx", "astro", "preview" }, null);
    try expectInject(&.{ "yarn", "react-native", "start" }, null);
    try expectInject(&.{ "bunx", "--bun", "vite", "dev" }, "--strictPort");
}

test "existing port flags win over injection" {
    try std.testing.expect(decide(&.{ "vite", "dev", "-p", "3000" }) == .none);
    try std.testing.expect(decide(&.{ "vite", "--port=4173" }) == .none);
    try std.testing.expect(decide(&.{ "ng", "serve", "--port", "4200" }) == .none);
}

test "non-serving subcommands stay untouched" {
    try std.testing.expect(decide(&.{ "vite", "build" }) == .none);
    try std.testing.expect(decide(&.{ "astro", "check" }) == .none);
}

test "every refusal case from the list" {
    try expectRefused(&.{ "npm", "run", "dev", "&&", "echo", "hi" }, .compound_command);
    try expectRefused(&.{ "PORT=1", "npm", "run", "dev" }, .env_prefix);
    try expectRefused(&.{ "#", "just", "a", "comment" }, .comment);
    try expectRefused(&.{ "sudo", "vite", "dev" }, .delegation);
    // Package scripts are opaque: the real server hides behind a name
    // we cannot see through, so this is an explicit refusal.
    try expectRefused(&.{ "yarn", "dev" }, .unknown_grammar);
    try expectRefused(&.{ "npm", "run", "dev" }, .unknown_grammar);
}
