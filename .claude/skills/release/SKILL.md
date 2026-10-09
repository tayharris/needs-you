---
name: release
description: Release steps for needs-you (changelog, version bump, tests, tag; the release workflow builds the Mac app DMG and zip, server tarball, CLI and checksums into a draft GitHub Release). Use when asked to cut, package or publish a release.
---

# release (manual, for now)

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which tests and then drafts the GitHub Release with `scripts/build-release.sh` (see `docs/roadmap/ci-cd.md`). The steps below are the manual fallback; `scripts/build-release.sh OUT_DIR` replaces step 4. To check the workflow without a tag, dispatch it as a dry run (`gh workflow run release.yml --ref <branch> -f dry_run=true`): it builds and uploads the assets as a workflow artifact and creates no release. Never push a tag or publish a release without the user's explicit go-ahead for that specific push.

## Channels: pre-release first, then promote

Every release goes out as a **pre-release** first; stable comes later, from the same build.

- **Cut** from `main` as below. When the workflow's draft is ready, publish it as a pre-release: `gh release edit vX.Y.Z --draft=false --prerelease`. Macs with Settings → Updates → **Releases and pre-releases** take it; stable Macs don't (they follow GitHub's "latest", which is never a pre-release). Senders follow the version their hub serves, so the owner's machines pick it up through the owner's Mac.
- **Soak** on the owner's Mac for a few days (or until the owner says it's good). Fixes go out as the next patch pre-release (0.4.1, ...).
- **Promote** with the owner's go-ahead: `gh release edit vX.Y.Z --prerelease=false --latest`. No rebuild; stable Macs see it as the newest release.
- Versions stay plain `X.Y.Z`: the Mac updater (`SemVer` in `Updater.swift`) and the CLI don't parse `-beta.N` suffixes, so the pre-release flag is the only marker. Minor bumps (0.4.0) for features or API additions, patch bumps for fixes.
- A stable fix while a pre-release is soaking: cut it from the stable tag on a `tay/<slug>` branch, tag `vX.Y.(Z+1)` there, publish it as stable, and merge the branch back to `main`.

## Versions

| Part | Where | Current |
|---|---|---|
| Hub | `VERSION` in `hub/needs_you_hub.py` (also served by `/v1/health`) | 0.4.0 |
| CLI | `VERSION` in `cli/needs-you` (`needs-you --version`) | 0.4.0 |
| MCP server | `VERSION` in `integrations/mcp/needs_you_mcp.py` (its `serverInfo.version`) | 0.4.0 |
| Mac app | `VERSION` at the repo root (`mac/scripts/bundle.sh` reads it; `NEEDS_YOU_VERSION` overrides); build number = `git rev-list --count HEAD` | 0.4.0 |

`VERSION`, the hub, the CLI and the MCP server must agree (`tests/test_release.py` checks); bump them all in one commit, with the `CHANGELOG.md` section. So must the version stamps the hub reports on `/dl/manifest.json` (`needs-you-version: X.Y.Z` in `integrations/claude-code/needs-you-hook.sh`, `skill/needs-you/SKILL.md`, `integrations/orca/snippet.md`, and `"_needs_you_version"` in `hooks.json`; for Codex and Gemini CLI, the stamp in `integrations/<agent>/install-<agent>-hooks.sh` and `"_needs_you_version"` in `integrations/<agent>/<agent>-hooks.json`; the stamps in `integrations/opencode/needs-you.js` and `install-opencode-plugin.sh`; for Copilot CLI, `install-copilot-hooks.sh` and `"_needs_you_version"` in `copilot-hooks.json`; for Grok Build the same in `integrations/grok/`; for Cursor, `install-cursor-hooks.sh` and `"_needs_you_version"` in `cursor-hooks.json`; `integrations/cline/install-cline-hooks.sh`; `integrations/aider/install-aider-notifications.sh`; `integrations/claude-code/needs-you-usage`; `INSTALLER_VERSION` and its stamp in `scripts/install-hub.sh` (the server installer, also a release asset); for Kimi Code, `install-kimi-hooks.sh` and the `# needs-you-version:` line in `kimi-hooks.toml`; `integrations/agent-instructions/needs-you.md` is generated from SKILL.md, so after bumping SKILL.md run `python3 scripts/build_agent_instructions.py`); `scripts/build-release.sh` and `tests/test_updates.py` check them.

## Steps

1. **Clean tree on `main`**, up to date: `git status` clean, `git pull --ff-only` (in the main clone, not a worktree on another branch).
2. **Bump** `VERSION` in `hub/needs_you_hub.py`, `cli/needs-you` and `integrations/mcp/needs_you_mcp.py`, and every version stamp above; commit `release: vX.Y.Z`.
3. **Test:** run the `test-all` and `smoke-e2e` skills. Stop on any failure.
4. **Build into a temp dir** (not the repo):

   ```bash
   V=X.Y.Z; OUT=$(mktemp -d)/needs-you-$V; mkdir -p "$OUT"
   NEEDS_YOU_VERSION=$V mac/scripts/bundle.sh
   ditto -c -k --keepParent mac/dist/NeedsYou.app "$OUT/NeedsYou-$V-macos.zip"
   STAGE=$(mktemp -d); ditto mac/dist/NeedsYou.app "$STAGE/NeedsYou.app"; ln -s /Applications "$STAGE/Applications"
   hdiutil create -volname NeedsYou -srcfolder "$STAGE" -format UDZO -ov "$OUT/NeedsYou-$V.dmg"
   git archive --format=tar.gz --prefix=needs-you-$V/ -o "$OUT/needs-you-server-$V.tar.gz" HEAD \
     hub cli scripts deploy integrations docs README.md LICENSE
   cp cli/needs-you "$OUT/needs-you-cli-$V"
   (cd "$OUT" && shasum -a 256 * > SHA256SUMS)
   ```

5. **Smoke the artifacts:** open the DMG (the window shows the app and an Applications link), unzip the app and launch it in demo mode (`NEEDS_YOU_DEMO=1 .../Contents/MacOS/NeedsYou`); extract the tarball and run `python3 hub/needs_you_hub.py --help`; run the CLI copy with `--version`.
6. **Tag** (ask first): `git tag -a vX.Y.Z -m "needs-you X.Y.Z"`; push only with approval.
7. **GitHub Release** (ask first; the tag push drafts it, so usually just publish the draft as a pre-release, above): `gh release create vX.Y.Z "$OUT"/* --title "needs-you X.Y.Z" --notes-file <notes>`. Notes: user-visible changes, any API changes (link `docs/API.md`), upgrade steps (`git pull && sudo ./scripts/install-hub.sh` for server hubs).

## Notes

- The app is **ad-hoc signed**. Say so in the release notes: first launch needs right-click → Open, and endpoint security (SentinelOne etc.) may flag it. Developer ID signing and notarization are in the CI/CD plan.
- Never include `mac/dist/` or `.build/` in git, or tokens/DBs in the tarball (`git archive` only takes tracked files).
- The license is Apache-2.0 (`LICENSE`). A public release still waits on the rest of `docs/roadmap/sharing-checklist.md`.
