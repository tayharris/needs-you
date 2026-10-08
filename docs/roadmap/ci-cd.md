# CI/CD plan

Status (2026-10-08): phases 1 and 2 are built and run on GitHub on every push (`ci.yml`, `release.yml`; the jobs use self-hosted runners through the variables below, and fork pull requests use GitHub's images). Releases 0.1.2–0.1.5 were cut this way: the tag drafts the release with build-provenance attestations, and the owner publishes it. Phase 3 (signing and notarization) is a plan; it waits on a Developer ID. Differences from the plan below: the site is checked by `tests/test_site.py` inside the Python jobs instead of a separate `site` job, and a separate `site.yml` can deploy the site ([site-deploy.md](site-deploy.md)).

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

`.github/workflows/release.yml`, triggered on `push: tags: ['v*.*.*']` (and `workflow_dispatch` with `dry_run`, default on: build everything, upload it as a workflow artifact, no release, no tag):

1. `needs: [the ci jobs]` via a reusable workflow (`workflow_call` on `ci.yml`), so nothing builds unless tests pass on the tagged commit.
2. Check the tag matches the `VERSION` file (below); fail otherwise.
3. **Mac app** (`macos-latest`): `NEEDS_YOU_VERSION=$V mac/scripts/bundle.sh`; `ditto -c -k --keepParent mac/dist/NeedsYou.app NeedsYou-$V-macos.zip`; `NeedsYou-$V.dmg` with `hdiutil create -volname NeedsYou -srcfolder <the app plus an /Applications link> -format UDZO`.
4. **Server tarball** (`ubuntu-latest`): `git archive --prefix=needs-you-$V/ HEAD hub cli scripts deploy integrations docs README.md VERSION | gzip > needs-you-server-$V.tar.gz`.
5. **CLI:** `cli/needs-you` copied as `needs-you-cli-$V` (it's one file).
6. `sha256sum * > SHA256SUMS`. Built since: GitHub build provenance (Sigstore) for every asset, and an Ed25519 signature over `release-manifest.json` once the owner adds the key ([release-signing.md](../security/release-signing.md)).
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

## Self-hosted runners

GitHub-hosted jobs stop when the account's Actions billing or spending limit is a problem; self-hosted runners aren't billed by GitHub. Each job reads its runner from a repo variable (Settings → Secrets and variables → Actions → Variables), so switching is a settings change, not a code change. Unset variables mean GitHub's images, as before.

| Variable | Jobs | Self-hosted value |
|---|---|---|
| `CI_LINUX_RUNNERS` | `python-ubuntu` (a JSON list: one job per entry) | `[["self-hosted","linux"]]` |
| `CI_LINUX_RUNNER` | `shellcheck` | `["self-hosted","linux"]` |
| `CI_MAC_RUNNER` | `python-macos-39`, `mac` | `["self-hosted","macOS"]` |
| `RELEASE_MAC_RUNNER` | the release build | `["self-hosted","macOS"]` (a separate decision from CI) |

```bash
gh variable set CI_LINUX_RUNNERS --body '[["self-hosted","linux"]]'
gh variable set CI_LINUX_RUNNER --body '["self-hosted","linux"]'
gh variable set CI_MAC_RUNNER --body '["self-hosted","macOS"]'
gh variable delete CI_MAC_RUNNER     # back to GitHub's macOS image
```

Runner hosts need what GitHub's images have: `/usr/bin/python3` (3.9 on the Mac, for `python-macos-39`), `shellcheck` on the runner's `PATH` (set it in the runner's `.env`), `git`, and on the Mac the Command Line Tools (`swift`). A self-hosted runner runs every job as the user it runs as, so a job can read that user's files (`~/.config/gh`, `~/.ssh`, `~/.config/needs-you`). Run it as a **dedicated user account** with nothing else in its home, never as root and never as your own user. Pull requests from forks always use GitHub's images (the `runs-on` expressions check `head.repo.fork`). Setting one up on a Linux box (needs sudo once):

```bash
sudo useradd -m -s /bin/bash ghrunner && sudo loginctl enable-linger ghrunner
sudo -iu ghrunner bash -c 'mkdir actions-runner && cd actions-runner && curl -fsSLO https://github.com/actions/runner/releases/download/v<V>/actions-runner-linux-x64-<V>.tar.gz && tar xzf actions-runner-linux-x64-<V>.tar.gz'
# then ./config.sh with a registration token, and run.sh as a systemd user service of ghrunner
```

**Before the repo goes public**, delete these variables or move the runners to a runner group limited to this repo with fork-PR workflows requiring approval: on a public repo, anyone's pull request could run code on a self-hosted runner.

## Versioning

- One `VERSION` file at the repo root, semver. The hub and CLI keep their own `VERSION = "..."` line (they must stay single files that work without the repo); `tests/test_release.py` and `scripts/build-release.sh` fail unless all three agree, so a release bump edits three lines in one commit. `bundle.sh` reads `VERSION`.
- The API version (`v1`) is separate and changes only with a breaking wire change.
- Major: breaking API, config or data-format change. Minor: features. Patch: fixes.

## Changelog

`CHANGELOG.md` in Keep a Changelog format with an `Unreleased` section. The PR template gains "CHANGELOG updated (if user-visible)". The release job extracts the `## [X.Y.Z]` section as release notes.

## Open decisions

1. Keep the system-python jobs only, or add a `setup-python` 3.9–3.13 matrix too?
2. Apple Developer account: personal, or an org account for the eventual non-profit?

Settled: releases stay drafts that a person publishes; downloads are checked with `SHA256SUMS` plus GitHub build provenance (Sigstore), and an optional Ed25519 signature over `release-manifest.json` once the owner adds the key ([release-signing.md](../security/release-signing.md)).
