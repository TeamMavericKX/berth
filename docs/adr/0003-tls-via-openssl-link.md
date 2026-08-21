# ADR-0003: TLS via linked OpenSSL, CA minting via openssl CLI

Status: accepted · Date: 2026-08-21

## Context

Zig std has no TLS server (verified against std/crypto/tls.zig on 0.16.0). berth's headline feature is HTTPS named URLs, so TLS is mandatory eventually. portless solves cert *minting* by spawning the openssl binary (`certs.ts:231`) and trust installation with per-OS logic including WSL dual-store handling (CHANGELOG #357).

## Decision

Split the problem:

1. **Termination** (M3): link OpenSSL (or BoringSSL) through Zig C interop. SNI callback selects per-host certificates exactly like portless's `createSNICallback` (`certs.ts:791`). ALPN offers http/1.1 only per ADR-0001.
2. **Minting** (M3): spawn the openssl binary for CA and leaf generation, same as portless. Keeps us out of X.509 construction code entirely.
3. **Trust** (M3): per-OS installers for macOS keychain, Linux ca-certificates/update-ca-trust paths, Windows plus WSL dual store.

Until M3 ships, berth runs cleartext on high ports. The proxy never requires elevation before M3.

## Consequences

- Build gains a libssl/libcrypto link dependency on M3 targets. Mitigated by system packages documented per platform.
- Windows support before M3 is CLI-only without HTTPS.
- If OpenSSL linking proves hostile on any target, BoringSSL is the fallback; the SNI seam isolates the choice.
