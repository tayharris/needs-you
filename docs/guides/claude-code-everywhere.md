# Claude Code alerts everywhere

A card on your Mac whenever a Claude Code session stops to wait for you (a permission prompt, a plan to approve, a question, idle waiting for input, or an API error or usage limit that stopped it), wherever that session runs: on the Mac, on a server over SSH, inside tmux, in a VS Code Remote-SSH window, or in an Orca terminal. The card clears itself as soon as the session moves again.

## Zero to alerts, copy-paste

You need the Mac app running ([quickstart.md](quickstart.md) step 1). For machines other than the Mac, they and the Mac must be on one tailnet ([tailscale.md](tailscale.md)).

**On the Mac:** right-click the pill → **Settings…** → **Connect a machine**: *A server or agent that sends alerts*, a name (e.g. `claude`), **Uses** = the number of machines you'll set up, **Create invite**, then **Shell one-liner**. It copies a line like `curl -fsSL http://my-mac.example.ts.net:8765/join/nyi_.../install.sh | bash -s -- --yes --claude-hooks user --skill --alerts`.

**On each machine where Claude Code runs** (the Mac itself included), paste that line. That's the whole setup (add `--auto-update` to let the machine update itself daily, see [Keeping up to date](updates.md)):

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --claude-hooks user --skill --alerts
```

On a server you reach from the Mac over SSH (or VS Code Remote-SSH), add `--ssh-alias <name>`, the name the Mac's `~/.ssh/config` uses for it, so its cards get a button that opens the session's folder in VS Code there.

1. The installer puts the `needs-you` CLI in `~/.local/bin` (and that directory on `PATH`, with one tagged line in your shell profile; `--no-path` prints it instead), a token of this machine's own in `~/.config/needs-you/env`, the hooks in `~/.claude/settings.json` (with `~/.claude/hooks/needs-you-hook.sh`), the skill in `~/.claude/skills/needs-you/`, and a 5-minute `needs-you flush`. A test card (`setup:<host>:test`) shows under **Recent** in the panel.
2. `--alerts` turns the hooks on for every Claude Code session on this machine (`NEEDS_YOU_AGENT_ALERTS=1` in the env file). Without it the hooks stay quiet, except in Orca sessions, which are on by default.
3. Restart open Claude Code sessions (or run `/hooks` in them) so they load the hooks.

Re-running the line is safe: it keeps the token and every setting you don't pass again. To check, open a new shell and run `needs-you doctor`: it should show `OK  claude hooks  installed in ~/.claude/settings.json; ...; alerts on (NEEDS_YOU_AGENT_ALERTS=1 in env file); context alert at 80%` and `OK  claude skill`. Every `WARN` or `FAIL` line has its fix under it.

Prefer to let an agent do it? Click **Agent prompt** instead and paste it into Claude Code on that machine. The prompt already says to use `--claude-hooks user --skill --alerts` when the machine runs Claude Code.

Check it without waiting for a real prompt:

```bash
echo '{"session_id":"test-1","cwd":"'"$PWD"'","notification_type":"permission_prompt","message":"test"}' |
  NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.claude/hooks/needs-you-hook.sh notify
# a card "Claude needs permission: <this folder>" appears; clear it:
echo '{"session_id":"test-1"}' | NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.claude/hooks/needs-you-hook.sh resolve
```

## What a card says

One card per session, keyed `agent:<host>:<session>` (in Orca, the terminal handle instead of the session id), updated rather than duplicated. The title says what's needed and the project:

| The session | Card title |
|---|---|
| Wants to run a command | **Claude wants to run git: my-repo** (the program's name only) |
| Wants to edit a file | **Claude wants to edit config.yml: my-repo** (the file's name only) |
| Has a plan ready (plan mode) | **Approve Claude's plan: my-repo** |
| Asked you a question | **Claude asked you a question: my-repo** |
| Another permission prompt | **Claude needs permission for github create_issue: my-repo** |
| Idle, waiting for input | **Claude is waiting for you: my-repo** |
| Stopped on an API error | **Claude hit a rate limit: my-repo**, **Claude stopped on an API error: my-repo**, ... |
| Hit its usage limit and won't resume | **Claude hit its usage limit: my-repo** |

A second, low-priority card, `agent:<host>:<session>:context`, says when the session's context is filling up: **Claude's context is 85% full: my-repo**, suggesting `/compact` or `/clear` (see [Context alert](#context-alert)).

The body has Claude's notification text (or the API error), the working directory and host, and where the session runs:

| Session runs in | The body says |
|---|---|
| A tmux pane | ``tmux `work:2.1` `` (session:window.pane) |
| VS Code's terminal (`TERM_PROGRAM=vscode`) | `VS Code` |
| A plain SSH login (not tmux) | `SSH` |
| An Orca terminal | the Orca worktree and the `orca terminal switch` command |

No prompt text, transcript or tool input is sent: a permission card names the tool and at most the program's name or the file's basename, never the command or the content.

### Buttons

| Session runs | Button |
|---|---|
| On the Mac | **VS Code**: opens the folder (`vscode://file<cwd>`) |
| On a server, with `--ssh-alias devbox` | **VS Code**: opens the folder in a Remote-SSH window (`vscode://vscode-remote/ssh-remote+devbox<cwd>`) |
| In the VS Code extension (not the CLI in VS Code's terminal) | **Claude**: focuses that conversation's tab (`vscode://anthropic.claude-code/open?session=<id>`; the session must belong to the workspace open in the focused window) |
| In Orca | **Terminal**: switches Orca to that terminal |
| In a terminal on the Mac (tmux, WezTerm, iTerm2, Terminal, Ghostty) | **Terminal**: brings that tab or pane forward ([Terminal button](#terminal-button)) |
| On a server over SSH, with `LC_NEEDS_YOU_TERM` set on the Mac | **Terminal**: brings forward the Mac tab the SSH connection runs in |

`NEEDS_YOU_AGENT_LINK` replaces the editor buttons with one of your own, and `none` turns them off (the Terminal button stays).

### Context alert

When a session's context is `NEEDS_YOU_CONTEXT_ALERT_PCT` percent full (default 80) at the end of a turn, a `low` card suggests `/compact` (summarize and keep going) or `/clear` (start fresh). It updates as the session grows (every 5 points), and resolves itself once the session is back under the line (after `/compact` or `/clear`), and when the session ends.

The hook reads only the tail of the session's transcript (the last 256 KB, then 2 MB if it has to) for the newest main-thread assistant message, and adds its `input_tokens`, `cache_read_input_tokens` and `cache_creation_input_tokens`. The window is `NEEDS_YOU_CONTEXT_WINDOW` if set, else 1,000,000 when the model is a `[1m]` one (from `SessionStart`, `ANTHROPIC_MODEL` or `model` in `~/.claude/settings.json`) or the usage is already past 200,000, else 200,000. `--context-alert <pct>` on the installer sets the threshold; `0` turns it off.

## Where it runs

### On the Mac

The installer lists `http://127.0.0.1:8765` first in `~/.config/needs-you/env` on the Mac, so local sessions post even while Tailscale is down. Cards from the Mac get a **VS Code** button that opens the project folder; `--agent-link 'Cursor=cursor://file{cwd}'` swaps it for Cursor.

### On a server, over SSH

The hooks run on the server, so the server is the sender: run the line above there, not on the Mac. It needs to reach the Mac's hub over Tailscale; without Tailscale, see [tailscale.md → Without Tailscale](tailscale.md#a-machine-without-tailscale). While the Mac sleeps, cards queue on the server and arrive within about 5 minutes of it waking.

The card names the host and directory. For a **Terminal** button that brings forward the Mac tab the SSH connection runs in, name the tab on the Mac ([Terminal button](#terminal-button)).

### Inside tmux

Nothing extra. The card names the pane (``tmux `work:2.1` ``), so `tmux attach -t work` and `tmux select-window -t work:2` get you there. Put `NEEDS_YOU_AGENT_ALERTS=1` in `~/.config/needs-you/env` rather than in a shell `export`: the hook reads the file on every event, while a tmux server started earlier never sees a later export. Detaching leaves the session (and its card) alive; killing the pane ends Claude, and the [lease](#when-a-session-dies) clears the card.

### VS Code Remote-SSH

Claude Code running in a VS Code window connected to a server is a session on that server: set the server up as above, with `--ssh-alias devbox` (or `NEEDS_YOU_SSH_ALIAS=devbox` in its env file). Its cards then get a button that brings that VS Code window forward on the Mac (`vscode://vscode-remote/ssh-remote+devbox<cwd>`), and sessions in the Claude Code extension also get a **Claude** button for their tab.

- `devbox` must be the name VS Code uses for the host (from `~/.ssh/config` or the Remote-SSH host list on the Mac).
- The link opens the session's working directory. If it isn't the folder the window has open, VS Code opens a new window for it.
- For a different link, set a template instead: `--agent-link 'VS Code=vscode://vscode-remote/ssh-remote+{host}{cwd}'`. The hook fills in `{cwd}`, `{host}` (the short hostname), `{session}` and `{handle}` (Orca's terminal handle; a template using it is skipped outside Orca).

### Terminal button

Clicking a card's **Terminal** button brings forward the terminal tab or pane the session runs in and marks the card done. The hook writes the link (`needsyou://terminal/focus?app=…`); the Mac app checks every value against a strict pattern and runs only fixed commands, never anything from the card.

| Terminal on the Mac | The hook reads | The app runs | Needs |
|---|---|---|---|
| tmux | `$TMUX_PANE`, and which terminal tmux runs in | `tmux select-window` and `select-pane -t %<n>`, then that terminal comes forward | nothing (the default tmux server) |
| WezTerm | `$WEZTERM_PANE` | `wezterm cli activate-pane --pane-id <n>`, then WezTerm comes forward | nothing |
| iTerm2 | `$ITERM_SESSION_ID` | AppleScript: selects that session | **Settings → Integrations → Jump to iTerm2 and Terminal tabs**, then allow the Automation prompt |
| Terminal | the session's tty (`/dev/ttys<n>`) | AppleScript: selects the tab on that tty | the same setting |
| Ghostty | `TERM_PROGRAM=ghostty` | brings Ghostty forward (no tab selection yet) | nothing |

Without the setting, iTerm2 and Terminal cards still get the button; it brings the app forward. A CLI switch that fails (the pane closed) puts the command on the clipboard. The jump never activates Needs You itself, and the panel never asks for a permission: the Automation prompt comes only from the Settings toggle (**Check again** asks again once the terminal is open).

**Sessions over SSH.** The hook runs on the server and can't see which Mac tab holds the connection, so the Mac tells it. macOS's ssh sends every `LC_*` variable (`SendEnv LANG LC_*` in `/etc/ssh/ssh_config`), and Debian and Ubuntu's sshd accepts them (`AcceptEnv LANG LC_*`), so one line in the Mac's shell is enough. Add this to `~/.zshrc` on the Mac:

```sh
# needs-you: name this tab for Claude Code cards from SSH sessions
if [ -n "$TMUX_PANE" ]; then
  export LC_NEEDS_YOU_TERM="app=tmux&pane=${TMUX_PANE#%}"
elif [ -n "$WEZTERM_PANE" ]; then
  export LC_NEEDS_YOU_TERM="app=wezterm&pane=$WEZTERM_PANE"
elif [ -n "$ITERM_SESSION_ID" ]; then
  export LC_NEEDS_YOU_TERM="app=iterm&session=${ITERM_SESSION_ID#*:}"
elif [ "$TERM_PROGRAM" = Apple_Terminal ]; then
  export LC_NEEDS_YOU_TERM="app=terminal&tty=$(tty)"
fi
```

For tmux on the Mac, add `&host=iterm` (or `wezterm`, `ghostty`, `terminal`) so the right app comes forward. Check it from a new tab: `ssh devbox 'echo $LC_NEEDS_YOU_TERM'` should print the value.

- If your `~/.ssh/config` has its own `SendEnv`, or the server's sshd doesn't accept `LC_*`, add `SendEnv LC_NEEDS_YOU_TERM` under the host in `~/.ssh/config` on the Mac and `AcceptEnv LC_NEEDS_YOU_TERM` to `/etc/ssh/sshd_config` on the server.
- It names a tab, nothing more: a pane number, a session id or a tty. Don't put anything else in it; the hook drops a value that isn't exactly one of the forms above.
- **tmux on the server:** a pane keeps the value from when its shell started. Re-attach from another Mac tab and old panes still name the first one (new panes pick up the new tab with `set -ga update-environment LC_NEEDS_YOU_TERM` in the server's `~/.tmux.conf`). A stale value fails safe: the button shows the wrong tab, or just brings the terminal forward.
- The remote's own tmux or WezTerm variables are never used: they name panes on the server, not on the Mac.

### Orca terminals

Sessions Orca starts are on automatically (Orca sets `$ORCA_TERMINAL_HANDLE`); `NEEDS_YOU_AGENT_ALERTS=0` turns them off. Their cards have a **Terminal** button: the Mac app runs `orca terminal switch` for that terminal, brings Orca forward and marks the card done. If the switch fails, the command goes on the clipboard. The body also has the command, for running by hand.

On a paired Orca server, tell the hook the name the Mac's Orca gives that server (as `orca environment list` shows it on the Mac), so the command and the button target it directly: add `--orca-environment 'My Devbox'` to the installer line (it writes `NEEDS_YOU_ORCA_ENVIRONMENT` to the env file).

Without it, the button tries the Mac's own Orca and then each paired environment in turn. Add `--orca` to the installer line for the automation prompt block; more in [orca.md](orca.md).

## When a session dies

A killed session (closed terminal, `kill`, reboot, OOM) never tells the hook it ended. Two backstops:

- **Process lease.** When the hook posts a card it records the Claude process id and start time in `~/.local/state/needs-you/claude-hooks/`. `needs-you flush`, which the installer runs every 5 minutes, resolves the card once that process is gone or its pid belongs to a newer process.
- **Expiry.** Each card expires 48 hours after its last post, for a machine that never comes back to run the flush. `NEEDS_YOU_AGENT_EXPIRY_HOURS` changes it; `0` never expires.

## Settings

Put these in `~/.config/needs-you/env` on the machine where Claude runs (or in the environment, which wins). The hook reads the file on every event, so no restart is needed.

| Variable | Default | Meaning |
|---|---|---|
| `NEEDS_YOU_AGENT_ALERTS` | unset (off, except in Orca) | `1` on, `0` off even in Orca. Installer: `--alerts` |
| `NEEDS_YOU_AGENT_CONTEXT` | `NEEDS_YOU_DEFAULT_CONTEXT`, else `work` | `work` or `personal`: when the card is prominent on the Mac |
| `NEEDS_YOU_AGENT_PRIORITY` | `normal` | `urgent`, `normal` or `low` |
| `NEEDS_YOU_AGENT_LINK` | unset: automatic editor buttons ([Buttons](#buttons)) | One link instead, `Label=url-template`, with `{cwd}`, `{host}`, `{session}`, `{handle}` (URL-encoded); `none` for no editor buttons. The scheme must be on the allow-list (`https`, `vscode`, `cursor`, `slack`, `figma`, `msteams`, `discord`, `linear`; `vscode`/`cursor` only as `file…`, `vscode-remote/ssh-remote+…` or the Claude session link, [API.md](../API.md#post-v1items-sender)). Installer: `--agent-link` |
| `NEEDS_YOU_SSH_ALIAS` | unset | This host's name in the Mac's `~/.ssh/config`: cards from it get a Remote-SSH button. Installer: `--ssh-alias` |
| `NEEDS_YOU_CONTEXT_ALERT_PCT` | `80` | Context card threshold in percent; `0` off. Installer: `--context-alert` |
| `NEEDS_YOU_CONTEXT_WINDOW` | `200000`, or `1000000` for a `[1m]` model | Context window in tokens, for the threshold |
| `NEEDS_YOU_AGENT_EXPIRY_HOURS` | `48` | Card expiry after its last post; `0` never |
| `NEEDS_YOU_ORCA_ENVIRONMENT` | unset | On a paired Orca server: its name in the Mac's Orca. Installer: `--orca-environment` |
| `NEEDS_YOU_BIN` | `needs-you` on `PATH`, else `~/.local/bin/needs-you` | CLI path |
| `NEEDS_YOU_HOOK_LOG` | unset | Append a debug line per event to this file |

## Installing by hand

Without an invite installer (for example, a token minted on a [server hub](../HUB.md)), from a checkout of this repo on that machine:

```bash
./scripts/setup-sender.sh --install-cli --alerts  # CLI, env file, flush schedule, PATH (asks for URL and token)
integrations/claude-code/install-hooks.sh         # hooks in ~/.claude/settings.json
mkdir -p ~/.claude/skills && cp -R integrations/claude-code/skill/needs-you ~/.claude/skills/
needs-you doctor                                  # in a new shell
```

`setup-sender.sh` takes the same `--alerts`, `--context-alert`, `--ssh-alias`, `--agent-link`, `--orca-environment`, `--no-path` and `--no-schedule` flags as the invite installer. `install-hooks.sh --project <repo>` installs into one repo instead, `--dry-run` previews, `--uninstall` removes. The hooks reference and guarantees: [integrations/claude-code/README.md](../../integrations/claude-code/README.md).

Something not showing up? [troubleshooting.md → Claude Code hooks](troubleshooting.md#claude-code-hooks).
