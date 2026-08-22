//! Certificate minting by spawning the openssl binary — no X.509
//! construction lives in this tree. An EC CA is created once under
//! ~/.berth/certs/ and per-host leaves are signed from it, cached on
//! disk and reused while valid.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    OpensslMissing,
    OpensslFailed,
    UnsupportedPlatform,
};

/// Overridable for tests.
pub var openssl_bin: []const u8 = "openssl";

pub const Paths = struct {
    ca_key: []const u8,
    ca_crt: []const u8,
    leaf_key: []const u8,
    leaf_crt: []const u8,
    ext_file: []const u8,
};

/// All artifacts for one host live in dir. Caller owns nothing: slices
/// point into a per-call arena pattern, so callers pass a gpa whose
/// results they free or an arena they reset.
pub fn pathsFor(gpa: std.mem.Allocator, dir: []const u8, hostname: []const u8) !Paths {
    return .{
        .ca_key = try std.fmt.allocPrint(gpa, "{s}/ca.key", .{dir}),
        .ca_crt = try std.fmt.allocPrint(gpa, "{s}/ca.crt", .{dir}),
        .leaf_key = try std.fmt.allocPrint(gpa, "{s}/{s}.key", .{ dir, hostname }),
        .leaf_crt = try std.fmt.allocPrint(gpa, "{s}/{s}.crt", .{ dir, hostname }),
        .ext_file = try std.fmt.allocPrint(gpa, "{s}/{s}.ext", .{ dir, hostname }),
    };
}

/// Ensure the CA exists and a valid leaf is signed for hostname.
/// Returns the leaf cert path. Idempotent: existing valid files are
/// reused untouched (mint twice = identical bytes).
pub fn ensureLeaf(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, hostname: []const u8) ![]const u8 {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return Error.UnsupportedPlatform,
    }

    // Nested creation: walk the components (dirs here are shallow).
    ensureDir(io, dir) catch return Error.OpensslFailed;

    const p = try pathsFor(gpa, dir, hostname);

    if (!fileExists(io, p.ca_crt) or !fileExists(io, p.ca_key)) {
        _ = runOpenssl(io, gpa, &.{ "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", p.ca_key }) catch |err| return err;
        const ca_ok = runOpenssl(io, gpa, &.{ "req", "-x509", "-new", "-key", p.ca_key, "-sha256", "-days", "825", "-subj", "/CN=berth local CA/O=berth", "-out", p.ca_crt }) catch |err| return err;
        if (!ca_ok) {
            reportLastFailure(gpa);
            return Error.OpensslFailed;
        }
    } else if (!caValid(io, gpa, p)) {
        // Regenerate the whole CA rather than risk mixed identities.
        std.Io.Dir.deleteFileAbsolute(io, p.ca_crt) catch {};
        std.Io.Dir.deleteFileAbsolute(io, p.ca_key) catch {};
        return ensureLeaf(io, gpa, dir, hostname);
    }

    if (fileExists(io, p.leaf_crt) and fileExists(io, p.leaf_key)) {
        if (leafValid(io, gpa, p)) return p.leaf_crt;
        std.Io.Dir.deleteFileAbsolute(io, p.leaf_crt) catch {};
        std.Io.Dir.deleteFileAbsolute(io, p.leaf_key) catch {};
    }

    var key_buf: [128]u8 = undefined;
    const cn_subject = std.fmt.bufPrint(&key_buf, "/CN={s}/O=berth", .{hostname}) catch return Error.OpensslFailed;

    _ = runOpenssl(io, gpa, &.{ "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", p.leaf_key }) catch |err| return err;

    var ext_buf: [256]u8 = undefined;
    const ext_content = std.fmt.bufPrint(&ext_buf, "subjectAltName=DNS:{s},DNS:*.{s}\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n", .{ hostname, hostname }) catch return Error.OpensslFailed;
    writeFile(io, p.ext_file, ext_content);

    // x509 -req needs a CSR file path; keep it beside the ext file.
    const csr_path = try std.fmt.allocPrint(gpa, "{s}/{s}.csr", .{ dir, hostname });
    _ = runOpenssl(io, gpa, &.{ "req", "-new", "-key", p.leaf_key, "-subj", cn_subject, "-out", csr_path }) catch |err| return err;

    _ = runOpenssl(io, gpa, &.{ "x509", "-req", "-in", csr_path, "-CA", p.ca_crt, "-CAkey", p.ca_key, "-CAcreateserial", "-days", "30", "-sha256", "-extfile", p.ext_file, "-out", p.leaf_crt }) catch |err| return err;

    std.Io.Dir.deleteFileAbsolute(io, csr_path) catch {};
    std.Io.Dir.deleteFileAbsolute(io, p.ext_file) catch {};
    return p.leaf_crt;
}

/// Verify leaf chains to our CA and is still current. Cheap spawn of
/// `openssl verify` with its own checkend semantics folded in.
fn leafValid(io: std.Io, gpa: std.mem.Allocator, p: Paths) bool {
    const rc = runOpenssl(io, gpa, &.{ "verify", "-CAfile", p.ca_crt, p.leaf_crt }) catch return false;
    if (!rc) return false;
    return checkEnd(io, gpa, p.leaf_crt);
}

fn caValid(io: std.Io, gpa: std.mem.Allocator, p: Paths) bool {
    return checkEnd(io, gpa, p.ca_crt);
}

fn checkEnd(io: std.Io, gpa: std.mem.Allocator, crt: []const u8) bool {
    return runOpenssl(io, gpa, &.{ "x509", "-checkend", "86400", "-noout", "-in", crt }) catch false;
}

fn ensureDir(io: std.Io, path: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var buf: [512]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    _ = z;
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn writeFile(io: std.Io, path: []const u8, content: []const u8) void {
    var f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return;
    defer f.close(io);
    var buf: [512]u8 = undefined;
    var w = f.writer(io, &buf);
    w.interface.writeAll(content) catch {};
    w.interface.flush() catch {};
}

/// Spawn openssl and swallow its output. Returns true on exit 0.
/// Stderr of the most recent failed openssl invocation; owned here so
/// callers can surface a real diagnosis instead of a bare exit code.
pub var last_failure_output: ?[]u8 = null;

fn runOpenssl(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) !bool {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    full.append(gpa, openssl_bin) catch return Error.OpensslFailed;
    full.appendSlice(gpa, argv) catch return Error.OpensslFailed;

    // run() pipes both streams (stdin ignored): nothing we spawn can
    // inject bytes into whatever protocol stream owns our fds, and
    // failures keep their actual stderr for diagnosis.
    const result = std.process.run(gpa, io, .{ .argv = full.items }) catch |err| switch (err) {
        error.FileNotFound => return Error.OpensslMissing,
        else => return Error.OpensslFailed,
    };
    defer gpa.free(result.stdout);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (ok) {
        gpa.free(result.stderr);
    } else {
        if (last_failure_output) |prev| gpa.free(prev);
        last_failure_output = result.stderr;
    }
    return ok;
}

/// Print and release the stashed failure output. Call at error sites.
pub fn reportLastFailure(gpa: std.mem.Allocator) void {
    if (last_failure_output) |s| {
        std.debug.print("openssl said:\n{s}", .{s});
        gpa.free(s);
        last_failure_output = null;
    }
}

test "paths assemble per host without clobbering ca names" {
    const gpa = std.testing.allocator;
    const p = try pathsFor(gpa, "/home/u/.berth/certs", "myapp.localhost");
    defer {
        gpa.free(p.ca_key);
        gpa.free(p.ca_crt);
        gpa.free(p.leaf_key);
        gpa.free(p.leaf_crt);
        gpa.free(p.ext_file);
    }
    try std.testing.expectEqualStrings("/home/u/.berth/certs/ca.crt", p.ca_crt);
    try std.testing.expectEqualStrings("/home/u/.berth/certs/myapp.localhost.key", p.leaf_key);
}

test "missing openssl binary produces actionable error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    openssl_bin = "/nonexistent/berth-openssl-missing";
    defer openssl_bin = "openssl";

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const result = ensureLeaf(io, a, "/tmp/berth-cert-test-missing", "x.localhost");
    try std.testing.expectError(Error.OpensslMissing, result);
}

test "mint twice produces identical files then verifies against ca" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rp_len = try tmp.dir.realPath(io, &rp_buf);
    var dir_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}", .{rp_buf[0..rp_len]});

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const leaf1 = try ensureLeaf(io, a, dir, "alpha.test");
    const stat1 = try std.Io.Dir.cwd().statFile(io, leaf1, .{});

    const leaf2 = try ensureLeaf(io, a, dir, "alpha.test");
    try std.testing.expectEqualStrings(leaf1, leaf2);
    const stat2 = try std.Io.Dir.cwd().statFile(io, leaf2, .{});

    // Cache hit: untouched mtime proves no regeneration happened.
    try std.testing.expectEqual(stat1.mtime, stat2.mtime);

    // Second host gets its own distinct leaf signed by the same CA.
    const other = try ensureLeaf(io, a, dir, "beta.test");
    try std.testing.expect(!std.mem.eql(u8, leaf1, other));
}
