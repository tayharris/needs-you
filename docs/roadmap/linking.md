# Linking: take the person exactly where they act

Status (2026-10-08): build steps 1–9 are built and shipped (0.1.2): automatic editor links from the hook, `--ssh-alias`, `linear` on the allow-list, the `needsyou://terminal/focus` action with WezTerm, tmux, iTerm2, Terminal and Ghostty, and the link conventions in the sender contract. What's left is plan: `claude-cli` links, two spikes, and selecting a remote tmux pane over SSH.

How it works for users: [Claude Code everywhere → buttons and the Terminal button](../guides/claude-code-everywhere.md#terminal-button), [Mac app → Terminal button](../guides/mac-app.md#terminal-button), and the link table in [AGENT-GUIDE.md](../AGENT-GUIDE.md) rule 4 (which link to put first for a PR, a check run, a Slack message, a Jira ticket). The wire rules are in [API.md](../API.md#post-v1items-sender).

As built, differences from the plan: the terminal link's parameters are per app (`app=wezterm&pane=<n>`, `app=tmux&pane=<n>[&host=<terminal>]` or `target=<s>:<w>.<p>`, `app=iterm&session=<UUID>` or `tty=`, `app=terminal&tty=`, `app=ghostty`) rather than `id=`/`tmux=`; the AppleScript lives in `TerminalJumpScript.swift` (one script per app, compiled only when that app is installed); with the opt-in off, iTerm2 and Terminal cards bring the app forward; Ghostty only comes forward. The `github-actions.yml` `?pr=` job link from step 9 wasn't done.

## Security model

Agents write these links, and a sender only holds a token. Three classes, and nothing outside them:

1. **External links (scheme allow-list).** Opened with `NSWorkspace.open`; the target app's own handler decides what happens. A scheme gets on the list only if its handler can't run code or send data without a further human step. `https`, `vscode`, `cursor`, `slack`, `linear` qualify. `claude-cli` qualifies on paper (the prompt is inert and labelled), but it puts attacker-chosen text one Enter key away from an agent with tool access, so it's opt-in (below). Never: `http`, `file`, `ssh`, `x-man-page`, `javascript`, `jira`, or any handler that takes a command line. The hub (`validate_links`) and `LinkPolicy.swift` change together (hard rule 7).
2. **App actions (`needsyou://<host>/<path>`).** A fixed, small set. Each is parsed in `NeedsYouCore` into a typed value whose fields pass a strict pattern (like `OrcaJump`); anything else does nothing. Each runs a fixed binary from a fixed path list (never `PATH`) with an argv list and a timeout, or an AppleScript **handler called with parameters** (`NSAppleEventDescriptor`, never string-built source). The hub keeps a path allow-list for `needsyou://` (`APP_LINK_PATHS`: `orca/terminal` and `terminal/focus`) mirrored in Core (`LinkPolicy.appActionPaths`). Worst case per action is written down: "a sender can switch which tab is shown".
3. **Never:** run a command, a script or a URL built from item text; copy free text to the clipboard as a command (pastejacking). A "copy command" fallback copies only a command the app built itself from validated fields.

AppleScript-driven jumps need a one-time Automation prompt per target app. The prompt is requested from a **Settings** click (which may activate the app), never from the panel, and the feature is off until then. The panel stays non-activating; the target terminal activating itself is that app's business (same as the Orca jump). The bundle needs `NSAppleEventsUsageDescription` in `Info.plist` for the prompt to appear at all; an ad-hoc signed app without the hardened runtime needs no Apple Events entitlement.

## Still plan

### Claude Code sessions

| Link | What it does | Use |
|---|---|---|
| `claude-cli://open?cwd=<abs>&q=<prompt>` or `?repo=owner/name&q=` | Opens a **new** Claude Code session in a new terminal window with the prompt typed but not sent; shows "Prompt from an external link". Registered on the first interactive prompt; needs Claude Code 2.1.91+ ([deep links](https://code.claude.com/docs/en/deep-links)) | "CI failed on main: open Claude in that repo with 'investigate job X' pre-filled". Runs on the Mac, so `repo=` (resolved to the Mac's clone) is the portable form. |
| `claude --resume <session-id>` | Resumes a session in the current terminal | No URL form: `claude-cli://` has no session parameter yet ([proposed upstream](https://claudeissues.com/issue/60618-claude-cli-url-scheme-add-session-id-param-to-jump-to-a-specific-session)). Useful only for a session that ended; a live one is better served by focusing its terminal. |
| `vscode://anthropic.claude-code/open?session=<id>` | Focuses or resumes that conversation in VS Code | See Editors |

### Remote terminals

**Remote sessions (SSH to devbox, often inside tmux).** The hook runs on devbox and can't see which Mac tab holds the SSH connection. Two practical facts help:

1. macOS's default `ssh_config` has `SendEnv LANG LC_*`, and Debian/Ubuntu's default `sshd_config` has `AcceptEnv LANG LC_*`. So a variable named `LC_*` set in the Mac shell crosses SSH with no server change. A one-line shell rc addition on the Mac, `export LC_NEEDS_YOU_TERM="iterm2:${ITERM_SESSION_ID#*:}"` (or `wezterm:$WEZTERM_PANE`, `tty:$(tty)`), lets the remote hook name the Mac-side tab. Caveat: a tmux pane keeps the value from when the tmux server or pane started; re-attaching from another tab leaves it stale. tmux's `update-environment` refreshes it for new panes only. The jump then just fails safe (nothing found, so the command is copied instead).
2. The remote tmux pane can be selected from the Mac with `ssh <alias> tmux select-window -t %<pane>`. That runs a (fixed) command on the remote host, so it's a later, opt-in phase with a Mac-side list of SSH aliases the app may use.

The first is built (`LC_NEEDS_YOU_TERM`). The second, selecting the remote tmux pane from the Mac, isn't.

### Build list

1. **`claude-cli` opt-in** (API + Mac). Hub and `LinkPolicy` accept `claude-cli://open` only (no other host), with `q` ≤ 1,000 chars; the app opens it only when Settings → "Open Claude Code links" is on, otherwise shows it as text. Tests on both sides. Docs: API, AGENT-GUIDE.
2. **Spikes, written up before building:** Ghostty terminal ids (is there an env var; does `focus` exist in its sdef); VS Code `tunnel+` form; whether `vscode://anthropic.claude-code/open?session=` works for a Remote-SSH window.

## Open decisions

1. `claude-cli` on the allow-list at all, or only through the opt-in? (Recommended: opt-in.)
2. Remote tmux selection over SSH (phase 3): worth a Mac-side SSH alias list, or is "focus the Mac tab" enough?

Decided while building: the hook adds editor links by default on the Mac, and on a remote host only with `--ssh-alias`.
