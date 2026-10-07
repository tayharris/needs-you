# Changelog

All notable user-visible changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver (see `docs/roadmap/ci-cd.md`). The release workflow uses the `## [X.Y.Z]` section as the release notes, so write it for someone installing the release.

## [Unreleased]

### Added

- Mac app: Orca cards have a **Terminal** button that runs `orca terminal switch` for that agent's terminal and brings Orca forward (a card that doesn't name its Orca environment tries each paired one). Clicking it marks the card done. If the switch fails, the command goes on the clipboard. The hook and the Orca prompt block add the link (`needsyou://orca/terminal?handle=…`); the hub accepts the app's own scheme for that path only, and the app validates the handle and environment and runs nothing else.

- Agent cards say where the session runs: the tmux pane (`kube:2.1`), VS Code, or SSH.
- Docs: a get-started section at the top of the README (download, first launch, invite a machine), and two guides: [Claude Code alerts everywhere](docs/guides/claude-code-everywhere.md) (one copy-paste setup; SSH, tmux, VS Code Remote-SSH, Orca) and [Tailscale](docs/guides/tailscale.md).

### Fixed

- Security (audit 2026-10-07, [details](docs/security/audit-2026-10-07.md)): the hub's access log no longer shows invite codes (it also reached the macOS log through the app's local hub); a request with a negative `Content-Length` can't make the hub read without limit; idle connections time out after 60 s; timestamps outside 1970–9999 are refused (a far-future `expires_at` used to break every listing); bidi override characters and invisible characters in URLs are refused; replicated items keep only allowed links. The Mac app asks before joining a hub from a `needsyou://connect` link opened outside the app, a new hub can't replace the tokens of hubs you already have, and card text drops bidi overrides. The invite installer refuses a hub answer or `--hub` URL with shell syntax before writing the env file. The CLI escapes control characters in what hubs send before printing it.
- Agent cards from a killed Claude session (closed terminal, reboot, OOM) no longer stay forever. The hook leases each card to its Claude process, and `needs-you flush` (every 5 minutes) resolves the card once that process is gone. Cards also expire 48 hours after their last post (`NEEDS_YOU_AGENT_EXPIRY_HOURS`, `0` turns it off).

### Changed

- Releases include `NeedsYou-X.Y.Z.dmg` (open it, drag the app onto Applications) next to the zip, and in `SHA256SUMS`. The release workflow has a manual dry run that builds everything without creating a release.
- needs-you is licensed under Apache-2.0 (`LICENSE`).
- The Orca prompt block, the skill and the agent guide tell scheduled senders to post with `--expires-in` of about twice their interval, so a blocker a run stops reporting drops off even if its resolve is missed.

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
