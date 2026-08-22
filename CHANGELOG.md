# Changelog

All notable changes to berth are documented here. Format follows Keep a Changelog; versions follow semver; entries are generated from conventional commits and written by humans.

## [Unreleased]

## [0.2.0] - 2026-08-22

### Added

- Project governance: README, CONTRIBUTING with the six-word commit law, Apache-2.0 license
- Research dossier on portless and portmap with file:line receipts (`docs/research/`)
- Architecture decision records 0001 through 0004 (`docs/adr/`)
- CI: build, test, format check on Linux and macOS, six-word commit lint
- Issue backlog: 31 issues across five milestones M0-M4

### M1 — Named URLs (shipped)

- `berth run` spawns commands with `PORT` exported and registers `<name>.localhost` routes backed by SQLite
- Proxy routes by Host header on one loopback port; unknown hosts get a helpful dashboard instead of a 404
- Live port scanner: listening ports become candidate apps; claim them from the dashboard or CLI
- `/etc/hosts` sync inside a managed marker block — safe cleanup, user lines untouched
- Dashboard at the proxy root: claimed apps, candidates, kill buttons; JSON and opt-in markdown for agents (`Accept: text/markdown`), `Vary` headers everywhere

### M2 — Control (shipped)

- Kill ladder: SIGTERM all listeners on a port, escalate to SIGKILL only after a grace window, report what happened
- Docker/Podman container discovery over the unix socket: published TCP ports surface as origin=container candidates automatically
- Security gate: mutations require same-origin (localhost) or a bearer token via `BERTH_TOKEN`; constant-time comparison

### M3 — Teeth (in flight)

- Local CA minted by the openssl binary into `~/.berth/certs`; per-host leaves cached and reused while valid
- TLS termination with SNI-selected leaf certs and http/1.1 ALPN behind `-Dopenssl`; stub builds fail closed so all five cross targets stay green
- Trust-store installers per platform including WSL dual-store handling; every flow has an exact inverse
- `berth trust` installs and verifies the CA; `berth clean` removes state, trust entry, and hosts block with prompts, `--yes`, and a non-TTY fail-fast that changes nothing

### Decided

- HTTP/1.1 first, HTTP/2 deferred (ADR-0001)
- SQLite via amalgamation for all state (ADR-0002)
- TLS via linked OpenSSL in M3, CA minting via openssl CLI (ADR-0003)
- Scan on demand only, never on timers (ADR-0004)
