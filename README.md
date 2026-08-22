# berth

**One daemon. Two superpowers.**

berth gives local dev servers stable `https://name.localhost` URLs — and gives humans *and* agents an honest dashboard over everything listening on loopback.

It is the useful halves of [portless](https://github.com/vercel-labs/portless) (named HTTPS URLs) and [portmap](https://github.com/vibber-ai/portmap) (port registry + agent-readable dashboard) in one small static Zig binary — **minus the taxes**: no Node 24 runtime, no sudo for port 443, no system-level root CA, no permissive CORS on kill endpoints.

| | |
|---|---|
| CI | ![ci](https://github.com/TeamMavericKX/berth/actions/workflows/ci.yml/badge.svg) |
| Release | ![release](https://github.com/TeamMavericKX/berth/actions/workflows/release.yml/badge.svg) |
| License | Apache-2.0 |

## Quickstart

```bash
# prebuilt static binaries (linux/macOS x86_64+aarch64, windows)
# → https://github.com/TeamMavericKX/berth/releases/latest

# or build from source (Zig 0.16.x)
git clone https://github.com/TeamMavericKX/berth && cd berth
zig build -Doptimize=ReleaseSafe
```

```bash
berth run -- npm run dev
# berth: myapi.localhost -> 127.0.0.1:4312 (pid 48221)

berth trust                 # local CA installed; https URLs work in browsers
berth serve                 # console on :8090 — also answers at http://berth.localhost:8090
berth service install       # survives reboots; user-level unit, still zero sudo
berth clean --yes           # leave with zero residue
```

That's the whole loop. Ctrl-C on a `run` cleans up its route, hosts entry, and process.

## What it does

| Feature | The one-line proof |
|---|---|
| Stable named URLs | `myapi.localhost` survives restarts; routes persist in SQLite |
| HTTPS via real certs | CA minted by your own `openssl` binary; SNI picks per-host leaves |
| One-port demux | TLS and plaintext share a listener via a first-byte peek |
| Framework port injection | `vite dev` gets `--port <n> --strictPort` appended; PORT-env ignorers covered |
| Worktree prefixes | linked worktree on `feature/auth` serves as `auth-myapp.localhost`; root never prefixed |
| Live scanner + claim | ports 1000–9999 scanned on demand; claim from dashboard or API |
| Docker/Podman discovery | published container ports surface as `origin=container` candidates |
| Kill ladder | TERM all listeners → 2s zombie-aware wait → KILL survivors → report which |
| Markdown for agents | `Accept: text/markdown` returns full status + API reference |
| Gated mutations | Origin allowlist plus optional `BERTH_TOKEN`; constant-time compare |
| Tunnels | `--tailscale` / `--funnel` attach the ts.net authority to the route |
| User services | LaunchAgent / systemd user unit; reboot-safe without sudo |

The dashboard itself is a dark glass console with live SSE updates, search, and tunnel badges — see `src/dash.html`.

## Docs

- **[Human guide](docs/guide.md)** — five minutes from clone to leaving-clean
- **[Agent contract](docs/agents.md)** — markdown endpoint, URL scheme, safe mutation patterns
- **[Landing page](site/index.html)** — the comparison table against both parents, with receipts
- **[Changelog](CHANGELOG.md)** — Keep-a-Changelog format

## Architecture

```
            ┌────────────────────────────────────────────┐
 browser ──▶│ :8080  peek(0x16)? ─ TLS(SNI leaf) ─┐      │
 curl    ──▶│   └── plain ──▶ host router ◀───────┘      │
 agents  ──▶│        │           │  ▲                     │
            │        │      routes.zig  sqlite (~/.berth) │
            │        ▼           │                        │
            │   backend 127.0.0.1:P                       │
            └──────┬─────────────────────────────────────-┘
                   │ on demand
     docker.sock ──┤ scanner 1000-9999
     openssl CLI ──┤ /etc/hosts marker block
     tailscale ────┘ systemd user unit / LaunchAgent
```

One listener, one thread per connection. Everything stateful lives in SQLite at `~/.berth/berth.db`; certificates in `~/.berth/certs/`. Cross-compile targets (`x86_64|aarch64 × linux|macos`, `x86_64-windows`) build ReleaseSafe on every commit; TLS requires `-Dopenssl` and fails closed without it.

## Design decisions

Recorded as ADRs with fallback plans: [h1-first](docs/adr/0001-http1-first.md), [SQLite amalgamation](docs/adr/0002-sqlite-amalgamation.md), [linked OpenSSL + spawned openssl CLI](docs/adr/0003-tls-via-openssl-link.md), [scan-on-demand only](docs/adr/0004-on-demand-scanning.md). Research dossiers on both parents — with file:line receipts into their source — live in [docs/research/](docs/research/).

## Known limits

- HTTP/1.1 only (std has no h2 server; ADR-0001). HMR works over WebSocket upgrades.
- TLS needs a system OpenSSL; cross-built binaries ship without it and fail closed.
- Routes registered while serving don't get TLS leaves until restart.
- Windows is CLI-only (no TLS, no service units).

## Contributing

Six-word lowercase commit subjects, enforced by CI. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache-2.0
