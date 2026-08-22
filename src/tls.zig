//! TLS termination with SNI-selected certificates, backed by the system
//! OpenSSL through C interop (ADR-0003). Zig std has no TLS server, and
//! this is the only viable path today.
//!
//! The build flag -Dopenssl controls linkage: without it every entry
//! point fails closed with error.Unavailable so cross-compile targets
//! keep building clean. With it, a Backend wraps an SSL_CTX configured
//! like portless's createSNICallback: per-host leaf certs swapped in by
//! SNI, a default cert for unknown names, ALPN offering http/1.1 only.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const certs = @import("certs.zig");
const Io = std.Io;

pub const enabled = build_options.openssl and switch (builtin.os.tag) {
    .linux, .macos => true,
    else => false,
};

pub const Error = error{
    Unavailable,
    ContextInitFailed,
    DefaultCertLoadFailed,
    HandshakeFailed,
    IoFailed,
};

const c = if (enabled)
    @cImport({
        @cInclude("openssl/ssl.h");
        @cInclude("openssl/err.h");
        @cInclude("openssl/x509.h");
    })
else
    struct {};

/// One hostname bound to its minted leaf material.
pub const HostCert = struct {
    host: []const u8,
    paths: certs.Paths,
};

var g_gpa: std.mem.Allocator = undefined;
// C callbacks carry no context pointer; one process serves one registry.
var g_hosts: ?*std.StringHashMapUnmanaged(certs.Paths) = null;

pub const Backend = struct {
    /// Opaque so the stub build (no openssl) compiles this layout.
    ctx: ?*anyopaque = null,
    gpa: std.mem.Allocator,

    pub fn deinit(b: *Backend) void {
        if (comptime !enabled) return;
        const ctx: *c.struct_ssl_ctx_st = @ptrCast(@alignCast(b.ctx));
        c.SSL_CTX_free(ctx);
        b.ctx = null;
        if (g_hosts) |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                g_gpa.free(e.key_ptr.*);
            }
            m.deinit(g_gpa);
            g_gpa.destroy(m);
            g_hosts = null;
        }
    }
};

fn zCopy(dst: []u8, src: []const u8) ?[:0]const u8 {
    if (src.len >= dst.len) return null;
    @memcpy(dst[0..src.len], src);
    dst[src.len] = 0;
    return dst[0..src.len :0];
}

fn lowerBuf(dst: []u8, src: []const u8) ?[]const u8 {
    if (src.len > dst.len) return null;
    for (src, 0..) |ch, i| dst[i] = std.ascii.toLower(ch);
    return dst[0..src.len];
}

fn sniCallback(ssl: ?*c.struct_ssl_st, alert: ?*c_int, arg: ?*anyopaque) callconv(.c) c_int {
    _ = alert;
    _ = arg;
    // Never fail the handshake: on anything unexpected the CTX-level
    // default cert answers. Unknown SNI must not break connections.
    const raw = c.SSL_get_servername(ssl, c.TLSEXT_NAMETYPE_host_name) orelse return c.SSL_TLSEXT_ERR_OK;
    const name_raw = std.mem.span(raw);
    var buf: [253]u8 = undefined;
    const name = lowerBuf(&buf, name_raw) orelse return c.SSL_TLSEXT_ERR_OK;
    const map = g_hosts orelse return c.SSL_TLSEXT_ERR_OK;
    const paths = map.get(name) orelse return c.SSL_TLSEXT_ERR_OK;

    // OpenSSL wants NUL-terminated paths; zig slices carry no sentinel.
    var crt_buf: [std.fs.max_path_bytes]u8 = undefined;
    var key_buf: [std.fs.max_path_bytes]u8 = undefined;
    const crt_z = zCopy(&crt_buf, paths.leaf_crt) orelse return c.SSL_TLSEXT_ERR_OK;
    const key_z = zCopy(&key_buf, paths.leaf_key) orelse return c.SSL_TLSEXT_ERR_OK;

    // Single-cert load at connection level; our leaves need no chain in
    // flight because clients trust the CA directly.
    if (c.SSL_use_certificate_file(ssl, crt_z.ptr, c.X509_FILETYPE_PEM) != 1) return c.SSL_TLSEXT_ERR_OK;
    if (c.SSL_use_PrivateKey_file(ssl, key_z.ptr, c.SSL_FILETYPE_PEM) != 1) return c.SSL_TLSEXT_ERR_OK;
    _ = c.SSL_check_private_key(ssl);
    return c.SSL_TLSEXT_ERR_OK;
}

fn alpnCallback(
    ssl: ?*c.struct_ssl_st,
    out: [*c][*c]const u8,
    outlen: [*c]u8,
    in: [*c]const u8,
    inlen: c_uint,
    arg: ?*anyopaque,
) callconv(.c) c_int {
    _ = ssl;
    _ = arg;
    const offered = in[0..inlen];
    const want = "http/1.1";
    var i: usize = 0;
    while (i < offered.len) {
        const l: usize = offered[i];
        if (l == 0 or i + 1 + l > offered.len) break;
        if (l == want.len and std.mem.eql(u8, offered[i + 1 .. i + 1 + l], want)) {
            out.* = want.ptr;
            outlen.* = @intCast(want.len);
            // This OpenSSL wants SSL_TLSEXT_ERR_OK from the select
            // callback; OPENSSL_NPN_NEGOTIATED fatals the handshake
            // despite a match (verified against 3.x empirically).
            return c.SSL_TLSEXT_ERR_OK;
        }
        i += 1 + l;
    }
    // No overlap: proceed without ALPN rather than alerting; h1-only is
    // an offer, not a requirement, for tools that skip extension.
    return c.SSL_TLSEXT_ERR_NOACK;
}

/// Build a server context. `default` supplies the fallback cert used for
/// unknown SNI; it is loaded at CTX level so misses answer seamlessly.
pub fn start(gpa: std.mem.Allocator, hosts: []const HostCert, default: HostCert) Error!Backend {
    if (!enabled) return Error.Unavailable;
    g_gpa = gpa;

    _ = c.OPENSSL_init_ssl(c.OPENSSL_INIT_LOAD_SSL_STRINGS | c.OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);

    const map = gpa.create(std.StringHashMapUnmanaged(certs.Paths)) catch return Error.ContextInitFailed;
    map.* = .empty;
    g_hosts = map;
    for (hosts) |hc| {
        const key = gpa.dupe(u8, hc.host) catch return Error.ContextInitFailed;
        map.put(g_gpa, key, hc.paths) catch return Error.ContextInitFailed;
    }

    const ctx = c.SSL_CTX_new(c.TLS_server_method()) orelse return Error.ContextInitFailed;
    errdefer c.SSL_CTX_free(ctx);

    if (c.SSL_CTX_ctrl(ctx, c.SSL_CTRL_SET_MIN_PROTO_VERSION, c.TLS1_2_VERSION, null) != 1) return Error.ContextInitFailed;

    var dflt_crt_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dflt_key_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dflt_crt_z = zCopy(&dflt_crt_buf, default.paths.leaf_crt) orelse return Error.DefaultCertLoadFailed;
    const dflt_key_z = zCopy(&dflt_key_buf, default.paths.leaf_key) orelse return Error.DefaultCertLoadFailed;
    if (c.SSL_CTX_use_certificate_chain_file(ctx, dflt_crt_z.ptr) != 1) return Error.DefaultCertLoadFailed;
    if (c.SSL_CTX_use_PrivateKey_file(ctx, dflt_key_z.ptr, c.SSL_FILETYPE_PEM) != 1) return Error.DefaultCertLoadFailed;
    if (c.SSL_CTX_check_private_key(ctx) != 1) return Error.DefaultCertLoadFailed;

    if (c.SSL_CTX_callback_ctrl(ctx, c.SSL_CTRL_SET_TLSEXT_SERVERNAME_CB, @ptrCast(&sniCallback)) != 1) return Error.ContextInitFailed;
    c.SSL_CTX_set_alpn_select_cb(ctx, alpnCallback, null);

    return .{ .ctx = ctx, .gpa = gpa };
}

/// One terminated TLS connection over an accepted TCP stream.
pub const Session = struct {
    /// Opaque so the stub build (no openssl) compiles this layout.
    ssl: ?*anyopaque,

    /// SHA-256 of the certificate actually served, hex-encoded. Proof of
    /// which leaf the SNI callback picked.
    pub fn servedFingerprintHex(s: Session, out: *[64]u8) Error!void {
        if (comptime !enabled) return Error.Unavailable;
        const ssl: *c.struct_ssl_st = @ptrCast(@alignCast(s.ssl.?));
        const x = c.SSL_get_certificate(ssl) orelse return Error.IoFailed;
        var md: [c.EVP_MAX_MD_SIZE]u8 = undefined;
        var md_len: c_uint = 0;
        if (c.X509_digest(@ptrCast(x), c.EVP_sha256(), &md, &md_len) != 1) return Error.IoFailed;
        const hexd = "0123456789abcdef";
        for (md[0..md_len], 0..) |b, i| {
            out[i * 2] = hexd[b >> 4];
            out[i * 2 + 1] = hexd[b & 15];
        }
    }

    pub fn read(s: Session, buf: []u8) !usize {
        if (comptime !enabled) return 0;
        const ssl: *c.struct_ssl_st = @ptrCast(@alignCast(s.ssl.?));
        const n = c.SSL_read(ssl, buf.ptr, @intCast(buf.len));
        if (n > 0) return @intCast(n);
        switch (c.SSL_get_error(ssl, n)) {
            c.SSL_ERROR_ZERO_RETURN => return 0,
            c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => return error.WouldBlock,
            else => return error.IoFailed,
        }
    }

    pub fn writeAll(s: Session, bytes: []const u8) !void {
        if (comptime !enabled) return;
        const ssl: *c.struct_ssl_st = @ptrCast(@alignCast(s.ssl.?));
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = c.SSL_write(ssl, bytes[sent..].ptr, @intCast(bytes.len - sent));
            if (n <= 0) {
                const e = c.SSL_get_error(ssl, n);
                switch (e) {
                    c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => continue,
                    else => return error.IoFailed,
                }
            }
            sent += @intCast(n);
        }
    }

    pub fn close(s: *Session) void {
        if (comptime !enabled) return;
        if (s.ssl) |raw| {
            const ssl: *c.struct_ssl_st = @ptrCast(@alignCast(raw));
            _ = c.SSL_shutdown(ssl);
            c.SSL_free(ssl);
        }
        s.ssl = null;
    }
};

/// Perform the TLS handshake on an accepted TCP stream.
pub fn accept(b: *Backend, stream: std.Io.net.Stream) Error!Session {
    if (!enabled) return Error.Unavailable;
    const ctx: *c.struct_ssl_ctx_st = @ptrCast(@alignCast(b.ctx));
    const ssl = c.SSL_new(ctx) orelse return Error.HandshakeFailed;
    errdefer c.SSL_free(ssl);
    if (c.SSL_set_fd(ssl, stream.socket.handle) != 1) return Error.HandshakeFailed;
    while (true) {
        const rc = c.SSL_accept(ssl);
        if (rc == 1) break;
        switch (c.SSL_get_error(ssl, rc)) {
            c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => continue,
            else => return Error.HandshakeFailed,
        }
    }
    return .{ .ssl = ssl };
}

test "stub fails closed when built without openssl" {
    if (enabled) return error.SkipZigTest;
    try std.testing.expectError(Error.Unavailable, start(std.testing.allocator, &.{}, .{ .host = "x", .paths = undefined }));
}

test "sni selects per-host leaves; unknown name falls back" {
    if (!enabled) return error.SkipZigTest;
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rp_len = try tmp.dir.realPath(std.testing.io, &rp_buf);
    const dir = rp_buf[0..rp_len];

    const ca_crt = try std.fmt.allocPrint(gpa, "{s}/ca.crt", .{dir});
    defer gpa.free(ca_crt);

    const alpha = HostCert{
        .host = "alpha.test",
        .paths = .{
            .ca_key = "",
            .ca_crt = "",
            .ext_file = "",
            .leaf_key = try std.fmt.allocPrint(gpa, "{s}/alpha.test.key", .{dir}),
            .leaf_crt = try std.fmt.allocPrint(gpa, "{s}/alpha.test.crt", .{dir}),
        },
    };
    const beta = HostCert{
        .host = "beta.test",
        .paths = .{
            .ca_key = "",
            .ca_crt = "",
            .ext_file = "",
            .leaf_key = try std.fmt.allocPrint(gpa, "{s}/beta.test.key", .{dir}),
            .leaf_crt = try std.fmt.allocPrint(gpa, "{s}/beta.test.crt", .{dir}),
        },
    };
    const dflt = HostCert{
        .host = "default.test",
        .paths = .{
            .ca_key = "",
            .ca_crt = "",
            .ext_file = "",
            .leaf_key = try std.fmt.allocPrint(gpa, "{s}/default.test.key", .{dir}),
            .leaf_crt = try std.fmt.allocPrint(gpa, "{s}/default.test.crt", .{dir}),
        },
    };
    // Mint all three through the real openssl CLI from #22.
    _ = try certs.ensureLeaf(io, gpa, dir, "alpha.test");
    _ = try certs.ensureLeaf(io, gpa, dir, "beta.test");
    _ = try certs.ensureLeaf(io, gpa, dir, "default.test");

    var backend = try start(gpa, &.{ alpha, beta }, dflt);
    defer backend.deinit();

    // Ground-truth fingerprints straight from the PEM files.
    const fp_alpha = try fileFingerprintHex(io, alpha.paths.leaf_crt, gpa);
    const fp_beta = try fileFingerprintHex(io, beta.paths.leaf_crt, gpa);
    const fp_default = try fileFingerprintHex(io, dflt.paths.leaf_crt, gpa);
    try std.testing.expect(!std.mem.eql(u8, fp_alpha, fp_beta));

    // Three sequential rounds: known host, second known host, unknown
    // SNI. Each round the external curl client drives handshake timing,
    // keeping this thread free of cross-thread coordination.
    const cases = [_]struct { host: []const u8, expect_fp: []const u8 }{
        .{ .host = "alpha.test", .expect_fp = fp_alpha },
        .{ .host = "beta.test", .expect_fp = fp_beta },
        .{ .host = "nobody.test", .expect_fp = fp_default },
    };

    for (cases) |case| {
        const address = std.Io.net.IpAddress{ .ip4 = try std.Io.net.Ip4Address.parse("127.0.0.1", 0) };
        var listener = try address.listen(io, .{ .kernel_backlog = 2 });
        defer listener.deinit(io);
        const port = listener.socket.address.getPort();

        const body_path = try std.fmt.allocPrint(gpa, "{s}/body-{s}", .{ dir, case.host });

        const resolve_arg = try std.fmt.allocPrint(gpa, "{s}:{d}:127.0.0.1", .{ case.host, port });
        const url_arg = try std.fmt.allocPrint(gpa, "https://{s}:{d}/ping", .{ case.host, port });

        var child = std.process.spawn(io, .{
            // -k: the fallback case deliberately presents a cert whose
            // SAN does not match the URL host; that mismatch aborting is
            // correct curl behavior, not a server bug.
            .argv = &.{
                "timeout",
                "8",
                "curl",
                if (std.mem.eql(u8, case.host, "nobody.test")) "-k" else "-s",
                "-s",
                "-m",
                "5",
                "--cacert",
                ca_crt,
                "--resolve",
                resolve_arg,
                url_arg,
                "-o",
                body_path,
            },
            .stdout = .close,
            .stderr = .close,
        }) catch return error.SkipZigTest;

        const stream = listener.accept(io) catch return error.SkipZigTest;
        var session = accept(&backend, stream) catch |err| {
            stream.close(io);
            _ = child.wait(io) catch {};
            return err;
        };

        // Drain request head, then answer once.
        var req_buf: [4096]u8 = undefined;
        var got: usize = 0;
        while (got < req_buf.len) {
            const n = session.read(req_buf[got..]) catch break;
            if (n == 0) break;
            got += n;
            if (std.mem.indexOf(u8, req_buf[0..got], "\r\n\r\n") != null) break;
        }
        try session.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhowdy");

        var fp_hex: [64]u8 = undefined;
        try session.servedFingerprintHex(&fp_hex);
        session.close();
        stream.close(io);

        _ = child.wait(io) catch {};

        const body = std.Io.Dir.cwd().readFileAlloc(io, body_path, gpa, std.Io.Limit.limited(1024)) catch
            return error.TestUnexpectedResult;
        defer gpa.free(body);
        try std.testing.expectEqualStrings("howdy", body);
        try std.testing.expectEqualStrings(case.expect_fp, &fp_hex);
    }
}

fn fileFingerprintHex(io: std.Io, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const pem = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(64 * 1024));
    const start_i = std.mem.indexOf(u8, pem, "-----BEGIN CERTIFICATE-----").?;
    const end_i = std.mem.indexOf(u8, pem, "-----END CERTIFICATE-----").?;
    var b64_buf: [16 * 1024]u8 = undefined;
    var b64_len: usize = 0;
    var it = std.mem.splitScalar(u8, pem[start_i..end_i], '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0 or t[0] == '-') continue;
        @memcpy(b64_buf[b64_len .. b64_len + t.len], t);
        b64_len += t.len;
    }
    var der: [8192]u8 = undefined;
    const decoder = std.base64.standard.Decoder;
    const der_len = try decoder.calcSizeForSlice(b64_buf[0..b64_len]);
    try decoder.decode(der[0..der_len], b64_buf[0..b64_len]);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(der[0..der_len], &digest, .{});
    return std.fmt.allocPrint(gpa, "{x}", .{&digest});
}

/// A TLS-terminated connection presenting the same reader/writer shape
/// as std.Io.net.Stream, so the h1 handler runs unchanged over it.
pub const Conn = struct {
    session: Session,

    pub fn close(self: *Conn) void {
        self.session.close();
    }

    pub fn reader(self: *Conn, io: Io, buffer: []u8) TlsReader {
        return .init(self, io, buffer);
    }

    pub fn writer(self: *Conn, io: Io, buffer: []u8) TlsWriter {
        return .init(self, io, buffer);
    }
};

pub const TlsReader = struct {
    io: Io,
    interface: Io.Reader,
    conn: *Conn,
    err: ?anyerror = null,

    pub fn init(conn: *Conn, io: Io, buffer: []u8) TlsReader {
        return .{
            .io = io,
            .conn = conn,
            .interface = .{
                .vtable = &.{
                    .stream = streamImpl,
                    .readVec = readVecImpl,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVecImpl(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVecImpl(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *TlsReader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs_buffer: [1][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        if (comptime !enabled) return error.ReadFailed;
        // SSL_read fills one contiguous span: dest[0] only. Bytes past
        // data_size landed in the interface's own buffer, which the core
        // cannot see unless we advance .end ourselves (fillMore calls
        // this with empty data precisely for that path).
        const n = r.conn.session.read(dest[0]) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            io_r.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

pub const TlsWriter = struct {
    io: Io,
    interface: Io.Writer,
    conn: *Conn,
    err: ?anyerror = null,

    pub fn init(conn: *Conn, io: Io, buffer: []u8) TlsWriter {
        return .{
            .io = io,
            .conn = conn,
            .interface = .{
                .vtable = &.{
                    .drain = drainImpl,
                    .sendFile = sendFileImpl,
                },
                .buffer = buffer,
            },
        };
    }

    fn drainImpl(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *TlsWriter = @alignCast(@fieldParentPtr("interface", io_w));
        if (comptime !enabled) return error.WriteFailed;
        // Buffer first, then each slice; last element written `splat`
        // times total per the drain contract.
        w.conn.session.writeAll(io_w.buffered()) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        io_w.end = 0;
        var consumed: usize = 0;
        for (data, 0..) |d, i| {
            const repeats: usize = if (i + 1 == data.len) splat else 1;
            var k: usize = 0;
            while (k < repeats) : (k += 1) {
                w.conn.session.writeAll(d) catch |err| {
                    w.err = err;
                    return error.WriteFailed;
                };
            }
            consumed += d.len;
        }
        return consumed;
    }

    fn sendFileImpl(io_w: *Io.Writer, file_reader: *Io.File.Reader, limit: Io.Limit) Io.Writer.FileError!usize {
        _ = io_w;
        _ = file_reader;
        _ = limit;
        return error.Unimplemented;
    }
};
