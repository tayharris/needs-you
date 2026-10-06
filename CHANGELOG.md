# Changelog

All notable user-visible changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver (see `docs/roadmap/ci-cd.md`). The release workflow uses the `## [X.Y.Z]` section as the release notes, so write it for someone installing the release.

## [Unreleased]

## [0.1.1] - 2026-10-06

The first packaged release: a private preview for invited testers.

### Added

- CLI: `needs-you doctor` checks this machine's setup (env file and its mode, PATH, each hub's version and the token's role, the outbox, Claude Code hooks and skill, Orca settings, the flush schedule) and prints a fix for each problem. `--json` is for agents. Read-only; it never posts and never prints the token.
- Mac app: **Settings → Access** lists and revokes invites and machine tokens. The hub has owner `GET /v1/tokens`, `DELETE /v1/tokens/<id>` and `DELETE /v1/invites/<id>`.
- Mac app: a menu bar icon; the panel can be hidden and moved.
- Mac app: when nothing is waiting, the pill shows a faint "Nothing needs <you>" instead of a sliver.
- Orca: the automation prompt block (`--orca`) posts with stable keys and Jira, PR and branch links, names the worktree and the `orca terminal switch` command, and resolves the same key once it's handled. Agent cards from Orca terminals carry the same command; `NEEDS_YOU_ORCA_ENVIRONMENT` adds `--environment` for paired Orca servers.
- `mac/scripts/install.sh` updates the installed app in place, with `--rollback`.
- Releases: a downloadable Mac app zip (ad-hoc signed), the server tarball, the CLI and `SHA256SUMS` on GitHub Releases.
- Agent cards from Orca terminals don't repeat the worktree path when it's the working directory.

### Changed

- The Mac app keeps tokens in `~/Library/Application Support/NeedsYou/tokens.json` (mode 600) instead of the Keychain.
- An invite redeemed on the hub's own machine gets `http://127.0.0.1:<port>` first, so local agents don't depend on Tailscale.
- Used-up invite links still serve their installer until they expire, so re-runs and `--uninstall` work.

### Fixed

- The installer's `--help` prints when piped from `curl`.
- A dead invite link's installer fails with exit 1 instead of running an empty script.
- Docs no longer point at `orca://terminal/...` or `orca://worktree/...` links, which Orca doesn't have.
