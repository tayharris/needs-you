---
name: release
description: Release steps for needs-you (changelog, version bump, tests, tag; the release workflow builds the Mac app zip, server tarball, CLI and checksums into a draft GitHub Release). Use when asked to cut, package or publish a release.
---

# release (manual, for now)

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which tests and then drafts the GitHub Release with `scripts/build-release.sh` (see `docs/roadmap/ci-cd.md`). The steps below are the manual fallback; `scripts/build-release.sh OUT_DIR` replaces step 4. Never push a tag or publish a release without the user's explicit go-ahead for that specific push.

## Versions

| Part | Where | Current |
|---|---|---|
| Hub | `VERSION` in `hub/needs_you_hub.py` (also served by `/v1/health`) | 1.0.0 |
| CLI | `VERSION` in `cli/needs-you` (`needs-you --version`) | 1.0.0 |
| Mac app | `VERSION` at the repo root (`mac/scripts/bundle.sh` reads it; `NEEDS_YOU_VERSION` overrides); build number = `git rev-list --count HEAD` | 1.0.0 |

`VERSION`, the hub and the CLI must agree (`tests/test_release.py` checks); bump all three in one commit, with the `CHANGELOG.md` section.

## Steps

1. **Clean tree on `main`**, up to date: `git status` clean, `git pull --ff-only` (in the main clone, not a worktree on another branch).
2. **Bump** `VERSION` in `hub/needs_you_hub.py` and `cli/needs-you`; commit `release: vX.Y.Z`.
3. **Test:** run the `test-all` and `smoke-e2e` skills. Stop on any failure.
4. **Build into a temp dir** (not the repo):

   ```bash
   V=X.Y.Z; OUT=$(mktemp -d)/needs-you-$V; mkdir -p "$OUT"
   NEEDS_YOU_VERSION=$V mac/scripts/bundle.sh
   ditto -c -k --keepParent mac/dist/NeedsYou.app "$OUT/NeedsYou-$V-macos.zip"
   git archive --format=tar.gz --prefix=needs-you-$V/ -o "$OUT/needs-you-server-$V.tar.gz" HEAD \
     hub cli scripts deploy integrations docs README.md
   cp cli/needs-you "$OUT/needs-you-cli-$V"
   (cd "$OUT" && shasum -a 256 * > SHA256SUMS)
   ```

5. **Smoke the artifacts:** unzip the app and launch it in demo mode (`NEEDS_YOU_DEMO=1 .../Contents/MacOS/NeedsYou`); extract the tarball and run `python3 hub/needs_you_hub.py --help`; run the CLI copy with `--version`.
6. **Tag** (ask first): `git tag -a vX.Y.Z -m "needs-you X.Y.Z"`; push only with approval.
7. **GitHub Release** (ask first): `gh release create vX.Y.Z "$OUT"/* --title "needs-you X.Y.Z" --notes-file <notes>`. Notes: user-visible changes, any API changes (link `docs/API.md`), upgrade steps (`git pull && sudo ./scripts/install-hub.sh` for server hubs).

## Notes

- The app is **ad-hoc signed**. Say so in the release notes: first launch needs right-click → Open, and endpoint security (SentinelOne etc.) may flag it. Developer ID signing and notarization are in the CI/CD plan.
- Never include `mac/dist/` or `.build/` in git, or tokens/DBs in the tarball (`git archive` only takes tracked files).
- No LICENSE yet: the license is chosen at public launch. Don't publish a public release before that.
