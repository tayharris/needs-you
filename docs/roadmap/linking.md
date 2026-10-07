# Linking: take the person exactly where they act

Status: build list steps 1–9 built (2026-10-07); `claude-cli` links (step 10) and the spikes (step 11) are still plan. As built: the terminal link's parameters are per app (`app=wezterm&pane=<n>`, `app=tmux&pane=<n>[&host=<terminal>]` or `target=<s>:<w>.<p>`, `app=iterm&session=<UUID>` or `tty=`, `app=terminal&tty=`, `app=ghostty`) rather than `id=`/`tmux=`; the AppleScript lives in `TerminalJumpScript.swift` (one script per app, compiled only when that app is installed) instead of a bundled `.applescript`; with the opt-in off, iTerm2 and Terminal cards bring the app forward (there's no CLI command to copy); Ghostty only comes forward. See [docs/API.md](../API.md#post-v1items-sender), [the Mac guide](../guides/mac-app.md#terminal-button) and [Claude Code everywhere](../guides/claude-code-everywhere.md#terminal-button).

A card is only as good as its click. Before this plan, a card can carry up to 6 links with an allowed scheme (`https`, `orca`, `slack`, `vscode`, `cursor`, `figma`, `msteams`, `discord`), plus one app action, the Orca **Terminal** jump (`needsyou://orca/terminal?...`, `OrcaJump.swift`). The Claude Code hook adds a link only when `NEEDS_YOU_AGENT_LINK` is set by hand. This plan covers what each place a person acts in offers, which of those need an allow-list change, which need a new `needsyou://` action, and the security model that keeps "a sender holds a token" from turning into "a sender runs code on the Mac".

## Findings

### Editors

| Target | Link | Notes |
|---|---|---|
| VS Code, local folder or file | `vscode://file/<abs path>[:line[:col]]` | Documented form; a trailing `/` opens a folder ([VS Code CLI docs](https://code.visualstudio.com/docs/configure/command-line)). Only useful when the path exists **on the Mac**, so only for senders running on the Mac itself. |
| VS Code, Remote-SSH folder | `vscode://vscode-remote/ssh-remote+<ssh-alias><abs path>[?windowId=_blank]` | Opens folders only, not files ([exe.dev FAQ](https://exe.dev/docs/faq/vscode), [Remote-SSH docs](https://code.visualstudio.com/docs/remote/ssh)). `<ssh-alias>` must be the name the **Mac's** `~/.ssh/config` uses (for example `devbox`), which the sender doesn't know on its own. Already suggested in [launch-prep.md](launch-prep.md) as a hand-set `NEEDS_YOU_AGENT_LINK`. |
| VS Code, Remote Tunnel | `vscode://vscode-remote/tunnel+<tunnel-name><abs path>` | Same handler as Remote-SSH; to verify by hand before relying on it. |
| VS Code, the Claude Code tab | `vscode://anthropic.claude-code/open?session=<id>` | The extension's handler. `session` resumes that conversation; **if it's already open in a tab, that tab is focused**. The session must belong to the workspace open in the focused window ([Claude Code in VS Code](https://code.claude.com/docs/en/vs-code#launch-a-vs-code-tab-from-other-tools)). Uses the `vscode` scheme, so it's already allowed. |
| Cursor | `cursor://file/...`, `cursor://vscode-remote/ssh-remote+...` | Cursor is a VS Code fork with the same handler shapes. Already allowed. |

### Terminals on the Mac

None of these has a URL scheme that focuses an existing tab, so each needs an app action.

| Terminal | How to focus one session | Identity the hook can record | Permission |
|---|---|---|---|
| iTerm2 | AppleScript: sessions have `unique id`; `select` works on a session, a tab and a window ([iTerm2 AppleScript](https://iterm2.com/applescript.html)). AppleScript is marked deprecated (bug fixes only; the Python API is preferred), but still works. | `ITERM_SESSION_ID` = `w0t1p0:<UUID>`; the UUID is the `unique id` | Automation (TCC) prompt: NeedsYou → iTerm2 |
| Terminal.app | AppleScript: find the tab whose `tty` is `/dev/ttysNNN`, `set selected of tab to true`, raise its window | `ps -o tty= -p <claude pid>` | Automation prompt: NeedsYou → Terminal |
| Ghostty 1.3+ | AppleScript dictionary (windows → tabs → terminals, each with an `id`; `focused terminal`; filter by `working directory`) ([Ghostty AppleScript](https://ghostty.org/docs/features/applescript)) | No documented env var for the terminal id; match on tty or working directory. Spike needed | Automation prompt; users can disable it with `macos-applescript = false` |
| WezTerm | `wezterm cli activate-pane --pane-id <n>` ([docs](https://wezterm.org/cli/cli/activate-pane.html)), then bring WezTerm forward | `WEZTERM_PANE` | None (a CLI, no AppleScript) |
| tmux on the Mac | `tmux select-window -t %<pane>` and `select-pane -t %<pane>` (targets can be pane ids) | `TMUX_PANE` (`%12`); the hook already records `session:window.pane` | None; then focus the terminal that hosts tmux |
| Orca | `orca terminal switch --terminal <handle> [--environment <name>]` | `ORCA_TERMINAL_HANDLE` | None. **Built** (`OrcaJump`) |

**Remote sessions (SSH to devbox, often inside tmux).** The hook runs on devbox and can't see which Mac tab holds the SSH connection. Two practical facts help:

1. macOS's default `ssh_config` has `SendEnv LANG LC_*`, and Debian/Ubuntu's default `sshd_config` has `AcceptEnv LANG LC_*`. So a variable named `LC_*` set in the Mac shell crosses SSH with no server change. A one-line shell rc addition on the Mac, `export LC_NEEDS_YOU_TERM="iterm2:${ITERM_SESSION_ID#*:}"` (or `wezterm:$WEZTERM_PANE`, `tty:$(tty)`), lets the remote hook name the Mac-side tab. Caveat: a tmux pane keeps the value from when the tmux server or pane started; re-attaching from another tab leaves it stale. tmux's `update-environment` refreshes it for new panes only. The jump then just fails safe (nothing found, so the command is copied instead).
2. The remote tmux pane can be selected from the Mac with `ssh <alias> tmux select-window -t %<pane>`. That runs a (fixed) command on the remote host, so it's a later, opt-in phase with a Mac-side list of SSH aliases the app may use.

### Claude Code sessions

| Link | What it does | Use |
|---|---|---|
| `claude-cli://open?cwd=<abs>&q=<prompt>` or `?repo=owner/name&q=` | Opens a **new** Claude Code session in a new terminal window with the prompt typed but not sent; shows "Prompt from an external link". Registered on the first interactive prompt; needs Claude Code 2.1.91+ ([deep links](https://code.claude.com/docs/en/deep-links)) | "CI failed on main: open Claude in that repo with 'investigate job X' pre-filled". Runs on the Mac, so `repo=` (resolved to the Mac's clone) is the portable form. |
| `claude --resume <session-id>` | Resumes a session in the current terminal | No URL form: `claude-cli://` has no session parameter yet ([proposed upstream](https://claudeissues.com/issue/60618-claude-cli-url-scheme-add-session-id-param-to-jump-to-a-specific-session)). Useful only for a session that ended; a live one is better served by focusing its terminal. |
| `vscode://anthropic.claude-code/open?session=<id>` | Focuses or resumes that conversation in VS Code | See Editors |

### Work tools (https is already the right answer)

| Tool | Deepest stable link | Notes |
|---|---|---|
| GitHub PR review | `https://github.com/<o>/<r>/pull/<n>/files` | The review UI. Conflicts: `/pull/<n>/conflicts` |
| GitHub check run / job | `https://github.com/<o>/<r>/runs/<check_run_id>` (the check run's `html_url`) or `/actions/runs/<run>/job/<job>?pr=<n>` | In Actions, `${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}` is the run; the job id needs the API |
| GitHub deployment approval | `https://github.com/<o>/<r>/actions/runs/<run>` | The "Review deployments" button lives on the run page |
| Jira | `https://<site>.atlassian.net/browse/<KEY>[?focusedCommentId=<id>]` | No desktop scheme worth allowing |
| Slack | Message: `https://<ws>.slack.com/archives/<C…>/p<ts>` (permalink; `chat.getPermalink`). Channel or DM: `slack://channel?team=<T…>&id=<C…>`, `slack://user?team=&id=` ([Slack deep linking](https://docs.slack.dev/interactivity/deep-linking)) | There is no `slack://` form for one message or thread; use the https permalink, which the desktop app picks up |
| Linear | `https://linear.app/<ws>/issue/<ID>`; desktop `linear://<ws>/issue/<ID>` | Linear's "Open in desktop app" preference redirects https links, so `linear` in the allow-list is a nicety |
| Orca | `needsyou://orca/terminal?...` (built) | Orca 1.4.220 has no worktree or terminal deep link |

## Security model

Agents write these links, and a sender only holds a token. Three classes, and nothing outside them:

1. **External links (scheme allow-list).** Opened with `NSWorkspace.open`; the target app's own handler decides what happens. A scheme gets on the list only if its handler can't run code or send data without a further human step. `https`, `vscode`, `cursor`, `slack`, `linear` qualify. `claude-cli` qualifies on paper (the prompt is inert and labelled), but it puts attacker-chosen text one Enter key away from an agent with tool access, so it's opt-in (below). Never: `http`, `file`, `ssh`, `x-man-page`, `javascript`, `jira`, or any handler that takes a command line. The hub (`validate_links`) and `LinkPolicy.swift` change together (hard rule 7).
2. **App actions (`needsyou://<host>/<path>`).** A fixed, small set. Each is parsed in `NeedsYouCore` into a typed value whose fields pass a strict pattern (like `OrcaJump`); anything else does nothing. Each runs a fixed binary from a fixed path list (never `PATH`) with an argv list and a timeout, or an AppleScript **handler called with parameters** (`NSAppleEventDescriptor`, never string-built source). The hub keeps a path allow-list for `needsyou://` (today it accepts only the `orca/terminal?` prefix) mirrored in Core. Worst case per action is written down: "a sender can switch which tab is shown".
3. **Never:** run a command, a script or a URL built from item text; copy free text to the clipboard as a command (pastejacking). A "copy command" fallback copies only a command the app built itself from validated fields.

AppleScript-driven jumps need a one-time Automation prompt per target app. The prompt is requested from a **Settings** click (which may activate the app), never from the panel, and the feature is off until then. The panel stays non-activating; the target terminal activating itself is that app's business (same as the Orca jump). The bundle needs `NSAppleEventsUsageDescription` in `Info.plist` for the prompt to appear at all; an ad-hoc signed app without the hardened runtime needs no Apple Events entitlement.

## Recommendation

1. **Hook-generated links first (sender-only).** The hook knows where it runs. Have it add the deepest link automatically: `vscode://file{cwd}` on the Mac; `vscode://vscode-remote/ssh-remote+<alias>{cwd}` on an SSH host (alias from a new `NEEDS_YOU_SSH_ALIAS`, set by the installer's `--ssh-alias`, default the short hostname); `vscode://anthropic.claude-code/open?session=<id>` when the session runs inside VS Code. All already-allowed schemes, so no API change. This is most of the value for the least work.
2. **One generic terminal action** in the app: `needsyou://terminal/focus?app=<iterm2|terminal|wezterm|tmux>&id=<...>[&tmux=%<n>]`, modelled on `OrcaJump`. WezTerm and local tmux first (no permission prompt), then iTerm2 and Terminal.app behind the Settings opt-in. Ghostty after a spike. The hook fills it from `ITERM_SESSION_ID` / tty / `WEZTERM_PANE` / `TMUX_PANE`, or from `LC_NEEDS_YOU_TERM` for SSH sessions.
3. **Allow-list:** add `linear` now. Add `claude-cli` behind a Mac setting ("Open Claude Code links", off by default), with the hub accepting it; the card shows the decoded prompt's first line as the button tooltip. Keep everything else as is.
4. **Primary click:** the card's first link is its default action (ai-first "Routing"), and the global hotkey's "go to top card" (launch-prep open question) runs it. Integrations put the act-here link first.
5. **Not now:** remote `ssh <alias> tmux select-window`, `claude --resume` as an action (only a "copy resume command" built from a validated session UUID), Orca worktree links (none exist upstream).

## Build list

Each step is one small change with its tests. "API" means the `api-change` skill applies (`docs/API.md`, hub, `LinkPolicy.swift`/`HubClient.swift`, tests together).

1. **Built.** **Hook: automatic editor links** (sender-only). `integrations/claude-code/needs-you-hook.sh`: when `NEEDS_YOU_AGENT_LINK` is unset, add `VS Code=vscode://file{cwd}` on macOS hosts; `VS Code=vscode://vscode-remote/ssh-remote+$NEEDS_YOU_SSH_ALIAS{cwd}` when `SSH_CONNECTION` is set; `Claude tab=vscode://anthropic.claude-code/open?session=<id>` when `TERM_PROGRAM=vscode` or `VSCODE_IPC_HOOK_CLI` is set (verify the hook env shows this for extension sessions). `NEEDS_YOU_AGENT_LINK=none` turns it off. Percent-encode paths (`quote`). Tests: a new `tests/test_hook_links.py` (same harness as `tests/test_orca.py`, which runs the hook with a fake CLI), asserting the `--link` args. Docs: `integrations/claude-code/README.md`, `docs/guides/claude-code.md`.
2. **Built.** **Installer: `--ssh-alias NAME`** (sender-only). `hub/join-install.sh` writes `NEEDS_YOU_SSH_ALIAS` to the env file; `needs-you doctor` shows it in the `claude hooks` detail. Tests: `tests/test_install.py`, `tests/test_doctor.py`.
3. **Built.** **Allow `linear`** (API). Hub scheme set, `LinkPolicy.allowedSchemes`, `docs/API.md`, `docs/AGENT-GUIDE.md` rule 4, the skill's scheme list, `tests/test_validation.py`, `LinkPolicyTests`.
4. **Built** (`APP_LINK_PATHS`, `LinkPolicy.appActionPaths`, `tests/test_link_mirror.py`). **Generalize the `needsyou://` allow-list** (API). Hub: replace `APP_LINK_PREFIX` with a tuple of allowed `host/path` prefixes (`orca/terminal`, `terminal/focus`). Core: `LinkPolicy.openableURL` tries each action parser. Old hubs reject the new link with 400, so the hook keeps its "retry without the app link" fallback (it exists for `Terminal=` today; make it drop every `needsyou://` link). Tests: `tests/test_validation.py`, `LinkPolicyTests`.
5. **Built.** **`TerminalJump` in NeedsYouCore** (Mac, pure). `mac/Sources/NeedsYouCore/TerminalJump.swift`: parse `needsyou://terminal/focus?app=&id=[&tmux=]`; validation per app: iTerm2 `id` is a UUID; Terminal `id` matches `^/dev/ttys[0-9]{1,4}$`; WezTerm `^[0-9]{1,6}$`; tmux pane `^%[0-9]{1,6}$`. Exactly these params, at most once each. Fixed CLI paths for `wezterm` and `tmux` (Homebrew and `/usr/local`, `/Applications/WezTerm.app/Contents/MacOS/wezterm`). `arguments` and `command` (the copy fallback) like `OrcaJump`. Tests: `mac/Tests/NeedsYouCoreTests/TerminalJumpTests.swift`, registered in `mac/Sources/NeedsYouSelfTest/main.swift` and symlinked.
6. **Built.** **`TerminalJumpRunner` in the app, no-permission backends** (Mac). `mac/Sources/NeedsYou/TerminalJumpRunner.swift`: WezTerm (`cli activate-pane --pane-id`, then `open -b com.github.wez.wezterm`), local tmux (`select-window` + `select-pane`, then raise the terminal named by `app`). `Process` with argv, 5 s timeout, never a shell; on failure copy `command` and show it on the card. Wire into `AppModel.open(...)` next to `OrcaJumpRunner`. `FloatingPanelTests` must still pass.
7. **Built** (Settings → Integrations → Jump to iTerm2 and Terminal tabs). **AppleScript backends behind a Settings opt-in** (Mac). Settings → Integrations: "Jump to iTerm2 / Terminal tabs". The toggle's click sends a harmless Apple Event to trigger the TCC prompt (allowed: Settings may activate). `Resources/Info.plist`: `NSAppleEventsUsageDescription`. Bundle `Resources/terminal-jump.applescript` with two handlers (`focus_iterm(uuid)`, `focus_terminal(tty)`), compiled once with `NSAppleScript` and called through `executeAppleEvent` with typed parameters. Off: the button copies the command. Pure parts (which backend, enabled or not) tested in Core.
8. **Built.** **Hook: terminal identity** (sender-only, after 4). Record `TERM_PROGRAM`, `ITERM_SESSION_ID`, the Claude process's tty, `WEZTERM_PANE`, `TMUX_PANE`, else `LC_NEEDS_YOU_TERM`; emit a `Terminal=needsyou://terminal/focus?...` link (not alongside the Orca one: Orca wins). Guide text for the Mac rc line (`export LC_NEEDS_YOU_TERM=...`) in `docs/guides/claude-code.md`, with the tmux staleness caveat. Tests as in step 1.
9. **Built**, except the `github-actions.yml` `?pr=` link (left for the GitHub integration work). **Link conventions in the sender contract** (docs only). `docs/AGENT-GUIDE.md` rule 4 and `integrations/claude-code/skill/needs-you/SKILL.md`: "put the act-here link first", plus the table above (PR `/files`, check run `html_url`, Slack permalink, Jira `browse`). `integrations/ci/github-actions.yml`: link the job with `?pr=` when the event is a PR.
10. **`claude-cli` opt-in** (API + Mac). Hub and `LinkPolicy` accept `claude-cli://open` only (no other host), with `q` ≤ 1,000 chars; the app opens it only when Settings → "Open Claude Code links" is on, otherwise shows it as text. Tests on both sides. Docs: API, AGENT-GUIDE.
11. **Spikes, written up before building:** Ghostty terminal ids (is there an env var; does `focus` exist in its sdef); VS Code `tunnel+` form; whether `vscode://anthropic.claude-code/open?session=` works for a Remote-SSH window.

## Open decisions

1. `claude-cli` on the allow-list at all, or only through the opt-in? (Recommended: opt-in.)
2. Remote tmux selection over SSH (phase 3): worth a Mac-side SSH alias list, or is "focus the Mac tab" enough?
3. Should the hook add editor links by default, or only when the installer was given `--ssh-alias`? (Recommended: by default on the Mac, with `--ssh-alias` on remote hosts.)
