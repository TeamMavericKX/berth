# Changelog

All notable changes to berth are documented here. Format follows Keep a Changelog; versions follow semver; entries are generated from conventional commits and written by humans.

## [Unreleased]

### Added

- Project governance: README, CONTRIBUTING with the six-word commit law, Apache-2.0 license
- Research dossier on portless and portmap with file:line receipts (`docs/research/`)
- Architecture decision records 0001 through 0004 (`docs/adr/`)
- CI: build, test, format check on Linux and macOS, six-word commit lint
- Issue backlog: 31 issues across five milestones M0-M4

### Decided

- HTTP/1.1 first, HTTP/2 deferred (ADR-0001)
- SQLite via amalgamation for all state (ADR-0002)
- TLS via linked OpenSSL in M3, CA minting via openssl CLI (ADR-0003)
- Scan on demand only, never on timers (ADR-0004)
