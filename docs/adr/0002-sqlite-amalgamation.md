# ADR-0002: SQLite via amalgamation, not JSON

Status: accepted · Date: 2026-08-21

## Context

portless persists routes as JSON with an mkdir-based lock protocol (`routes.ts:117-146`). portmap persists apps and tag colors in SQLite through sqlx with real migrations (`db.rs:38-43`, migrations 001-003). berth needs both a route store and a registry.

## Decision

berth links `sqlite3.c` (the public-domain amalgamation) directly into the binary. Schema follows portmap's shape: `apps`, `tag_colors`, unique index on non-empty names. Routes known to the proxy live in the same database rather than a separate JSON file.

## Consequences

- One state file: `~/.berth/berth.db`. Crash-safe, queryable, constraint-enforced.
- No lock protocol to invent; SQLite handles concurrency.
- Binary grows by roughly one megabyte. Acceptable for a static tool.
- JSON export remains available through the API for agents that want it.
