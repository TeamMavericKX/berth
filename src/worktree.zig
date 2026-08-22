//! Git worktree detection for per-branch hostname prefixes (#26).
//! Parallel agent sessions across linked worktrees are a berth-native
//! use case; colliding hostnames would break the core promise.
//!
//! Heuristic (portless auto.ts:170-232): a checkout is a LINKED
//! worktree only when its git-dir differs from the common dir. The
//! root checkout never gets a prefix — even on a feature branch —
//! which is the portless lesson: developers do not expect their main
//! clone's URLs to change just because the branch has a slash in it.

const std = @import("std");
const builtin = @import("builtin");
const run_mod = @import("run.zig");

pub const Error = error{
    UnsupportedPlatform,
    CommandFailed,
};

pub const RunResult = struct {
    stdout: []u8,
};

/// Injectable command runner. Production shells out to git; tests
/// point this elsewhere or force failure to exercise the filesystem
/// fallback.
pub var exec_impl: *const fn (io: std.Io, gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) Error!RunResult = execGit;

fn execGit(io: std.Io, gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) Error!RunResult {
    if (builtin.os.tag == .windows) return Error.UnsupportedPlatform;
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    full.append(gpa, "git") catch return Error.CommandFailed;
    full.appendSlice(gpa, argv) catch return Error.CommandFailed;

    const result = std.process.run(gpa, io, .{
        .argv = full.items,
        .cwd = .{ .path = cwd },
    }) catch |err| switch (err) {
        error.FileNotFound => return Error.UnsupportedPlatform,
        else => return Error.CommandFailed,
    };
    // Exit code matters: rev-parse fails outside repos. Streams are
    // ours to release either way.
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

fn resetSeams() void {
    exec_impl = execGit;
}

/// Sanitized branch prefix for cwd, or null when none applies: root
/// checkouts, detached HEAD, main/master anywhere, and anything that
/// smells wrong all yield null. Caller owns the returned slice.
pub fn prefixFor(io: std.Io, gpa: std.mem.Allocator, cwd: []const u8) ?[]u8 {
    const out = prefixForImpl(io, gpa, cwd) catch return null;
    resetSeams();
    return out;
}

fn trim(s: []u8) []const u8 {
    return std.mem.trim(u8, s, " \r\n\t");
}

fn prefixForImpl(io: std.Io, gpa: std.mem.Allocator, cwd: []const u8) Error!?[]u8 {
    // Linked worktree iff git-dir differs from the common dir. The
    // --path-format flag keeps both absolute on every modern git; older
    // ones fail here and drop to the filesystem fallback below.
    const git_dir_raw = exec_impl(io, gpa, cwd, &.{ "rev-parse", "--path-format=absolute", "--git-dir" }) catch |err| switch (err) {
        Error.UnsupportedPlatform => return fallbackPrefix(io, gpa, cwd),
        else => return null, // not a repo: no prefix is correct
    };
    const git_dir = trim(git_dir_raw.stdout);
    defer gpa.free(git_dir_raw.stdout);

    const common_raw = exec_impl(io, gpa, cwd, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }) catch return null;
    const common_dir = trim(common_raw.stdout);
    defer gpa.free(common_raw.stdout);

    if (std.mem.eql(u8, git_dir, common_dir)) return null; // root checkout

    const branch_raw = try exec_impl(io, gpa, cwd, &.{ "symbolic-ref", "--short", "HEAD" });
    defer gpa.free(branch_raw.stdout);
    const branch = trim(branch_raw.stdout);

    return sanitizeBranch(gpa, branch);
}

fn sanitizeBranch(gpa: std.mem.Allocator, branch: []const u8) ?[]u8 {
    const last = lastSegment(branch);
    if (last.len == 0) return null;
    if (std.mem.eql(u8, last, "main") or std.mem.eql(u8, last, "master")) return null;
    var clean_buf: [128]u8 = undefined;
    const sanitized = run_mod.sanitizeInto(&clean_buf, last);
    if (sanitized.len == 0 or sanitized.len > 64) return null;
    return gpa.dupe(u8, sanitized) catch null;
}

fn lastSegment(branch: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, branch, '/') orelse return branch;
    return branch[idx + 1 ..];
}

/// No git binary: parse .git plus HEAD by hand (portless auto.ts
/// filesystem path). A directory .git means root checkout; a file
/// .git pointing into .git/worktrees/<n> means linked.
fn fallbackPrefix(io: std.Io, gpa: std.mem.Allocator, cwd: []const u8) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dot_git = std.fmt.bufPrint(&buf, "{s}/.git", .{cwd}) catch return null;

    const st = blk: {
        const f = std.Io.Dir.cwd().openFile(io, dot_git, .{}) catch return null;
        defer f.close(io);
        break :blk f.stat(io) catch return null;
    };
    if (st.kind == .directory) return null; // root checkout

    var contents_buf: [1024]u8 = undefined;
    const len = readSmallFile(io, dot_git, &contents_buf) orelse return null;
    const line = std.mem.trim(u8, contents_buf[0..len], " \r\n\t");
    const marker = "gitdir:";
    if (!std.mem.startsWith(u8, line, marker)) return null;
    const gitdir = std.mem.trim(u8, line[marker.len..], " \t");
    // Linked worktrees live under <repo>/.git/worktrees/<name>.
    if (std.mem.indexOf(u8, gitdir, "/.git/worktrees/") == null) return null;

    var head_buf: [std.fs.max_path_bytes]u8 = undefined;
    const head_path = std.fmt.bufPrint(&head_buf, "{s}/HEAD", .{gitdir}) catch return null;
    var head_contents: [512]u8 = undefined;
    const hlen = readSmallFile(io, head_path, &head_contents) orelse return null;
    const head = std.mem.trim(u8, head_contents[0..hlen], " \r\n\t");
    const ref_prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, head, ref_prefix)) return null; // detached
    return sanitizeBranch(gpa, head[ref_prefix.len..]);
}

fn readSmallFile(io: std.Io, path: []const u8, buf: []u8) ?usize {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, buf, 0) catch return null;
    return n;
}

test "fixture worktrees yield distinct prefixes; root stays bare" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rp_len = try tmp.dir.realPath(io, &rp_buf);
    const root = rp_buf[0..rp_len];
    var buf_a: [std.fs.max_path_bytes + 8]u8 = undefined;
    const repo = try std.fmt.bufPrint(&buf_a, "{s}/repo", .{root});
    var buf_wt: [std.fs.max_path_bytes + 16]u8 = undefined;
    const wt = try std.fmt.bufPrint(&buf_wt, "{s}/wt", .{root});
    var buf_wm: [std.fs.max_path_bytes + 16]u8 = undefined;
    const wt_main = try std.fmt.bufPrint(&buf_wm, "{s}/wtmain", .{root});

    try std.Io.Dir.cwd().createDirPath(io, repo);
    resetSeams();

    // git init -b develop; empty commit; two linked worktrees.
    try git(io, gpa, repo, &.{ "init", "-b", "develop", "." });
    try git(io, gpa, repo, &.{ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "x" });
    try git(io, gpa, repo, &.{ "worktree", "add", "-b", "feature/auth", wt });
    try git(io, gpa, repo, &.{ "worktree", "add", "-b", "main", wt_main });

    // Root on a feature-looking branch stays unprefixed (portless lesson).
    try git(io, gpa, repo, &.{ "checkout", "-b", "feature/root-branch" });
    try expectNullPrefix(io, gpa, repo);

    const p1 = prefixFor(io, gpa, wt) orelse return error.TestUnexpectedResult;
    defer gpa.free(p1);
    try std.testing.expectEqualStrings("auth", p1);

    try expectNullPrefix(io, gpa, wt_main); // main never prefixed
}

fn expectNullPrefix(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) !void {
    if (prefixFor(io, gpa, dir)) |p| {
        gpa.free(p);
        return error.TestUnexpectedResult;
    }
}

fn git(io: std.Io, gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !void {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, "git");
    try full.appendSlice(gpa, argv);
    const result = try std.process.run(gpa, io, .{ .argv = full.items, .cwd = .{ .path = cwd } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

test "filesystem fallback parses gitdir file without git" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rp_len = try tmp.dir.realPath(io, &rp_buf);
    const root = rp_buf[0..rp_len];

    // Fake layout: repo/.git/worktrees/wt1/HEAD + wt/.git pointer file.
    var gd_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const gitdir = try std.fmt.bufPrint(&gd_buf, "{s}/repo/.git/worktrees/wt1", .{root});
    try std.Io.Dir.cwd().createDirPath(io, gitdir);
    var head_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const head_path = try std.fmt.bufPrint(&head_buf, "{s}/HEAD", .{gitdir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = head_path, .data = "ref: refs/heads/feature/auth\n" });

    var wt_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const wtdir = try std.fmt.bufPrint(&wt_buf, "{s}/wt", .{root});
    try std.Io.Dir.cwd().createDirPath(io, wtdir);
    var dot_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const dot_git = try std.fmt.bufPrint(&dot_buf, "{s}/.git", .{wtdir});
    var content_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const content = try std.fmt.bufPrint(&content_buf, "gitdir: {s}\n", .{gitdir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dot_git, .data = content });

    exec_impl = struct {
        fn f(_: std.Io, _: std.mem.Allocator, _: []const u8, _: []const []const u8) Error!RunResult {
            return Error.UnsupportedPlatform;
        }
    }.f;

    const p = prefixFor(io, gpa, wtdir) orelse return error.TestUnexpectedResult;
    defer gpa.free(p);
    try std.testing.expectEqualStrings("auth", p);

    // Root checkout (.git directory): null even via fallback.
    var repo_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const repodir = try std.fmt.bufPrint(&repo_buf, "{s}/repo", .{root});
    try expectNullPrefix(io, gpa, repodir);
}
