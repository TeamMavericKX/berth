# Research: Zig feasibility for berth

Verified against Zig 0.16.0 installed locally on 2026-08-21. Every claim below was checked against the installed standard library, not assumed.

## What std gives us today

- `std.http.Server` exists (`std/http/Server.zig`). HTTP/1.1 serving is covered.
- `std.crypto.tls` is client-only. There is no TLS server implementation in std. This is the single biggest constraint on the project and drives ADR-0003.
- `std.net` covers TCP listeners, Unix sockets (`connectUnixSocket`), and address resolution. Enough for the proxy dial path and the Docker socket.
- C interop is first-class: linking the SQLite amalgamation is a build.zig flag plus `@cInclude`, no package manager involved.

## Module-by-module feasibility

| berth module | Mechanism | Risk |
|---|---|---|
| proxy.zig | std.http.Server, hand-rolled host routing | Low. h1 semantics are simple; pipelining not needed |
| routes.zig | JSON via std.json + POSIX flock | Low. Simpler than portless's mkdir-lock dance |
| scan.zig | Thread pool of connect probes, IPv4 then IPv6 | Low. portmap does this in 90 lines of Rust |
| db.zig | sqlite3.c amalgamation linked at build time | Low. One file, public domain |
| containers.zig | HTTP/1.1 over /var/run/docker.sock, std.json parse | Medium. Need minimal Docker API client; list-containers response parsing only |
| dash.zig | Embedded HTML string + SSE via chunked responses | Low-medium. SSE is just headers plus an infinite body |
| mdn.zig | Content negotiation on Accept header | Low |
| inject.zig | Comptime data tables ported from cli-utils.ts | Low. Pure data plus string surgery |
| certs.zig | Spawn openssl binary like portless does (certs.ts:231) | Low for minting. Trust-store install is per-OS scripting |
| TLS serving | Link OpenSSL or BoringSSL via C interop | High. Deferred to M3, see ADR-0003 |

## Cross-compilation

`zig build -Dtarget=aarch64-macos-none -Doptimize=ReleaseSafe` style targets cover macOS arm64/x86, Linux x86/arm64, Windows x64. Static linking where libc allows. This kills the Node runtime dependency that is portless's biggest deployment tax.

## Honest costs

1. No h2 server in std. Browsers speak h1 fine over cleartext and via OpenSSL-linked TLS later; HMR works over h1 WebSocket upgrades. We accept h1-first (ADR-0001).
2. Ecosystem is thin. Anything beyond std means vendoring C or writing it ourselves. We chose modules so that nothing beyond sqlite3.c and OpenSSL needs vendoring.
3. Language churn between Zig releases. We pin 0.16.x in CI and build docs.
