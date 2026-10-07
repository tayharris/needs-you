# Claude Code alerts everywhere

A card on your Mac whenever a Claude Code session stops to wait for you (a permission prompt, or idle waiting for input), wherever that session runs: on the Mac, on a server over SSH, inside tmux, in a VS Code Remote-SSH window, or in an Orca terminal. The card clears itself as soon as the session moves again.

## Zero to alerts, copy-paste

You need the Mac app running ([quickstart.md](quickstart.md) step 1). For machines other than the Mac, they and the Mac must be on one tailnet ([tailscale.md](tailscale.md)).

**On the Mac:** right-click the pill → **Settings…** → **Invite a machine**: a name (e.g. `claude`), role **Sender**, **Uses** = the number of machines you'll set up, **Create invite**, then **Shell one-liner**. It copies a line like `curl -fsSL http://my-mac.example.ts.net:8765/join/nyi_.../install.sh | bash -s -- --yes`.

**On each machine where Claude Code runs** (the Mac itself included), paste that line and add the Claude options, then opt in and check:

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --claude-hooks user --skill
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env
~/.local/bin/needs-you doctor
```

1. The installer puts the `needs-you` CLI in `~/.local/bin`, a token of this machine's own in `~/.config/needs-you/env`, the hooks in `~/.claude/settings.json` (with `~/.claude/hooks/needs-you-hook.sh`), the skill in `~/.claude/skills/needs-you/`, and a 5-minute `needs-you flush`. A test card (`setup:<host>:test`) shows under **Recent** in the panel.
2. The `echo` line turns the hooks on for every Claude Code session on this machine. Without it the hooks stay quiet (except in Orca sessions, which are on by default).
3. `needs-you doctor` should show `OK  claude hooks  installed in ~/.claude/settings.json; ...; alerts on (NEEDS_YOU_AGENT_ALERTS=1 in env file)` and `OK  claude skill`. A `WARN path` line means `~/.local/bin` isn't on your `PATH` yet; every `WARN` or `FAIL` line has its fix under it.

Restart open Claude Code sessions (or run `/hooks` in them) so they load the hooks. That's it.

Prefer to let an agent do it? Click **Agent prompt** instead and paste it into Claude Code on that machine, then add: *"Use --claude-hooks user --skill, and turn on NEEDS_YOU_AGENT_ALERTS=1 in ~/.config/needs-you/env."*

Check it without waiting for a real prompt:

```bash
echo '{"session_id":"test-1","cwd":"'"$PWD"'","notification_type":"permission_prompt","message":"test"}' |
  NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.claude/hooks/needs-you-hook.sh notify
# a card "Claude needs permission: <this folder>" appears; clear it:
echo '{"session_id":"test-1"}' | NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.claude/hooks/needs-you-hook.sh resolve
```

## What a card says

One card per session, keyed `agent:<host>:<session>` (in Orca, the terminal handle instead of the session id), updated rather than duplicated. The title says what's needed and the project: **Claude needs permission: my-repo**, **Claude is waiting for you: my-repo**. The body has Claude's notification text, the working directory and host, and where the session runs:

| Session runs in | The body says |
|---|---|
| A tmux pane | ``tmux `work:2.1` `` (session:window.pane) |
| VS Code's terminal (`TERM_PROGRAM=vscode`) | `VS Code` |
| A plain SSH login (not tmux) | `SSH` |
| An Orca terminal | the Orca worktree and the `orca terminal switch` command |

No prompt text, transcript or tool input is sent.

## Where it runs

### On the Mac

The installer lists `http://127.0.0.1:8765` first in `~/.config/needs-you/env` on the Mac, so local sessions post even while Tailscale is down. To get a button that opens the project folder in VS Code:

```bash
echo "NEEDS_YOU_AGENT_LINK='VS Code=vscode://file{cwd}'" >> ~/.config/needs-you/env
```

### On a server, over SSH

The hooks run on the server, so the server is the sender: run the three lines above there, not on the Mac. It needs to reach the Mac's hub over Tailscale; without Tailscale, see [tailscale.md → Without Tailscale](tailscale.md#a-machine-without-tailscale). While the Mac sleeps, cards queue on the server and arrive within about 5 minutes of it waking.

There's no button that jumps back to a plain terminal window yet; the card names the host and directory.

### Inside tmux

Nothing extra. The card names the pane (``tmux `work:2.1` ``), so `tmux attach -t work` and `tmux select-window -t work:2` get you there. Put `NEEDS_YOU_AGENT_ALERTS=1` in `~/.config/needs-you/env` rather than in a shell `export`: the hook reads the file on every event, while a tmux server started earlier never sees a later export. Detaching leaves the session (and its card) alive; killing the pane ends Claude, and the [lease](#when-a-session-dies) clears the card.

### VS Code Remote-SSH

Claude Code running in a VS Code window connected to a server is a session on that server: set the server up as above. Then give its cards a button that brings that VS Code window forward on the Mac:

```bash
# on the server; devbox is the SSH host name VS Code on the Mac connects to
echo "NEEDS_YOU_AGENT_LINK='VS Code=vscode://vscode-remote/ssh-remote+devbox{cwd}'" >> ~/.config/needs-you/env
```

- `devbox` must be the name VS Code uses for the host (from `~/.ssh/config` or the Remote-SSH host list on the Mac). If that's the server's short hostname, `ssh-remote+{host}{cwd}` works on every server with one line.
- `{cwd}` is the session's working directory. If it isn't the folder the window has open, VS Code opens a new window for it.
- The hook fills in `{cwd}`, `{host}` (the short hostname), `{session}` and `{handle}` (Orca's terminal handle; a template using it is skipped outside Orca). There's one link per card.

### Orca terminals

Sessions Orca starts are on automatically (Orca sets `$ORCA_TERMINAL_HANDLE`); `NEEDS_YOU_AGENT_ALERTS=0` turns them off. Their cards have a **Terminal** button: the Mac app runs `orca terminal switch` for that terminal, brings Orca forward and marks the card done. If the switch fails, the command goes on the clipboard. The body also has the command, for running by hand.

On a paired Orca server, tell the hook the name the Mac's Orca gives that server (as `orca environment list` shows it on the Mac), so the command and the button target it directly:

```bash
echo "NEEDS_YOU_ORCA_ENVIRONMENT='My Devbox'" >> ~/.config/needs-you/env
```

Without it, the button tries the Mac's own Orca and then each paired environment in turn. Add `--orca` to the installer line for the automation prompt block; more in [orca.md](orca.md).

## When a session dies

A killed session (closed terminal, `kill`, reboot, OOM) never tells the hook it ended. Two backstops:

- **Process lease.** When the hook posts a card it records the Claude process id and start time in `~/.local/state/needs-you/claude-hooks/`. `needs-you flush`, which the installer runs every 5 minutes, resolves the card once that process is gone or its pid belongs to a newer process.
- **Expiry.** Each card expires 48 hours after its last post, for a machine that never comes back to run the flush. `NEEDS_YOU_AGENT_EXPIRY_HOURS` changes it; `0` never expires.

## Settings

Put these in `~/.config/needs-you/env` on the machine where Claude runs (or in the environment, which wins). The hook reads the file on every event, so no restart is needed.

| Variable | Default | Meaning |
|---|---|---|
| `NEEDS_YOU_AGENT_ALERTS` | unset (off, except in Orca) | `1` on, `0` off even in Orca |
| `NEEDS_YOU_AGENT_CONTEXT` | `NEEDS_YOU_DEFAULT_CONTEXT`, else `work` | `work` or `personal`: when the card is prominent on the Mac |
| `NEEDS_YOU_AGENT_PRIORITY` | `normal` | `urgent`, `normal` or `low` |
| `NEEDS_YOU_AGENT_LINK` | unset | One link, `Label=url-template`, with `{cwd}`, `{host}`, `{session}`, `{handle}` (URL-encoded). The scheme must be on the allow-list (`https`, `vscode`, `cursor`, `orca`, `slack`, `figma`, `msteams`, `discord`). |
| `NEEDS_YOU_AGENT_EXPIRY_HOURS` | `48` | Card expiry after its last post; `0` never |
| `NEEDS_YOU_ORCA_ENVIRONMENT` | unset | On a paired Orca server: its name in the Mac's Orca |
| `NEEDS_YOU_BIN` | `needs-you` on `PATH`, else `~/.local/bin/needs-you` | CLI path |
| `NEEDS_YOU_HOOK_LOG` | unset | Append a debug line per event to this file |

## Installing by hand

Without an invite installer (for example, a token minted on a [server hub](../HUB.md)), from a checkout of this repo on that machine:

```bash
./scripts/setup-sender.sh                         # CLI + ~/.config/needs-you/env (asks for URL and token)
integrations/claude-code/install-hooks.sh         # hooks in ~/.claude/settings.json
mkdir -p ~/.claude/skills && cp -R integrations/claude-code/skill/needs-you ~/.claude/skills/
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env
needs-you doctor
```

`setup-sender.sh` doesn't schedule the flush (so leases aren't reaped); add the cron line from [add-a-sender.md](add-a-sender.md#manually-no-invite-link). `install-hooks.sh --project <repo>` installs into one repo instead, `--dry-run` previews, `--uninstall` removes. The hooks reference and guarantees: [integrations/claude-code/README.md](../../integrations/claude-code/README.md).

Something not showing up? [troubleshooting.md → Claude Code hooks](troubleshooting.md#claude-code-hooks).
