# ADR-0004: Scan on demand, never on a timer

Status: accepted · Date: 2026-08-21

## Context

portmap v0.8.0 removed continuous scanning after measuring "~400 CPU minutes over 15 days scanning ports every 10-30s even when nobody was looking" (CHANGELOG.md:15-16). The replacement blocks on a Notify channel with a 100ms debounce (`lib.rs:162-176`); refreshes come from explicit user or agent action. Their README still claims periodic discovery, which we verified is false (`template.rs:1258` shows browser auto-refresh defaulting to once per day).

## Decision

berth scans only when triggered: dashboard load, explicit refresh button or endpoint, CRUD operations that change liveness display, CLI list/kill commands, and agent API reads that ask for fresh data. Scan results are cached and republished after mutations without rescanning (portmap's `republish` pattern, `lib.rs:187-199`). SSE broadcasts scan start/done so the UI shows honest progress.

## Consequences

- Idle berth costs zero CPU. A sleeping daemon stays sleeping.
- First paint probes registered ports only, then triggers a full range scan in the background (portmap's fast-paint trick, `lib.rs:488-498`).
- Documentation must never claim periodic scanning. The README drift that hit portmap becomes a review checklist item here.
