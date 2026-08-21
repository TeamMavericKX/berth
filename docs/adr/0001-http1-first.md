# ADR-0001: HTTP/1.1 first, HTTP/2 deferred

Status: accepted · Date: 2026-08-21

## Context

Zig 0.16 std has `std.http.Server` for HTTP/1.1 but no HTTP/2 server implementation. portless's h2 support (multiplexing, RFC 8441 WebSocket bridging, stream-reset tuning) represents years of edge-case hardening across ~700 lines of dense proxy code.

## Decision

berth M1-M2 serve HTTP/1.1 only. TLS arrives in M3 via linked OpenSSL (ADR-0003), still speaking h1 over TLS with ALPN offering only http/1.1. WebSockets work through standard h1 Upgrade piping.

## Consequences

- Browsers negotiate h1; dev servers work, HMR works, OAuth flows work.
- We lose h2 multiplexing head-of-line improvements, which matter little on loopback RTTs measured in microseconds.
- RFC 8441 bridging is explicitly out of scope until there is user pain. Revisit no earlier than post-M4.
