# Architecture

berth is one daemon doing two jobs: proxying your dev servers behind stable names, and keeping a live registry of everything listening on the machine. This document maps every module, its inputs and outputs, and which parent tool each idea came from. Parent citations point at the research dossiers, which carry file:line receipts.

## The shape

```
                    ┌──────────────────────────────────────┐
  browser ────────▶ │  berth (one static binary)           │
  agent/curl ─────▶ │                                      │
                    │  ┌────────────┐   ┌───────────────┐  │
                    │  │ proxy.zig  │──▶│ routes (sqlite)│  │
                    │  └─────┬──────┘   └───────▲───────┘  │
                    │        │ dial              │ register │
                    │        ▼                   │          │
                    │  dev servers :4000-4999    │          │
                    │                            │          │
                    │  ┌────────────┐   ┌────────┴───────┐  │
                    │  │ scan.zig   │──▶│ db.zig         │  │
                    │  │containers  │   │ apps+tag_colors│  │
                    │  └────────────┘   └───────┬────────┘  │
                    │                           │ merge     │
                    │  ┌────────────┐   ┌───────▼────────┐  │
                    │  │ kill.zig   │   │ dash.zig       │  │
                    │  └────────────┘   │ mdn.zig        │  │
                    │                   └────────────────┘  │
                    └──────────────────────────────────────┘
```

## Modules

### proxy.zig

The access layer. Listens on loopback (default 8080 until M3 adds TLS on 443), reads the Host header, finds a route through four tiers (exact hostname, tunnel authority, tunnel hostname ignoring port, wildcard subdomain), then dials the backend over loopback. Unknown hosts get a 404 page listing live routes plus the command that would register yours. Requests carry a hop counter; five hops means a proxy loop, answered with a 508 whose body shows the fix.

- Inputs: HTTP requests, route list from the store
- Outputs: proxied responses, X-Forwarded headers set, error pages that teach
- Lineage: portless findRoute tiers (`proxy.ts:113-122`), hop detection (`proxy.ts:60-66`), helpful 404s (`proxy.ts:203-227`). See docs/research/portless-dossier.md.

### routes.zig

Route persistence. Lives in the same SQLite database as everything else per ADR-0002. A route is hostname, backend port, owning PID, and optional tunnel metadata. Conflict rule: registering a hostname held by a live PID fails unless forced, and force kills the old owner first.

- Inputs: registrations from run/alias, lookups from proxy
- Outputs: authoritative hostname-to-port map
- Lineage: portless RouteStore semantics (`routes.ts`) with portmap's storage discipline (migrations 001-003).

### scan.zig

TCP connect scanner. Default range 1000-9999, 500ms timeout, bounded pool of twenty workers, IPv4 first with IPv6 fallback only when IPv4 fails. Runs on demand only per ADR-0004; results are cached and republished after mutations without rescanning.

- Inputs: range config, explicit triggers
- Outputs: sorted open-port list
- Lineage: portmap scanner.rs verbatim in spirit (`scanner.rs:8-9, 62-77`), on-demand economics from their v0.8.0 lesson (CHANGELOG.md:15-16).

### containers.zig

Docker API client over the Unix socket. Lists running containers, keeps public ports bound to wildcard or loopback, attributes container names, detects Podman by version components. No socket means empty results, never an error.

- Inputs: container runtime socket
- Outputs: port-to-container attribution
- Lineage: portmap container.rs (`container.rs:47, 63-66, 100-110`).

### db.zig

SQLite via the linked amalgamation. Owns migrations, the routes table, the apps registry (name, port unique, category), and tag colors. One state file: ~/.berth/berth.db.

- Inputs: CRUD from CLI, API, and internal modules
- Outputs: every persistent fact berth knows
- Lineage: portmap schema shape (migrations 001-003) applied to portless's route problem per ADR-0002.

### kill.zig

The graceful ladder: lsof finds listeners, SIGTERM all, poll exit every 100ms up to two seconds using ownership-independent checks, SIGKILL survivors only. Reports not-found, killed, force-killed, or error honestly.

- Inputs: port number or app name
- Outputs: kill result enum
- Lineage: portmap process.rs:66-125, adopted after line-by-line review found no flaw.

### dash.zig

Embedded single-page dashboard. Table of ports and routes with name, category, source, status; SSE stream for live updates and scan progress; tag colors; edit and kill actions; toasts. No external assets, works from the binary alone.

- Inputs: merged view data, SSE subscribers
- Outputs: HTML, event streams
- Lineage: portmap template.rs dashboard (SSE events `lib.rs:412-441`, toasts `template.rs:1098+`).

### mdn.zig

Markdown content negotiation. Accept: text/markdown on / returns status plus an embedded API reference so an agent with nothing but the URL becomes fully operational. Standalone /markdown endpoint shares the renderer.

- Inputs: requests with Accept headers
- Outputs: markdown documents
- Lineage: portmap lib.rs:543-549 negotiation gate and lib.rs:597+ self-describing renderer.

### inject.zig

Framework flag injection for `berth run`. Apps receive PORT env; frameworks known to ignore it (vite, vp, react-router, rsbuild, astro, ng, react-native, expo) get flags injected into server subcommands only, reached through package runners, refused for compound commands, env prefixes, comments, and delegation.

- Inputs: user command lines
- Outputs: rewritten argv plus environment
- Lineage: portless cli-utils.ts:1095-1150 table and refusal rules, ported as comptime data.

### worktree.zig

Git worktree awareness. Linked worktrees on non-default branches prefix hostnames with the sanitized branch segment; main and master never prefixed; filesystem fallback when git is unavailable.

- Inputs: current directory context
- Outputs: optional hostname prefix
- Lineage: portless auto.ts:170-232 including the linked-vs-root distinction.

### certs.zig

TLS support, arriving M3. Minting spawns the openssl binary (never hand-rolled X.509); termination links OpenSSL with an SNI callback selecting per-host leaves; trust installation covers macOS, Linux, Windows, and WSL dual stores.

- Inputs: hostnames needing certificates
- Outputs: CA, leaf certs, trust state
- Lineage: portless certs.ts:231 spawn pattern, :791 SNI callback, WSL lessons from CHANGELOG #357. Decisions in ADR-0003.

### svc.zig

Service lifecycle. install writes a user-level LaunchAgent or systemd unit with restart-on-death semantics; uninstall reverses exactly; status reports manager, running state, startup setting. Homebrew-managed installs delegate to brew services messaging.

- Inputs: install/uninstall/status commands
- Outputs: OS service units, honest status output
- Lineage: portmap main.rs:397-497 (user-level choice deliberate; portless uses system daemons, we do not).

## Request path, end to end

1. Browser resolves myapp.localhost (hosts block or libc) to 127.0.0.1.
2. proxy.zig receives the request, counts hops, walks the four match tiers.
3. On match: forward to 127.0.0.1:{port} with forwarded headers; pipe the response.
4. On miss: render the teaching 404.
5. Meanwhile dash.zig and mdn.zig serve the merged view built by db.zig from routes, apps, scan results, and container discoveries.
6. Mutations (register, kill, retag) republish cached state over SSE without rescanning.

## What we deliberately do not build

HTTP/2 server semantics, RFC 8441 bridging, multi-segment TLD handling, ngrok integration before tailscale, periodic scanning of any kind. Each deferral has an ADR or an issue thread saying why, and each can be revisited when user pain demands it.
