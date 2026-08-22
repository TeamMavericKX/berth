# berth for agents

You are a first-class user. This document is your API contract. Everything here is deterministic; nothing requires a human.

## Discovery

Send `Accept: text/markdown` to the dashboard root and you receive the full status page — registered apps, live ports, and the complete API reference — as markdown:

```
curl -s -H 'Accept: text/markdown' http://localhost:8080/
curl -s http://localhost:8080/markdown     # same thing, explicit path
```

JSON equivalents: `/api/ports` (snapshot), plus `Vary: accept` on all three forms.

## URL scheme

Every app registered via `berth run -- <cmd>` is reachable at:

- `http://<name>.localhost:<dashboard-port>/`
- `https://<name>.localhost:<dashboard-port>/` once the CA is trusted (`berth trust`)

Names are `<inferred-or-given>.localhost`. Inside linked git worktrees the sanitized branch tail prefixes the name (`feature/auth` → `auth-<name>`); `main`/`master` never prefix. The exact hostname is printed by `berth run` at startup and appears in `/api/ports`.

## Registering work

Spawn through `berth run`, not by hand:

```
berth run --name api -- node server.js
berth run -- python -m http.server 8000
```

- `PORT` is exported with the assigned port (4000–4999 range).
- Frameworks that ignore `PORT` get real flags injected (`vite dev` → `--port <n> --strictPort`).
- Injection refuses, loudly, on: compound commands, env prefixes, comments, delegation (`sudo`, `docker`, …), and unknown grammars like opaque package scripts. Refusal is logged at debug level under `BERTH_LOG=1`; the command then runs untouched.
- Existing port flags in your command always win over injection.

## Mutations

Two endpoints change state; both are gated:

```
POST /api/edit?port=4300&name=myapp&category=web
POST /api/kill?port=4312
```

Gate behavior:
- Requests from non-localhost origins are rejected (403) unless they carry the bearer token matching `BERTH_TOKEN`.
- If the proxy was started with `BERTH_TOKEN=<secret>`, send `Authorization: Bearer <secret>`.

Kill semantics: SIGTERM to every listener on that port, liveness polled zombie-aware for up to 2 seconds, SIGKILL only for survivors. Response tells you which outcome occurred (`killed`, `force_killed`, `not_found`).

## Tunnels

`berth run --tailscale …` / `--funnel …` expose the route over tailscale and record the ts.net authority on the route row. It appears in `/api/ports` output and the markdown dashboard's tunnel column. Tunnel failure degrades to local-only serving; the process keeps running.

## Safe patterns

1. **Read before write**: fetch `/api/ports`, match on `port`, never on guessed names.
2. **Kill by port, not pid**: berth owns the TERM→KILL ladder and reports outcomes.
3. **Prefer `berth run`** for spawning so cleanup is automatic on exit.
4. **Non-interactive cleanups**: `berth clean --yes`; plain `berth clean` refuses without a TTY by design.
5. **Check the tunnel column** before sharing URLs externally — localhost URLs are unreachable from other machines unless tunneled.

## Failure modes worth knowing

- Unknown host → teaching 404 listing live apps (never a bare error).
- Port conflict on registration → exit code 3 with the owning pid printed; dead pids do not block re-registration.
- Missing openssl → `berth trust` names the package to install instead of failing opaquely.
