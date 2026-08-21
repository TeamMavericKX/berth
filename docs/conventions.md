# Conventions

How berth code handles failure, talks to users, and logs. Twelve modules written fast need shared rules or the codebase forks stylistically. This page is the shared rules. It is short on purpose; when a rule needs a paragraph of exceptions, the rule is wrong.

## Errors: propagate or own, never swallow

Zig gives us error unions; use them.

1. Library-shaped modules (proxy, scan, db, containers, certs) return errors upward. They do not print, log, or exit.
2. The CLI layer owns every error a user can see. One place formats, one place decides exit codes.
3. A caught-and-continued condition must say so. Silent catch blocks fail review, always.
4. `unreachable` means provably impossible with a comment proving it. Anything less is a bug wearing a costume.

Error sets get names at module scope (`pub const DialError = error{ ConnectionRefused, Timeout };`), never anonymous long lists at call sites.

## User-facing tone

Every error message answers three questions in order: what failed, why, what to do next. The third part is not optional.

```
# Bad
error: bind failed

# Good
cannot bind 127.0.0.1:8080: address already in use
  something else owns this port. find it: berth list, or lsof -i :8080
```

portless's 508 page renders the exact config fix into the error body; that bar applies to our CLI text too. Error pages and messages are features with tests, not afterthoughts.

Rules of voice: lowercase first word, no exclamation marks, no apology theater, one suggestion per message. Commands in backticks. Paths as paths, never described.

## Logging

berth logs to stderr; data goes to stdout and never the reverse.

- Levels: `err` (operation failed), `warn` (degraded but continuing), `info` (lifecycle events: listening, route registered, service installed), `debug` (per-request routing decisions, injection decisions).
- Default level is `info`. `BERTH_LOG=debug` opts into the firehose.
- Debug logs exist wherever behavior would otherwise be invisible: which match tier resolved a host, why injection refused a script, why a scan trigger fired. portless's silent refusal grammar is the cautionary tale; ours explains itself at debug level.
- No secrets in logs: tokens print as first four characters plus ellipsis. Cert keys never print anywhere.
- Log lines are single-line key-value pairs so they grep cleanly: `route registered hostname=api.myapp.localhost port=4123 pid=8814`.

## Exit codes

0 success. 1 usage error. 2 operation failed (bind conflict, kill target missing). 3 environment problem (no openssl binary, unwritable state dir). CI scripts can trust these.

## Code shape

One module, one concern, matching docs/architecture.md. Functions stay under about forty lines; if a function needs section comments, it wants extraction. Tests live beside code in the same file; integration fixtures live in tests/. Formatting is whatever zig fmt says, enforced by CI, argued about nowhere.
