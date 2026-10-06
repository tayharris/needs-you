# CI/CD plan

Status: phases 1 and 2 exist as `.github/workflows/ci.yml` and `release.yml` (not yet run on GitHub). Phase 3 is a plan. Differences from the plan below: no `shellcheck` job yet (a `bash -n` job instead, until existing findings are fixed), no `site` job, and no version stamping (see Versioning).

Goal: every push and PR runs the same suites a contributor runs locally (`test-all` skill), and pushing a `vX.Y.Z` tag produces a GitHub Release with the Mac app, the server tarball and the CLI, checksummed, after the tests pass. Signing comes in a later phase because it needs paid-account secrets.

## Phase 1: tests on every push and PR

Add `.github/workflows/ci.yml`:

| Job | Runner | Steps |
|---|---|---|
| `python-ubuntu` | `ubuntu-22.04`, `ubuntu-latest` (matrix) | `actions/checkout`; `python3 --version`; `python3 -m unittest discover -s tests`. Use the **system** python3 (3.10 / 3.12), no `setup-python`, because that's what hub users run. |
| `python-macos-39` | `macos-14` | `/usr/bin/python3 --version` must print 3.9.x; `/usr/bin/python3 -m unittest discover -s tests`. This is the compatibility floor (stdlib-only, 3.9 syntax). If GitHub's image ever drops `/usr/bin/python3` 3.9, add a `setup-python` 3.9 job instead. |
| `mac` | `macos-latest` | `cd mac && swift build`; `mac/scripts/test.sh` (XCTest is available on the image); `mac/scripts/bundle.sh`; upload `mac/dist/NeedsYou.app` zipped as a 7-day artifact for PR review. |
| `shellcheck` | `ubuntu-latest` | `shellcheck` is preinstalled: `shellcheck scripts/*.sh mac/scripts/*.sh deploy/*.sh integrations/*/*.sh`. Start with `-S warning` and fix or annotate existing findings first. |
| `py39-syntax` | `ubuntu-latest` | Cheap guard: `python3 -m py_compile` under a 3.9 interpreter is covered by `python-macos-39`; optionally add `vermin -t=3.9-` later (not a runtime dependency). |
| `site` | `ubuntu-latest` | Serve `site/` with `python3 -m http.server` and `curl -f` it; run an HTML structure check (a stdlib `html.parser` script in `site/check.py` or `tests/`). |

Settings: `permissions: contents: read`; `concurrency` per ref with cancel-in-progress; path filters so a docs-only change skips `mac`. Pin actions by SHA. Require `python-*`, `mac` and `shellcheck` in branch protection on `main`.

Files to add: `.github/workflows/ci.yml`, and later the conformance job (see [ADR 0004](../adr/0004-always-on-hub.md) and [ai-first.md](ai-first.md)) that runs `protocol/conformance` against every hub implementation.

## Phase 2: release on tag

Cutting a release: rename `## [Unreleased]` in `CHANGELOG.md` to `## [X.Y.Z] - <date>` (and add a fresh `Unreleased` above it), bump the three versions, commit, then tag `vX.Y.Z` and push the tag (with approval). `scripts/build-release.sh OUT_DIR` builds the same assets locally. The fresh-user check is [fresh-user-test-plan.md](fresh-user-test-plan.md).

`.github/workflows/release.yml`, triggered on `push: tags: ['v*.*.*']`:

1. `needs: [the ci jobs]` via a reusable workflow (`workflow_call` on `ci.yml`), so nothing builds unless tests pass on the tagged commit.
2. Check the tag matches the `VERSION` file (below); fail otherwise.
3. **Mac app** (`macos-latest`): `NEEDS_YOU_VERSION=$V mac/scripts/bundle.sh`; `ditto -c -k --keepParent mac/dist/NeedsYou.app NeedsYou-$V-macos.zip`.
4. **Server tarball** (`ubuntu-latest`): `git archive --prefix=needs-you-$V/ HEAD hub cli scripts deploy integrations docs README.md VERSION | gzip > needs-you-server-$V.tar.gz`.
5. **CLI:** `cli/needs-you` copied as `needs-you-cli-$V` (it's one file).
6. `sha256sum * > SHA256SUMS`. Later: sign `SHA256SUMS` with a minisign or Sigstore key.
7. `gh release create v$V --draft --notes-file <changelog section>` with all files. A human publishes the draft.

Permissions: `contents: write` only in the release job.

## Phase 3: signing and notarization

Needs a paid Apple Developer account (decision in [distribution.md](distribution.md)).

| Secret | Use |
|---|---|
| `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD` | Developer ID Application cert, imported into a temporary keychain |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Name (TEAMID)` |
| `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8_BASE64` | App Store Connect API key for `notarytool` |

Steps: `bundle.sh` gains an optional `NEEDS_YOU_SIGN_IDENTITY` (default stays ad-hoc `-`) and signs with `--options runtime --timestamp` plus an entitlements file; then `xcrun notarytool submit --wait`, `xcrun stapler staple`, `spctl -a -vv` as a check. Use an `environment: release` with required reviewers so secrets are only available to tag builds.

## Versioning

- One `VERSION` file at the repo root, semver. The hub and CLI keep their own `VERSION = "..."` line (they must stay single files that work without the repo); `tests/test_release.py` and `scripts/build-release.sh` fail unless all three agree, so a release bump edits three lines in one commit. `bundle.sh` reads `VERSION`.
- The API version (`v1`) is separate and changes only with a breaking wire change.
- Major: breaking API, config or data-format change. Minor: features. Patch: fixes.

## Changelog

`CHANGELOG.md` in Keep a Changelog format with an `Unreleased` section. The PR template gains "CHANGELOG updated (if user-visible)". The release job extracts the `## [X.Y.Z]` section as release notes.

## Open decisions

1. Keep the system-python jobs only, or add a `setup-python` 3.9–3.13 matrix too?
2. Draft releases (a human publishes) or publish automatically?
3. Checksum signing: minisign key, Sigstore keyless, or none at first?
4. Apple Developer account: personal, or an org account for the eventual non-profit?
