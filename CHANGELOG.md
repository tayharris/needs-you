# Changelog

All notable user-visible changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver (see `docs/roadmap/ci-cd.md`). The release workflow uses the `## [X.Y.Z]` section as the release notes, so write it for someone installing the release.

## [Unreleased]

### Added

- **Item steps:** senders can give the person a checklist, `"steps": [{"text", "link"?, "done"?}]` (at most 10, one line of 200 characters each, inline markdown; links use the same scheme allow-list). The Mac app shows them as a numbered checklist at the card text size with each step's link as a button; ticks stay on that Mac, and the card offers **Done** once every step is ticked. "First lines" and "Title only" show "3 steps" until the card is expanded. CLI: `--step "Text"`, `--step "Text=https://..."` (repeatable) and `--steps-json`. Steps are part of the item's content (a change re-animates the card) and replicate between hubs. The hub's database moves to schema 3 (one new column, backed up first); an older hub refuses the upgraded file, so upgrade every hub together or keep the backup.
- Mac app: **Focus** and delivery tiers. Every arrival is **Interrupt** (the spring-out preview, as before), **Ambient** (the count and one soft glow) or **Later** (held out of the count in a Later section, then delivered as one quiet peek, "3 waited while you were focused", when the focus or snooze ends or the work day starts). Right-click the pill or use the menu bar → **Focus**: Agents and urgent only (`agent:` cards and urgent interrupt), Urgent only, Everything later, for 30 min / 1 hr / 2 hr / until tomorrow; a moon on the pill shows it. **Settings → Alerts** adds the tier for normal, low, done/info and other-context items, **Urgent items break through Focus** (on), a table of what each focus does, and **Bypass rules** (key prefix, agent prefix or host → always interrupt / never interrupt / always later; first match wins, at most 50). A sender interrupting more than 6 times an hour is held to ambient for the rest of it. Changed defaults: low items and done/info now arrive ambient (one soft glow instead of the spring-out), and normal items that arrive during a snooze wait under Later instead of joining the count straight away.
- Mac app: `needsyou://focus?level=off|agents|urgent|later[&minutes=N|&until=tomorrow]` for Shortcuts automations and scripts (`open -g`). It asks first unless **Settings → Alerts → Allow focus links from other apps** is on (off by default), lasts at most 12 h (or until tomorrow), never holds back urgent items, and shows a link badge on the pill. See the [Mac guide](docs/guides/mac-app.md#drive-it-from-shortcuts-or-a-script).
- Mac app: new items spring out on **the display you're working on** (the frontmost app's window, else the pointer; Settings → Alerts → On the work screen, on by default), then the pill goes home. Optional **Edge glow** for urgent arrivals (off by default): a click-through glow around that display's edge. Neither needs a permission or takes focus.
- Mac app: make the panel yours. **Settings → Panel**: size (compact, regular, large) for the pill, the cards' type and the open panel; a separate card text size (small to extra large) for long agent instructions; card text in full, the first 3 lines or title only; compact links; how many cards show before the list scrolls; opacity. A sample card shows each change. The defaults are the original look.
- Mac app: **Settings → Alerts** sets how loud new items are (off, subtle, normal, bright), separately for urgent and for other items. Urgent never goes below subtle. The preview pills play each style.
- Mac app: record your own global shortcut in **Settings → Panel → Keyboard** (it must use ⌃, ⌥ or ⌘; system shortcuts are refused, and a shortcut another app holds keeps the old one). Settings shows whether it registered. New, off by default: **Hotkey also opens the top card's first link** (Settings → Integrations), which runs the top card's Terminal jump or opens its VS Code window instead of showing or hiding the panel.
- Mac app: cards waiting 4 hours or more show their age next to the title (`5 h`, `2 d`, amber after 2 days), and a card's **…** menu has **Dismiss All from <host>** for a machine that went away without resolving its cards.

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
- Security (audit 2026-10-07, [details](docs/security/audit-2026-10-07.md)): the hub's access log no longer shows invite codes (it also reached the macOS log through the app's local hub); a request with a negative `Content-Length` can't make the hub read without limit; idle connections time out after 60 s; timestamps outside 1970–9999 are refused (a far-future `expires_at` used to break every listing); bidi override characters and invisible characters in URLs are refused; replicated items keep only allowed links. The Mac app asks before joining a hub from a `needsyou://connect` link opened outside the app, a new hub can't replace the tokens of hubs you already have, and card text drops bidi overrides. The invite installer refuses a hub answer or `--hub` URL with shell syntax before writing the env file. The CLI escapes control characters in what hubs send before printing it.
- Agent cards from a killed Claude session (closed terminal, reboot, OOM) no longer stay forever. The hook leases each card to its Claude process, and `needs-you flush` (every 5 minutes) resolves the card once that process is gone. Cards also expire 48 hours after their last post (`NEEDS_YOU_AGENT_EXPIRY_HOURS`, `0` turns it off).

### Changed

- Mac app: Settings is in tabs (Hubs and access, Panel, Alerts, Integrations, Advanced), with a one-line explanation for each setting.
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
