# Changelog

All notable user-visible changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver (see `docs/roadmap/ci-cd.md`). The release workflow uses the `## [X.Y.Z]` section as the release notes, so write it for someone installing the release.

## [Unreleased]

### Added

- Mac app: **Settings → Access** lists and revokes invites and machine tokens. The hub has owner `GET /v1/tokens`, `DELETE /v1/tokens/<id>` and `DELETE /v1/invites/<id>`.
- Mac app: a menu bar icon; the panel can be hidden and moved.
- Mac app: when nothing is waiting, the pill shows a faint "Nothing needs <you>" instead of a sliver.
- Orca: the automation prompt block (`--orca`) posts with stable keys and Jira, PR and branch links, names the worktree and the `orca terminal switch` command, and resolves the same key once it's handled. Agent cards from Orca terminals carry the same command; `NEEDS_YOU_ORCA_ENVIRONMENT` adds `--environment` for paired Orca servers.
- `mac/scripts/install.sh` updates the installed app in place, with `--rollback`.

### Changed

- The Mac app keeps tokens in `~/Library/Application Support/NeedsYou/tokens.json` (mode 600) instead of the Keychain.
- An invite redeemed on the hub's own machine gets `http://127.0.0.1:<port>` first, so local agents don't depend on Tailscale.
- Used-up invite links still serve their installer until they expire, so re-runs and `--uninstall` work.

### Fixed

- The installer's `--help` prints when piped from `curl`.
- A dead invite link's installer fails with exit 1 instead of running an empty script.
- Docs no longer point at `orca://terminal/...` or `orca://worktree/...` links, which Orca doesn't have.
