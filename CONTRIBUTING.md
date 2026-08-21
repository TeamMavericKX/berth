# Contributing

berth is built issue-first. Research lands before code, issues land before branches, and every change ships through a pull request. This document is the law. PRs that break it get sent back, no hard feelings.

## The loop

Every unit of work follows the same cycle:

1. Pick an open issue. Comment your research and approach before writing code.
2. Branch from `main`: `feat/<area>-<slug>`, `fix/<area>-<slug>`, `docs/<slug>`.
3. Implement. Every commit message obeys the six-word law below.
4. Validate locally: `zig build && zig build test && zig fmt --check src/`.
5. Commit with `Co-authored-by:` trailer. Push. Open a PR that says `Closes #N`.
6. Review happens from a different account than the author.
7. Merge, delete the branch locally and remotely, prune stale branches.
8. Next issue.

## The six-word law

Commit subjects follow conventional commits with exactly six words in the description. Not five. Not seven. Six.

```
feat(proxy): route requests by host header      # 6 ✓
fix(scanner): stop scanning the dashboard port  # 7 ✗ rewrite it
docs(readme): explain the merged daemon story   # 6 ✓
```

Rules:

- Type is one of: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`, `perf`, `build`.
- Scope is the module or area: `proxy`, `scanner`, `db`, `dash`, `mdn`, `inject`, `certs`, `svc`, `repo`.
- Description is lowercase, imperative mood, no period, exactly six words.
- If six words cannot say it, the commit does too much. Split it.

## Commits and authorship

Commits carry both builders:

```
git config user.name "10xdev4u-alt"
git config user.email "10xdev4u@gmail.com"
```

Every commit includes:

```
Co-authored-by: the-ai-developer <the-ai-developer@users.noreply.github.com>
```

## Reviews

The author never merges their own PR. Review comes from `10xdev4u-alt` or `the-ai-developer`, whoever did not author. A review checks three things: does it close the issue, does it pass validation, does the commit history obey the six-word law.

## Validation gate

No PR opens red. Before pushing:

```sh
zig build              # compiles
zig build test         # tests pass
zig fmt --check src/   # formatting clean
```

CI runs the same three plus a commit-lint on PR titles. Red CI blocks merge, always.

## Issue hygiene

One issue, one concern. Issues carry receipts: file paths, line numbers, links to parent-project research. If an issue grows a second concern mid-flight, split it and reference the split.

## Branch hygiene

Branches are disposable. After merge, delete local and remote copies. Stale branches older than their milestone get pruned without ceremony. `main` always builds.
