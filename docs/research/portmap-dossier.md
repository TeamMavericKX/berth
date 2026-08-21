# Research: portmap (vibber-ai/portmap)

Cloned 2026-08-21 at commit `04a3725`. v0.8.1 (released 2026-07-02), Rust edition 2024, ~4,344 lines across 10 source files plus 3 SQL migrations and 2 integration test files. Started as `JonasKs/portmap`, moved to vibber-ai org. Distributed via Homebrew tap and source builds; `publish = false` on crates.io.

## What it is

A localhost port registry and dashboard. Tagline: "Map names to localhost ports. Made for agents and humans." README positions it as "a lightweight alternative to Vercel's Portless" that "doesn't hijack your localhost with subdomain routing or break OAuth flows" (`README.md:9`). It scans TCP ports, lets users and agents name and tag them, persists everything in SQLite, and serves a live dashboard.

## Architecture, from source

Three data sources merge into one table via `build_port_entries`, priority order baked in (`ports.rs:31-100`): registered app beats container beats known macOS port beats anonymous.

1. **Scanner** (`scanner.rs`): TCP connect scan, default range 1000-9999, 500ms connect timeout, 20 concurrent probes in a bounded JoinSet window. IPv4 first, IPv6 fallback only if IPv4 fails (`scanner.rs:62-77`).
2. **Container discovery** (`container.rs`): bollard client over the local Docker socket, running containers only (`all: false`, line 47), public ports bound on wildcard or loopback kept (lines 63-66), Podman detected by inspecting version components (lines 100-110). Client cached in a `OnceCell`.
3. **SQLite registry** (`db.rs` + migrations): `apps(id, name, port UNIQUE, category, created_at)`, `tag_colors(category PK, color)`, unique index on non-empty names (migration 003). sqlx with `mode=rwc` create-on-open. DB at `~/.config/portmap/portmap.db`, auto-migrates from legacy `~/.portmap.db` (`config.rs:88-110`).

Server is axum bound explicitly to `127.0.0.1:{port}` (`main.rs:150-152`), default port 1337.

## The API surface

Routes registered in `lib.rs:63-78`: dashboard `/`, markdown `/markdown`, JSON `/api/ports`, CRUD `/api/apps` plus bulk upsert, SSE `/events`, kill `/api/kill/{port}`, refresh `/api/refresh`, tag colors. Two details matter:

- **Content negotiation**: send `Accept: text/markdown` to `/` and receive a full status page with the API reference embedded, so an LLM can self-discover registration, update, and kill without docs (`lib.rs:543-549`, renderer at `lib.rs:597+`).
- **SSE events**: two event types, `refresh` carrying full payload JSON and `scan` carrying start/done, keepalive every 15s (`lib.rs:412-441`).

## Process killing

`process.rs:66-125` implements a graceful ladder: find PIDs via `lsof -ti :PORT -sTCP:LISTEN`, SIGTERM all, poll exit every 100ms for up to 2s using ownership-independent `ps -p` checks, then SIGKILL survivors only. Result enum distinguishes NotFound, Killed, ForceKilled, Error.

## Scanning economics

v0.8.0 replaced continuous scanning after it "burned ~400 CPU minutes over 15 days scanning ports every 10-30s even when nobody was looking" (CHANGELOG.md:15-16). Now `scan_worker` blocks on a Notify channel with 100ms debounce; there is no periodic timer server-side (`lib.rs:162-176`). Refresh triggers: POST /api/refresh, GET /api/ports (inline full scan), GET /markdown (inline), browser fetch on page load, and a browser auto-refresh timer whose default is once per day (`AR_DEFAULT = 1440` minutes, `template.rs:1258`).

Gotcha we verified: the README Features section still claims "Full discovery runs every 60s while the dashboard is open" which has been false since 0.8.0. Trust the changelog.

## Security posture

No privileges needed: no sudo, no CA, no hosts-file writes. Binds loopback explicitly. Rust hygiene: `unsafe_code = "forbid"`, clippy pedantic denied (`Cargo.toml:26-29`), release profile strips + LTO + opt-level "z".

The one real flaw: `CorsLayer::permissive()` on the entire router (`lib.rs:79`). Any website open in any browser can `fetch('http://localhost:1337/api/kill/3000', {method:'POST'})` since there is no auth and no Origin check. berth fixes this with an Origin allowlist plus optional token.

## Known ports catalog

11 macOS system ports (AirPlay 5000/7000, Screen Sharing 5900, APNS 5223, Handoff 8770, etc.) so scans read like a map instead of mystery listeners. Compiled in only on macOS targets via `cfg!(target_os = "macos")` (`known_ports.rs:74`).

## Agent skills

Ships as a Claude Code plugin marketplace with two skills (`skills/portmap/SKILL.md`, `skills/port-allocation/SKILL.md`): one teaches querying and managing via the markdown endpoint, one teaches port allocation discipline when creating new services.
