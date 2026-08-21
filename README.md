# berth

One daemon that proxies your dev servers AND shows you everything running on your machine.

berth takes the two best ideas in local port tooling and merges them. From [portless](https://github.com/vercel-labs/portless): stable named URLs like `https://myapp.localhost` instead of port-number lotto. From [portmap](https://github.com/vibber-ai/portmap): a live registry of every port on your machine, with names, tags, and a kill button. Neither tool does both. berth does both, in one static Zig binary with zero runtime dependencies.

## Why merge them

A reverse proxy already knows every route, PID, and port that flows through it. The visibility layer comes almost free once the proxy exists. We verified this reading both codebases line by line; the receipts live in [docs/research](docs/research/).

The short version:

| Problem | portless | portmap | berth |
|---|---|---|---|
| Named `.localhost` URLs | yes | no | yes |
| See every listening port | only its own children | yes | yes |
| Kill a process by port | no | yes | yes |
| Runtime required | Node 24+ | none (static) | none (static) |
| Agent interface | URLs + doctor | markdown API + skills | both styles |
| Known flaw | needs sudo + CA trust | permissive CORS on kill API | fix both |

## Status

Pre-alpha. Design phase. The full build plan lives in the issue tracker, organized into five milestones:

- M0 Foundation: build system, CI, governance
- M1 Spine: HTTP/1.1 proxy, host routing, route store
- M2 Sight: scanner, SQLite registry, dashboard, kill, markdown API
- M3 Teeth: TLS with SNI, local CA, trust store install
- M4 Polish: worktree prefixes, framework injection, tunnels, services

## Build

Requires Zig 0.16.x. Nothing else.

```sh
zig build
zig build test
```

## Design principles

1. One binary, static, cross-compiled. If it needs a runtime, we failed.
2. Loopback by default. Network exposure is an explicit flag, never a default.
3. Scan on demand, never on a timer. portmap burned 400 CPU-minutes learning this.
4. Every error page teaches the fix. A 508 should tell you exactly which config line to change.
5. Agents are first-class users. Markdown in, JSON out, deterministic URLs.

## Security

The dashboard and its API bind to loopback only. Mutating endpoints
(`/api/edit`, `/api/kill`) reject any request whose `Origin` header is
present and not a loopback host — a random website cannot make your
browser murder dev servers via `fetch`. Read endpoints stay open by
design.

Set `BERTH_TOKEN=<secret>` when running `berth serve` to additionally
require `Authorization: Bearer <secret>` on every mutation; agents can
pass it with `curl -H "Authorization: Bearer $BERTH_TOKEN"`.

## License

Apache-2.0. See [LICENSE](LICENSE).
