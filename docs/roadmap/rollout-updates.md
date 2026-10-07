# Rollout and updates: every machine on the version that passed

Status: plan, nothing built, 2026-10-07.

The owner runs the Mac app plus several Linux sender machines reached over SSH (devbox and friends), each with the CLI, the Claude Code hook and skill, and often the Orca prompt block. Today each piece updates by hand. Goal: **a release that passed its tests reaches the Mac app shortly after it ships, and from there every sender, with no SSH loop needed in the normal case**, and the owner can see which machines lag.

## Findings: what exists

| Piece | Where it comes from today | How it updates today |
|---|---|---|
| Mac app | `mac/scripts/install.sh` (build or `--app PATH`), or the release zip | By hand. `install.sh` quits gracefully, swaps `/Applications/NeedsYou.app`, keeps `NeedsYou.app.previous`, relaunches with `open -g`, puts the old one back if the new one doesn't stay running, and has `--rollback` |
| Embedded hub | `NeedsYou.app/Contents/Resources/hub/` (bundled by `mac/scripts/bundle.sh`) | With the app |
| What the hub serves on `/dl` | `DOWNLOADS` in `hub/needs_you_hub.py`: `needs-you`, `needs-you-hook.sh`, `install-hooks.sh`, `hooks.json`, `SKILL.md`, read from `install_dir` (the bundle's `Resources/` on the Mac, the checkout or tarball on a server hub) | With the app or the server tarball |
| Sender CLI | Invite installer (`hub/join-install.sh`) fetches `/dl/needs-you` | `needs-you self-update`: first healthy hub's `/dl/needs-you`, checks it starts with `#!`, contains `def main(` and compiles, then atomic replace. **No checksum, CLI only**: hook, `hooks.json`, skill and Orca snippet aren't touched |
| Hook | Installer runs `/dl/install-hooks.sh`, which fetches the hook | Re-run the installer. `doctor` flags an "old hook" by a marker string (`HOOK_MARKER`) |
| Skill | Installer `--skill` writes `~/.claude/skills/needs-you/SKILL.md` | Re-run the installer |
| Orca prompt block | Installer `--orca` writes `~/.config/needs-you/orca-snippet.md` from a heredoc inside `join-install.sh` (not on `/dl`); people paste it into automation prompts | Never: the pasted copy is frozen in each prompt |
| Version reporting | CLI sends `User-Agent: needs-you-cli/<v>`; `doctor` compares the CLI with each hub's `/v1/health` version and hints `self-update` | The hub records nothing per sender |
| Releases | A `v*` tag → `ci.yml` (tests) → **draft** GitHub Release with `NeedsYou-<v>-macos.zip`, server tarball, CLI and `SHA256SUMS` (`release.yml`, `needs: test`). A person publishes the draft | The repo is **private** (collaborators only): anonymous `api.github.com/repos/.../releases/latest` returns 404. One draft exists (0.1.1) |

Key observation: **the Mac app already carries the CLI, hook, hooks.json and skill, and its embedded hub serves them to every sender.** So "update the Mac app" already means "the hub now offers the new sender files". What's missing is (a) the Mac app updating itself, (b) senders pulling all their files (not just the CLI) with verification, on a schedule, and (c) someone seeing who's behind.

## Findings: external

- **Quarantine.** macOS adds `com.apple.quarantine` only when the downloading app sets `LSFileQuarantineEnabled` (browsers do) or is sandboxed; a non-sandboxed app downloading with `URLSession` gets no quarantine flag, and custom updaters routinely don't set it or strip it ([Eclectic Light: who decides to quarantine](https://eclecticlight.co/2025/12/08/who-decides-to-quarantine-files/), [quarantine flag](https://eclecticlight.co/2020/10/29/quarantine-and-the-quarantine-flag/)). So a built-in updater's zip never hits the Gatekeeper first-launch dialog. That makes the app's own SHA-256 check the only gate, so it must be strict.
- **Ad-hoc signatures change every build.** No Keychain impact any more (tokens are in `tokens.json`), but the macOS application firewall, when it's on, ties its "allow incoming connections" rule to the signature, so it can prompt again after each update ([distribution.md](distribution.md)). Until the owner clicks Allow, remote senders can't reach the embedded hub over the tailnet. Loopback senders are unaffected, and remote senders queue in their outbox.
- **Sparkle 2** needs EdDSA-signed updates (`SUPublicEDKey`), an appcast at a public HTTPS `SUFeedURL`, and is normally added through Xcode/SwiftPM; library validation under the hardened runtime wants a real signing identity ([Sparkle docs](https://sparkle-project.org/documentation/)). It's a dependency, so it needs an ADR (hard rule 1). It also doesn't solve the private-repo phase: the appcast and the zips must be downloadable without credentials.
- **Claude Code plugins** can bundle hooks and skills and auto-update from a marketplace at startup; third-party marketplaces default to auto-update off; private repos need `GITHUB_TOKEN` in the environment for background updates. That covers hook and skill but not the CLI, and needs git credentials on every sender, so it's a later option once the repo is public.
- **GitHub API.** With auth, `GET /repos/{o}/{r}/releases/latest` returns the newest published (non-draft, non-prerelease) release with `published_at` and assets; `GET /repos/{o}/{r}/actions/runs?head_sha=<sha>&event=push` gives the release run's `conclusion`. Asset downloads go through `GET /repos/{o}/{r}/releases/assets/{id}` with `Accept: application/octet-stream`.

## Recommendation

**One primary path, a chain with one gate:**

```
tag vX.Y.Z → CI tests pass → draft release (+ release-manifest.json) → person publishes
   → Mac app sees it (≤ 6 h), waits out a soak, verifies SHA256SUMS, stages, installs when idle
   → the embedded hub now serves the new CLI/hook/skill + /dl/manifest.json
   → each sender's daily `needs-you update --auto` (from flush) pulls, verifies, installs
   → each sender reports its versions on every call; Settings shows "2 machines out of date"
```

- **The gate is "published and green".** `release.yml` already drafts only after `ci.yml` passes; publishing the draft is the human "ship" step. The app additionally requires the release's `release-manifest.json` asset (written only by the release job after the tests and the checksum step), a matching `SHA256SUMS` line, and, when it can query Actions, a `success` conclusion for the release run on that tag's commit. Plus a soak: install no earlier than `published_at + 2 h` (setting; 0 to disable), so a release pulled within that window never lands.
- **The Mac app checks GitHub itself** through one small `UpdateSource` in `NeedsYouCore`, with auth chosen by what's available: (1) anonymous once the repo is public; (2) while private, the GitHub token from `gh auth token`, run from a fixed path (`/opt/homebrew/bin/gh`, `/usr/local/bin/gh`), held in memory only, never logged; (3) a fine-grained PAT (Contents: read, Actions: read on this one repo) in `~/Library/Application Support/NeedsYou/github.token`, mode 600, for Macs without `gh`. A hub relay was considered (a server hub holding a PAT and serving the manifest and zip to reader tokens): it centralizes one credential, but the default setup has no server hub, and it adds an outbound credential to a component that's stdlib-only and tailnet-only by design. Keep it as an option for later.
- **A small built-in updater, not Sparkle.** Everything it needs is already in the OS (URLSession, CryptoKit SHA-256, `ditto`, `codesign --verify`) and in `mac/scripts/install.sh`. Sparkle would add a dependency (ADR), an appcast that must be public, and an EdDSA key to manage, and it pays off mainly with a Developer ID build. Revisit Sparkle when the repo is public **and** there's a Developer ID (write the ADR then).
- **Senders follow their hub, not GitHub.** Their trust anchor is already the hub (it minted their token and served their installer), so they pull from `/dl`, with a manifest listing each file's SHA-256. On a sender this checksum guards against truncated or mixed-version downloads, not against a malicious hub; that's the same trust as today and is written down as such.
- **Orca blocks stop being frozen copies.** The block that gets pasted into prompts becomes a two-line pointer: "Before posting, read `~/.config/needs-you/orca-snippet.md` and follow it." The file is updated with the rest, so prompts pick up new rules on their next run.
- **`scripts/rollout.sh` is the fallback**, not the main path: for a machine that's never online when its hub is up, for first-time setup of a fleet, and to check everyone at once. It loops over a hosts file and runs `needs-you update && needs-you doctor --json` over SSH.

## Mac app auto-update design

**Check.** At launch (after 2 minutes) and every 6 hours, plus a **Check now** button in Settings. Off by default until the owner decides (open decision 1); when on, the request goes to `api.github.com` only, carries no item data, and Settings says so.

**Decide** (pure, `NeedsYouCore/Updater.swift`):

| Check | Rule |
|---|---|
| Release state | not `draft`, not `prerelease` |
| Version | the tag `vX.Y.Z` > `CFBundleShortVersionString` (numeric compare; the same `X.Y.Z` the `VERSION` file enforces) |
| Manifest | `release-manifest.json` asset present: `{"version", "commit", "run_id", "assets": [{"name", "sha256", "size"}], "min_macos"}`; its version matches the tag; `min_macos` ≤ this Mac's |
| Tests | if Actions is readable: the run `run_id` concluded `success` and its `head_sha` = `commit`. If not readable (anonymous, rate-limited), the manifest's existence stands in for it, since only the release job, after `needs: test`, uploads it |
| Soak | now ≥ `published_at` + soak (default 2 h) |
| Skip | not a version the user chose to skip, and not the version just rolled back from |

**Download and stage.** In the background, the zip goes to `~/Library/Application Support/NeedsYou/Updates/<v>/`. Verify size and SHA-256 against both the manifest and `SHA256SUMS` (fetched separately). Unzip with `/usr/bin/ditto -x -k`. Check the staged bundle: `CFBundleIdentifier` equals ours, `CFBundleShortVersionString` equals the tag, `codesign --verify --deep --strict` passes (an ad-hoc signature still seals the bundle's contents). If a quarantine attribute is somehow present, remove it from the staged copy only (`xattr -dr com.apple.quarantine`), justified by the checksum we just verified. Keep at most one staged version; delete older ones.

**Install.** Never while the panel is expanded, the pointer is over it, or an item arrived in the last 2 minutes. Automatically when the user has been idle for 10 minutes (`CGEventSource.secondsSinceLastEventType`) or when the app is quitting; or at once from **Restart to update** in Settings or the right-click menu (a click, so allowed). Run the bundled copy of `install.sh` (shipped at `Contents/Resources/scripts/install.sh`) detached in its own session (`/bin/bash` with an argv list; `--app <staged> --quit-with app`), so it survives the app quitting. It already does the graceful quit, the swap, `NeedsYou.app.previous`, the background relaunch and the auto-rollback. One addition: `--rollback` records the version it rolled back from (in the Updates directory) so the updater skips it.

**After the update.** The relaunched app posts a local `info` item through its own hub: "Updated to X.Y.Z. If macOS asks about incoming connections, choose Allow, or other machines can't reach this Mac's hub". It also shows the sender roll-out status (below). If `/Applications` isn't writable, the item says "Update X.Y.Z is ready" with the command to run.

**Never** activates the app or takes focus (hard rule 2). The relaunch uses `open -g`.

## Sender update design

- **`/dl/manifest.json` (hub, no token, like `/dl`).** `{"version": "<hub VERSION>", "files": {"needs-you": {"sha256", "size"}, "needs-you-hook.sh": {...}, ..., "orca-snippet.md": {...}}}`, computed when the hub starts and cached. `orca-snippet.md` moves out of the `join-install.sh` heredoc into `integrations/orca/snippet.md` and onto `/dl` (one source; `tests/test_orca.py` already checks README ↔ installer and would check README ↔ file).
- **`needs-you update [--auto] [--check]`.** Fetch the manifest from the first healthy hub. For each installed piece whose local sha256 differs: download it, verify, then install atomically: the CLI (as `self-update` does today), `~/.claude/hooks/needs-you-hook.sh`, the hook entries (run the fetched `install-hooks.sh`, which merges idempotently), the skill if `~/.claude/skills/needs-you/` exists, the Orca snippet if `orca-snippet.md` exists. Nothing new gets installed that wasn't there. `--check` reports without changing anything. `self-update` stays as an alias for one release. Never downgrades: skip if the hub's version is older than the local CLI's.
- **Automatic.** `needs-you flush` (already every 5 minutes on every sender) runs `update --auto` at most once per 24 h plus a per-host random offset, only when a hub answers, never when `NEEDS_YOU_AUTO_UPDATE=0`. It's quiet, never fails the flush, and exits 0 (hard rule 8).
- **Reporting.** Every CLI request sends `X-Needs-You-Client: cli=<v>; hook=<v|none>; skill=<v|none>; orca=<v|none>` (versions come from a `# needs-you <v>` line added to each file). The hub keeps, **per token, on this hub only** (not replicated: it would be a write per post), `client` and `last_seen_at`, in a new `token_clients` table. `GET /v1/tokens` adds `client` and `last_seen_at`. `needs-you doctor` adds an `update` check: local versions, the hub's, and the hint.
- **Mac UI.** Settings → Access lists tokens with their versions and last seen; a line in the menu and Settings says "2 of 5 machines out of date" (sender tokens seen in the last 14 days whose `cli` < the app's version). No card: it isn't something the owner has to act on today. A machine that's 7+ days behind gets one `low` item.

## Server hubs

A server hub's `/dl` serves its own checkout or tarball, so it lags until it's updated, and its senders lag with it. Add `scripts/update-hub.sh` (run by a systemd timer, opt-in at `install-hub.sh` time): read the latest published release the same way (a PAT in `/etc/needs-you/github.token` while private), apply the same gate and soak, verify the tarball against `SHA256SUMS`, unpack to `/opt/needs-you/src-<v>`, flip a `current` symlink, restart the unit, and roll the symlink back if `/v1/health` doesn't answer within 30 s. This is the hub's half of the same chain.

## Build list

Ordered: each part works on its own, and the earlier parts make the later ones useful.

### Release (CI)

1. **`release-manifest.json` asset.** `scripts/build-release.sh` writes it (version, commit, `GITHUB_RUN_ID`, each asset's sha256 and size, `min_macos` from `mac/Package.swift`); `release.yml` uploads it with the rest; it goes in `SHA256SUMS` too. Tests: `tests/test_release.py` (the manifest matches `SHA256SUMS`, version matches `VERSION`).
2. **Ship `install.sh` in the bundle.** `mac/scripts/bundle.sh` copies `mac/scripts/install.sh` to `Contents/Resources/scripts/`; `install.sh` gains `--record-rollback DIR` (writes the version it left). Tests: `mac/scripts/upgrade-test.sh` covers the bundled copy.

### Mac

3. **`Updater` in NeedsYouCore (pure, tested).** `mac/Sources/NeedsYouCore/Updater.swift`: `SemVer` parse and compare; `ReleaseInfo` and `ReleaseManifest` decoding from fixture JSON (GitHub's release and runs shapes); `UpdateDecision.evaluate(release:manifest:run:current:now:soak:skipped:) -> .none | .wait(until) | .download(asset)`; `SHA256SUMS` line parse; checksum verify over a file (CryptoKit, a system framework); `InstallWindow.canInstall(panelExpanded:hovering:lastArrival:idleSeconds:now:)`. Tests: `mac/Tests/NeedsYouCoreTests/UpdaterTests.swift` (registered in `NeedsYouSelfTest/main.swift`, symlinked).
4. **`UpdateSource` auth chain** (Core + app). Core: choose anonymous / `gh` / PAT file; fixed `gh` paths; never log the token. App: run `gh auth token` with `Process` (argv, 5 s timeout), keep the result in memory. Tests for the choice logic in Core.
5. **`UpdateController` in the app.** `mac/Sources/NeedsYou/UpdateController.swift`: schedule (launch + 2 min, every 6 h), fetch, decide, download, stage, verify bundle id, version and `codesign --verify`, then install through the bundled `install.sh` when `InstallWindow` allows or on click. Settings → Updates: on/off, soak, auth status ("using gh", "PAT", "public"), Check now, Restart to update, Skip this version. Post-update `info` item through the local hub. Nothing activates the app except the Settings window itself; `FloatingPanelTests` unchanged and passing.

### Hub (API)

6. **`/dl/manifest.json` and the Orca snippet file.** `hub/needs_you_hub.py`: compute and cache the sha256 and size of each `DOWNLOADS` entry; add `orca-snippet.md` (from `integrations/orca/snippet.md`). `hub/join-install.sh` fetches the snippet instead of carrying a heredoc. `mac/scripts/bundle.sh` bundles the snippet. Docs: `docs/API.md` (`/dl` table, manifest shape). Tests: `tests/test_api.py` (manifest matches files; 404 for unknown), `tests/test_orca.py` (README ↔ snippet file), `tests/test_install.py`.
7. **Client version tracking.** Hub: parse `X-Needs-You-Client` (a strict `name=version` list, ≤ 200 chars; unknown names ignored), store in `token_clients(token_id, client, last_seen_at)` on authenticated sender calls, throttled to one write per token per 10 minutes; `GET /v1/tokens` gains `client` (object) and `last_seen_at`. Not replicated, so each hub reports what it saw, and the Mac merges by token id across hubs (newest `last_seen_at` wins). Docs: `docs/API.md`. Tests: `tests/test_api.py`. Mac: `Models.swift` and `HubClient.swift` decode the new optional fields (unknown fields stay ignored).

### CLI and integrations (sender-side)

8. **Version stamps.** A `# needs-you <v>` line in `needs-you-hook.sh`, `SKILL.md` (as an HTML comment), the Orca snippet and `hooks.json` (a `"_needs_you_version"` key, which Claude Code ignores); `scripts/build-release.sh` and `tests/test_release.py` check they all match `VERSION`.
9. **`needs-you update`.** `cli/needs-you`: manifest fetch, per-file verify and atomic install, `--check`, `--auto`, no downgrade; `self-update` becomes an alias. `doctor` gains an `update` check. Tests: `tests/test_cli.py` with a fake hub serving a manifest (good, bad checksum, older version), `tests/test_doctor.py`.
10. **Auto-update from flush.** `flush` calls `update --auto` once per 24 h (state file `~/.local/state/needs-you/last-update`, random per-host offset), honours `NEEDS_YOU_AUTO_UPDATE=0`, never changes flush's exit code. Tests: `tests/test_cli.py`.
11. **Client header.** The CLI sends `X-Needs-You-Client` on every request. Tests: `tests/test_cli.py` (header shape), `tests/test_api.py` end to end.
12. **Orca pointer block.** `integrations/orca/README.md` and the snippet: the pasted block becomes "read `~/.config/needs-you/orca-snippet.md` and follow it", with the full text living in the file. Tests: `tests/test_orca.py`.
13. **Mac Settings: "machines out of date".** Settings → Access shows each sender's versions and last seen; a summary line in Settings and the menu; one `low` item for a machine 7+ days behind. Pure counting in Core (`RolloutStatus`, tested).

### Fallback and server hubs

14. **`scripts/rollout.sh`.** `rollout.sh [--hosts FILE] [--check] [host...]`: hosts from `~/.config/needs-you/hosts` (one SSH alias per line, for example `devbox`), else the arguments; never parses `~/.ssh/config` wildcards. Per host, over `ssh -o BatchMode=yes -o ConnectTimeout=10`: `needs-you update` (or `--check`), then `needs-you doctor --json`; prints a table (host, cli, hook, skill, doctor ok). If the CLI is missing, it says to use an invite link (it doesn't copy tokens). Tests: `tests/test_rollout.py` with a fake `ssh` on `PATH`; `shellcheck` already runs on every `*.sh`.
15. **`scripts/update-hub.sh` + systemd timer** for server hubs (gate, soak, checksum, symlink flip, health check, rollback). `deploy/needs-you-hub-update.{service,timer}`; `install-hub.sh --auto-update`. Docs: `docs/HUB.md`. Tests: `tests/test_install.py`-style with a fake release directory.

## Open decisions

1. Update checks on the Mac: off by default, or on with disclosure? (`distribution.md` open decision 2.) Recommended: on, since the only request goes to GitHub and carries nothing about items.
2. Soak length: 2 h (recommended), 24 h, or none.
3. Should publishing stay manual? The gate works either way; auto-publishing after tests would make "ships" mean "tests passed", with the soak as the only brake.
4. Sender auto-update default: on (recommended: they already trust their hub) or opt-in.
5. Sparkle, once public with a Developer ID: switch (ADR), or keep the built-in updater?
