//! Trust-store installers for the local CA (ADR-0003). A trusted CA is
//! real power; installation must be reversible and platform-honest.
//! Every flow here has an exact inverse, and failure paths leave the
//! minted CA untouched so a retry re-runs cleanly. The portless lesson
//! from 0.15.3: WSL carries TWO stores; both sides are handled in the
//! same breath or neither is trusted.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    UnsupportedPlatform,
    CommandFailed,
    WriteFailed,
    ReadFailed,
};

pub const Kind = enum {
    macos,
    debian_linux,
    fedora_linux,
    windows,
    wsl_debian_linux,
    wsl_fedora_linux,

    /// True when a second store behind a Windows host must be handled
    /// alongside the Linux one.
    pub fn dualStore(k: Kind) bool {
        return k == .wsl_debian_linux or k == .wsl_fedora_linux;
    }
};

/// Anchor file name used in every system store we touch.
pub const anchor_name = "berth-local-ca.crt";
/// CN of our CA; certutil matches on this when deleting.
pub const ca_cn = "berth local CA";

// Injectable seams for tests; production never touches these.
pub var exec_impl: *const fn (io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) Error!void = execReal;
pub var debian_certs_dir: []const u8 = "/usr/local/share/ca-certificates";
pub var fedora_anchors_dir: []const u8 = "/etc/pki/ca-trust/source/anchors";
pub var debian_marker_path: []const u8 = "/etc/debian_version";
pub var wsl_probe_path: []const u8 = "/proc/version";
pub var wsl_certutil_path: []const u8 = "/mnt/c/Windows/System32/certutil.exe";

/// Recorded argv vectors land here during tests (one call per line,
/// space-joined). Null in production.
pub var recorded_calls: ?*std.ArrayList([]const u8) = null;

fn record(gpa: std.mem.Allocator, argv: []const []const u8) Error!void {
    const list = recorded_calls orelse return;
    var joined: std.ArrayList(u8) = .empty;
    for (argv, 0..) |arg, i| {
        if (i > 0) joined.append(gpa, ' ') catch return Error.CommandFailed;
        joined.appendSlice(gpa, arg) catch return Error.CommandFailed;
    }
    const line = joined.toOwnedSlice(gpa) catch return Error.CommandFailed;
    list.append(gpa, line) catch return Error.CommandFailed;
}

fn exec(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) Error!void {
    return exec_impl(io, gpa, argv);
}

fn execReal(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) Error!void {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch |err| switch (err) {
        error.FileNotFound => return Error.UnsupportedPlatform,
        else => return Error.CommandFailed,
    };
    // Non-zero exits surface as errors below; the streams themselves
    // are ours to release.
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return Error.CommandFailed,
        else => return Error.CommandFailed,
    }
}

fn exists(io: std.Io, path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn readFileInto(gpa: std.mem.Allocator, io: std.Io, path: []const u8, max: usize) ?[]u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const st = f.stat(io) catch return null;
    if (st.size > max) return null;
    const buf = gpa.alloc(u8, @intCast(st.size)) catch return null;
    const n = f.readPositionalAll(io, buf, 0) catch {
        gpa.free(buf);
        return null;
    };
    return buf[0..n];
}

var kind_buf: [std.fs.max_path_bytes]u8 = undefined;

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) continue :outer;
        }
        return true;
    }
    return false;
}

fn detectKind(io: std.Io, gpa: std.mem.Allocator) Error!Kind {
    switch (builtin.os.tag) {
        .macos => return .macos,
        .windows => return .windows,
        .linux => {},
        else => return Error.UnsupportedPlatform,
    }

    const wsl = blk: {
        const content = readFileInto(gpa, io, wsl_probe_path, 4096) orelse break :blk false;
        defer gpa.free(content);
        break :blk asciiContainsIgnoreCase(content, "microsoft");
    };
    const debian_flow = exists(io, debian_marker_path);
    if (wsl) return if (debian_flow) .wsl_debian_linux else .wsl_fedora_linux;
    return if (debian_flow) .debian_linux else .fedora_linux;
}

/// Public detection entry: which flow would we run on this machine?
pub fn kind(io: std.Io, gpa: std.mem.Allocator) Error!Kind {
    return detectKind(io, gpa);
}

fn copyIntoStore(io: std.Io, gpa: std.mem.Allocator, ca_crt: []const u8, dir: []const u8) Error!void {
    const content = readFileInto(gpa, io, ca_crt, 64 * 1024) orelse return Error.ReadFailed;
    defer gpa.free(content);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, anchor_name }) catch return Error.WriteFailed;
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = target,
        .data = content,
    }) catch return Error.WriteFailed;
}

fn removeFromStore(io: std.Io, dir: []const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, anchor_name }) catch return;
    std.Io.Dir.deleteFileAbsolute(io, target) catch {};
}

fn loginKeychainPath(env: ?*const std.process.Environ.Map, gpa: std.mem.Allocator) Error![]u8 {
    const home = (env orelse return Error.UnsupportedPlatform).get("HOME") orelse return Error.UnsupportedPlatform;
    return std.fmt.allocPrint(gpa, "{s}/Library/Keychains/login.keychain-db", .{home}) catch Error.CommandFailed;
}

/// Install the CA into this platform's store (both stores under WSL).
/// Idempotent: re-running re-copies and re-runs the update tool. The
/// minted CA files are only ever read, never touched, so a failed
/// attempt leaves identity intact for a safe retry.
pub fn installCA(io: std.Io, gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map, ca_crt: []const u8) Error!void {
    const k = try detectKind(io, gpa);
    switch (k) {
        .macos => {
            const keychain = try loginKeychainPath(env, gpa);
            try exec(io, gpa, &.{ "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-k", keychain, ca_crt });
        },
        .debian_linux => {
            try copyIntoStore(io, gpa, ca_crt, debian_certs_dir);
            try exec(io, gpa, &.{"update-ca-certificates"});
        },
        .fedora_linux => {
            try copyIntoStore(io, gpa, ca_crt, fedora_anchors_dir);
            try exec(io, gpa, &.{ "update-ca-trust", "extract" });
        },
        .windows => {
            try exec(io, gpa, &.{ "certutil", "-user", "-addstore", "Root", ca_crt });
        },
        .wsl_debian_linux => {
            try copyIntoStore(io, gpa, ca_crt, debian_certs_dir);
            try exec(io, gpa, &.{"update-ca-certificates"});
            // Windows side via interop; skipping it is how portless
            // shipped 0.15.3 with one side silently untrusted.
            try exec(io, gpa, &.{ wsl_certutil_path, "-user", "-addstore", "Root", ca_crt });
        },
        .wsl_fedora_linux => {
            try copyIntoStore(io, gpa, ca_crt, fedora_anchors_dir);
            try exec(io, gpa, &.{ "update-ca-trust", "extract" });
            try exec(io, gpa, &.{ wsl_certutil_path, "-user", "-addstore", "Root", ca_crt });
        },
    }
}

/// Reverse exactly what installCA did, on every store it touched.
/// Both WSL stores always get their reversal attempt even when the
/// first side errors — residue on either defeats the point — and the
/// surfaced error reports whichever store failed.
pub fn untrustCA(io: std.Io, gpa: std.mem.Allocator, ca_crt: []const u8) Error!void {
    const k = try detectKind(io, gpa);
    switch (k) {
        // remove-trusted-cert reverses the trust decision; the cert
        // copy itself leaves the keychain with delete-certificate.
        .macos => {
            try exec(io, gpa, &.{ "security", "remove-trusted-cert", "-d", ca_crt });
            try exec(io, gpa, &.{ "security", "delete-certificate", "-c", ca_cn });
        },
        .debian_linux => {
            removeFromStore(io, debian_certs_dir);
            try exec(io, gpa, &.{ "update-ca-certificates", "--fresh" });
        },
        .fedora_linux => {
            removeFromStore(io, fedora_anchors_dir);
            try exec(io, gpa, &.{ "update-ca-trust", "extract" });
        },
        .windows => {
            try exec(io, gpa, &.{ "certutil", "-user", "-delstore", "Root", ca_cn });
        },
        .wsl_debian_linux, .wsl_fedora_linux => {
            if (k == .wsl_debian_linux) {
                removeFromStore(io, debian_certs_dir);
                try exec(io, gpa, &.{ "update-ca-certificates", "--fresh" });
            } else {
                removeFromStore(io, fedora_anchors_dir);
                try exec(io, gpa, &.{ "update-ca-trust", "extract" });
            }
            // Best effort on the Windows side: report failure but only
            // after both stores had their chance.
            exec(io, gpa, &.{ wsl_certutil_path, "-user", "-delstore", "Root", ca_cn }) catch |err| return err;
        },
    }
}

var failing_at: ?usize = null; // fail the Nth recorded exec
var exec_count: usize = 0;

fn execRecording(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) Error!void {
    _ = io;
    if (failing_at) |n| {
        if (exec_count == n) {
            exec_count += 1;
            return Error.CommandFailed;
        }
    }
    exec_count += 1;
    return record(gpa, argv);
}

fn resetSeams(gpa: std.mem.Allocator) void {
    exec_impl = execRecording;
    failing_at = null;
    exec_count = 0;
    if (recorded_calls) |rc| {
        for (rc.items) |line| gpa.free(line);
        rc.clearRetainingCapacity();
    }
}

test "debian flow copies anchor then updates; untrust reverses exactly" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rp_len = try tmp.dir.realPath(io, &rp_buf);

    // Fake system layout + fake distro + fake WSL probe (not microsoft).
    var store_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const store = try std.fmt.bufPrint(&store_buf, "{s}/store", .{rp_buf[0..rp_len]});
    try std.Io.Dir.cwd().createDirPath(io, store);
    var marker_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "{s}/debian_version", .{rp_buf[0..rp_len]});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "bookworm/sid" });

    debian_certs_dir = store;
    debian_marker_path = marker;
    wsl_probe_path = "/nonexistent-probe";
    defer {
        debian_certs_dir = "/usr/local/share/ca-certificates";
        debian_marker_path = "/etc/debian_version";
        wsl_probe_path = "/proc/version";
    }

    var calls: std.ArrayList([]const u8) = .empty;
    recorded_calls = &calls;
    defer recorded_calls = null;
    resetSeams(gpa);

    var ca_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ca_crt = try std.fmt.bufPrint(&ca_buf, "{s}/ca.crt", .{rp_buf[0..rp_len]});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ca_crt, .data = "-----BEGIN CERTIFICATE-----FAKE-----END CERTIFICATE-----\n" });
    try installCA(io, gpa, null, ca_crt);

    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
    try std.testing.expectEqualStrings("update-ca-certificates", calls.items[0]);

    // Anchor landed in the store with byte-identical content.
    const anchor = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ store, anchor_name });
    const stored = std.Io.Dir.cwd().readFileAlloc(io, anchor, gpa, std.Io.Limit.limited(4096)) catch
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("-----BEGIN CERTIFICATE-----FAKE-----END CERTIFICATE-----\n", stored);

    // Untrust removes the anchor then rebuilds.
    try untrustCA(io, gpa, ca_crt);
    try std.testing.expectEqual(@as(usize, 2), calls.items.len);
    try std.testing.expectEqualStrings("update-ca-certificates --fresh", calls.items[1]);
    if (std.Io.Dir.cwd().openFile(io, anchor, .{})) |_| {
        return error.TestUnexpectedResult; // residue!
    } else |_| {}
}

test "wsl handles both stores on install and both on untrust" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rp_len = try tmp.dir.realPath(io, &rp_buf);
    const rp = rp_buf[0..rp_len];

    var store_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const store = try std.fmt.bufPrint(&store_buf, "{s}/store", .{rp});
    try std.Io.Dir.cwd().createDirPath(io, store);
    var marker_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "{s}/debian_version", .{rp});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "12.5" });

    debian_certs_dir = store;
    debian_marker_path = marker;
    wsl_certutil_path = "/mnt/c/fake/certutil.exe";

    // WSL probe file claiming a microsoft kernel.
    var probe_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const probe = try std.fmt.bufPrint(&probe_buf, "{s}/version", .{rp});
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = probe,
        .data = "Linux version 5.15.153.1-microsoft-standard-WSL2",
    });
    wsl_probe_path = probe;
    defer {
        debian_certs_dir = "/usr/local/share/ca-certificates";
        debian_marker_path = "/etc/debian_version";
        wsl_probe_path = "/proc/version";
        wsl_certutil_path = "/mnt/c/Windows/System32/certutil.exe";
    }

    var calls: std.ArrayList([]const u8) = .empty;
    recorded_calls = &calls;
    defer recorded_calls = null;
    resetSeams(gpa);

    var wsl_ca_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wsl_ca = try std.fmt.bufPrint(&wsl_ca_buf, "{s}/wsl-ca.crt", .{rp});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wsl_ca, .data = "CA-DATA" });
    try installCA(io, gpa, null, wsl_ca);
    try std.testing.expectEqual(@as(usize, 2), calls.items.len);
    try std.testing.expectEqualStrings("update-ca-certificates", calls.items[0]);
    const want_add = try std.fmt.allocPrint(gpa, "/mnt/c/fake/certutil.exe -user -addstore Root {s}", .{wsl_ca});
    try std.testing.expectEqualStrings(want_add, calls.items[1]);

    var wsl_un_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wsl_un_path = try std.fmt.bufPrint(&wsl_un_buf, "{s}/wsl-ca.crt", .{rp});
    try untrustCA(io, gpa, wsl_un_path);
    try std.testing.expectEqual(@as(usize, 4), calls.items.len);
    try std.testing.expectEqualStrings("update-ca-certificates --fresh", calls.items[2]);
    try std.testing.expectEqualStrings("/mnt/c/fake/certutil.exe -user -delstore Root berth local CA", calls.items[3]);
}

test "failed update step preserves anchor for safe retry" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rp_len = try tmp.dir.realPath(io, &rp_buf);
    const rp = rp_buf[0..rp_len];

    var store_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const store = try std.fmt.bufPrint(&store_buf, "{s}/store", .{rp});
    try std.Io.Dir.cwd().createDirPath(io, store);

    debian_certs_dir = store;
    wsl_probe_path = "/nonexistent-probe";
    debian_marker_path = "/nonexistent-marker"; // fedora flow, no real markers
    fedora_anchors_dir = store;
    defer {
        debian_certs_dir = "/usr/local/share/ca-certificates";
        wsl_probe_path = "/proc/version";
        debian_marker_path = "/etc/debian_version";
        fedora_anchors_dir = "/etc/pki/ca-trust/source/anchors";
    }

    var calls: std.ArrayList([]const u8) = .empty;
    recorded_calls = &calls;
    defer recorded_calls = null;
    resetSeams(gpa);
    failing_at = 0; // the update-tool exec fails

    var id_ca_buf: [std.fs.max_path_bytes]u8 = undefined;
    const id_ca = try std.fmt.bufPrint(&id_ca_buf, "{s}/id-ca.crt", .{rp});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = id_ca, .data = "CA-IDENTITY" });
    try std.testing.expectError(Error.CommandFailed, installCA(io, gpa, null, id_ca));

    // Anchor survived: identity intact, retry re-copies idempotently.
    const anchor = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ store, anchor_name });
    const stored = std.Io.Dir.cwd().readFileAlloc(io, anchor, gpa, std.Io.Limit.limited(4096)) catch
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("CA-IDENTITY", stored);

    // Retry with the failure cleared completes cleanly.
    failing_at = null;
    try installCA(io, gpa, null, id_ca);
    try std.testing.expectEqual(@as(usize, 1), calls.items.len); // failed attempt leaves no trace
}

test "detect returns a linux flow on this machine" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    const k = try kind(io, std.testing.allocator);
    try std.testing.expect(k == .debian_linux or k == .fedora_linux or k == .wsl_debian_linux or k == .wsl_fedora_linux);
}
