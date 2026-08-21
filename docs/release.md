# Release runbook

How a commit on main becomes an installable release. Written so either account can execute it without tribal knowledge. The release workflow (.github/workflows/release.yml) does the heavy lifting; this document is the judgment around it.

## Versioning

Semver, honest about pre-alpha: 0.x.y until M3 ships TLS, then we talk about 1.0. Breaking changes bump minor while in 0.x (0.2.0 may break 0.1.0 users; we say so here rather than pretending). The version string lives in build.zig.zon and src/main.zig; both must match, and CI will not check this for you yet — the releaser checks.

## Cutting a release

1. Update CHANGELOG.md: move Unreleased entries under the new version heading with the date. Entries come from conventional commits; write them as user-visible facts, not commit logs.
2. Bump version in build.zig.zon and src/main.zig. Run zig build test locally.
3. Commit: `chore(repo): release berth <version> here` (six words after type-scope; adjust wording to fit).
4. Tag and push: `git tag v0.x.y && git push origin v0.x.y`.
5. The release workflow builds ReleaseSafe for five targets, packages tarballs with checksums, and opens a **draft** GitHub release with generated notes.
6. Review the draft: notes accurate, five artifacts present, checksums match (`sha256sum -c` on one of them locally).
7. Publish the draft. Announce nowhere yet; we have no users to disturb and no appetite for theater.

## What the workflow does not do

- Sign binaries. Planned once we decide on a signing identity; unsigned for now, stated plainly in release notes.
- Homebrew tap. Deferred until M1 has something worth installing; portmap's tap structure is the reference.
- Windows installers. A zip inside the tarball flow is fine for now.

## Rollback

Releases are immutable once published. If a release is broken, cut a patch release; never mutate or delete a published tag. If a release must disappear (security), delete the draft before publish or mark the published release deprecated in its notes and ship the fix forward.

## Post-release

Open an issue titled `repo: post-release checklist for vX.Y.Z` containing: CI state on the release commit, artifact list, any known issues deferred. This is the paper trail that makes future archaeology cheap.
