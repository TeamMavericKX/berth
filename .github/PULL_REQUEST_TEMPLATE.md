<!--
PR title IS a commit subject: type(scope): exactly six lowercase words.
Example: feat(proxy): route requests by host header
-->

## Closes

<!-- Issue number this PR closes. One PR, one issue. -->

Closes #

## What changed

<!-- The shape of the change in three sentences or fewer. -->

## Validation

<!-- Paste real command output. Red PRs do not get reviewed. -->

```
zig build        # result
zig build test   # result
zig fmt --check src/  # result
```

## Reviewer checklist

- [ ] Closes exactly one issue and the issue's "done when" all pass
- [ ] Commit subjects obey the six-word law
- [ ] No new dependencies without an ADR
- [ ] Docs updated if behavior changed (docs-match-code rule)
