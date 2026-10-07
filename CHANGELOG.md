# Changelog

All notable user-visible changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver (see `docs/roadmap/ci-cd.md`). The release workflow uses the `## [X.Y.Z]` section as the release notes, so write it for someone installing the release.

## [Unreleased]

### Added

- Mac app: Orca cards have a **Terminal** button that runs `orca terminal switch` for that agent's terminal and brings Orca forward (a card that doesn't name its Orca environment tries each paired one). Clicking it marks the card done. If the switch fails, the command goes on the clipboard. The hook and the Orca prompt block add the link (`needsyou://orca/terminal?handle=…`); the hub accepts the app's own scheme for that path only, and the app validates the handle and environment and runs nothing else.

- Agent cards say where the session runs: the tmux pane (`kube:2.1`), VS Code, or SSH.
- One line from zero to Claude Code alerts on a machine: `curl -fsSL <join_url>/install.sh | bash -s -- --yes --claude-hooks user --skill --alerts`. New installer flags: `--alerts` (writes `NEEDS_YOU_AGENT_ALERTS=1`), `--context-alert PCT`, `--ssh-alias NAME`, `--agent-link 'LABEL=URL'`, `--orca-environment NAME`, and `--no-path`. The installer now puts `~/.local/bin` on `PATH` with one tagged line in your shell profile (removed again by `--uninstall`). Re-runs keep every setting you don't pass again.
- `scripts/setup-sender.sh` schedules the 5-minute `needs-you flush` like the installer (`--no-schedule`), sets up `PATH` (`--no-path`) and takes the same Claude Code setting flags.
- Claude Code hook: specific cards for permission requests ("Approve Claude's plan", "Claude asked you a question", "Claude wants to run git", "Claude wants to edit config.yml"; never the command or content), for turns that ended on an API error (`StopFailure`: rate limit, sign-in, billing, ...), and for a usage limit that won't auto-resume. Re-run the installer (or `install-hooks.sh`) to register the new events.
- Claude Code hook: a low-priority card suggests `/compact` or `/clear` when a session's context is 80% full (`NEEDS_YOU_CONTEXT_ALERT_PCT`, `0` = off; `NEEDS_YOU_CONTEXT_WINDOW`, 1M models detected). It clears itself after `/compact`, `/clear` or the end of the session.
- Claude Code hook: cards get editor buttons without configuration: the folder in VS Code on the Mac, a VS Code Remote-SSH window with `NEEDS_YOU_SSH_ALIAS`, and the conversation's tab for sessions in the VS Code extension. `NEEDS_YOU_AGENT_LINK` still replaces them (`none` turns them off).
- `needs-you doctor` shows the context alert, SSH alias and agent link settings.
- Docs: a get-started section at the top of the README (download, first launch, invite a machine), and two guides: [Claude Code alerts everywhere](docs/guides/claude-code-everywhere.md) (one copy-paste setup; SSH, tmux, VS Code Remote-SSH, Orca) and [Tailscale](docs/guides/tailscale.md).

### Fixed

- The installer's `--uninstall` (and a re-install) no longer stops halfway on a crontab that holds only the needs-you flush line.
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
