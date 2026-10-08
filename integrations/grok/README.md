# needs-you for Grok Build

When a Grok Build session shows a permission prompt, or finishes its turn and has waited about a minute for your next message, a `needs` item appears on your Mac. It's resolved when you send the next prompt, a tool finishes, the turn is cancelled (a declined or dismissed permission, an interrupt), or the session ends.

It uses Grok Build's [hooks](https://docs.x.ai/build/features/hooks) (every `*.json` in `~/.grok/hooks/`, or `$GROK_HOME/hooks/`, always trusted) and the same `needs-you-hook.sh` as the [Claude Code integration](../claude-code/README.md), started with a `grok` argument. Opt-in, keys, links, leases and expiry work as described there. Grok Build is xAI's `grok`; the community `grok-cli` (npm `grok-dev`) is a different program and isn't supported.

The machine must be a sender first: an invite link (add `--grok-hooks user --alerts` to its one-liner) or [`scripts/setup-sender.sh`](../../scripts/setup-sender.sh). User guide: [docs/guides/grok.md](../../docs/guides/grok.md).

## Files

```
integrations/grok/
├── grok-hooks.json          the hooks file, installed as <grok home>/hooks/needs-you.json
└── install-grok-hooks.sh    copies it and the hook into <grok home>/hooks/
```

## Install

```bash
integrations/grok/install-grok-hooks.sh                   # ~/.grok/hooks/, or $GROK_HOME/hooks/
integrations/grok/install-grok-hooks.sh --grok-home DIR
integrations/grok/install-grok-hooks.sh --dry-run
integrations/grok/install-grok-hooks.sh --uninstall
```

The hooks file is ours alone, so nothing is merged: the installer writes `needs-you.json` and `needs-you-hook.sh` and leaves every other file in `hooks/` alone. It refuses a symlinked `hooks/` or file. The commands find the hook through `${GROK_HOME:-$HOME/.grok}` (Grok runs them through a shell), so the file is the same on every machine and `needs-you update` replaces it as is. Grok tolerates the `_needs_you_version` key (checked live: `grok inspect` lists all eight entries). Grok reads hooks when it starts: restart it. An organization policy with `allow_managed_hooks_only` turns all user hooks off; the installer and `needs-you doctor` say so.

## One card per wait, with the Claude Code hooks

Grok also runs the Claude Code hooks from `~/.claude/settings.json` (and a trusted project's `.claude/settings.json`) by default; it sets `$GROK_HOOK_EVENT` on every hook it runs. The shared hook decides:

- Called as `grok` (this file): it posts, as Grok.
- Called any other way with `$GROK_HOOK_EVENT` set (the Claude Code entries): if `${GROK_HOME:-~/.grok}/hooks/needs-you.json` exists, it exits at once and does nothing; otherwise it posts as Grok in its place.

So with both installed, a Grok wait is posted once, from this file; with only the Claude Code hooks, those still give Grok its cards (labelled Grok, with no Claude context check). Checked live with grok 1.0.46: one post per wait both ways. Turning Grok's Claude compatibility off (`[compat.claude] hooks = false`, or `GROK_CLAUDE_HOOKS_ENABLED=0`) isn't needed and would also turn off your other Claude hooks in Grok.

## What gets posted

Grok sends camelCase keys plus Claude-style aliases (`hook_event_name`, `session_id`), but a `Notification` has only `notificationType`.

| Grok event | Hook mode | Action |
|---|---|---|
| `Notification`, matcher `permission_prompt` | `notify grok` | `needs-you add`: **Grok needs permission** (the payload doesn't name the tool) |
| `Notification`, matcher `idle_prompt` | `notify grok` | `needs-you add`: **Grok is waiting for you**, about 60 s after the turn, and none if you type first. Keeps an open permission card. `NEEDS_YOU_AGENT_TURN_CARDS=0` turns it off |
| `StopFailure` | `notify grok` | `needs-you add`: **Grok hit a rate limit**, **Grok needs you to sign in again**, **Grok stopped on a billing problem**, else **Grok stopped on an error** (from `error`; `errorDetails` isn't sent) |
| `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `StopCancelled` | `resolve grok` | `needs-you resolve`, only if this session posted something |
| `SessionStart` | `start grok` | on a resume in the same process, resolves its earlier cards |
| `SessionEnd` | `end grok` | resolves the session's card (in live runs, a SIGTERM to Grok still cleared it) |

- **No `Stop` hook.** The waiting card comes from `idle_prompt`, as in Claude Code, not at the end of every turn. `Stop` is a gate in Grok (awaited, and exit 2 keeps the agent working), and it also fires at session end.
- **No gate hooks** (`PreToolUse`, `SubagentStop`): exit 2 there denies a tool or hands stderr to the model. The hook never exits 2 and never prints.
- **Subagents** (a payload with `subagentType`) post nothing: their waits show in the main session.
- **Key:** `agent:<short-hostname>:<id>`, `<id>` being `$ORCA_TERMINAL_HANDLE` or Grok's `session_id`.
- **Never sent:** the notification message, prompts, `lastAssistantMessage`, tool input or output.
- **Source:** `--agent grok --project <basename of the project dir>`.
- **Backgrounded, in a session of its own.** Grok waits for its hooks (the default timeout is 5 s, 600 s for `PostToolUse`), starts each through `sh -c` in a process group of its own and kills that group on timeout (checked live: a plain background child of a hook that ran past its timeout was killed, a `setsid` one survived). So the hook reads its input, starts a copy with `setsid` (perl's on macOS) and no stdio, and exits 0 at once. The foreground names the shell's parent (Grok) for the lease, so the 5-minute `needs-you flush` clears the card of a session that died.

## Settings

The [Claude Code hook settings](../claude-code/README.md#settings) apply, plus:

| Variable | Default | Meaning |
|---|---|---|
| `NEEDS_YOU_AGENT_TURN_CARDS` | on | `0`: no `idle_prompt` card, only permission and error cards |
| `GROK_HOME` | `~/.grok` | Where Grok, the installer, the hook's "own install" check, `needs-you doctor` and `needs-you update` look |

## Check and test

```bash
needs-you doctor      # a "grok hooks" line
grok inspect          # needs-you's entries under Hooks
echo '{"hook_event_name":"Notification","notificationType":"permission_prompt","session_id":"test-1","cwd":"'"$PWD"'"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.grok/hooks/needs-you-hook.sh notify grok
echo '{"hook_event_name":"UserPromptSubmit","session_id":"test-1"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.grok/hooks/needs-you-hook.sh resolve grok
```

`NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` logs to a file (stderr goes nowhere in this mode). Tests: `tests/test_grok.py` (payloads captured from grok 1.0.46; permission, idle and the Claude-hooks fallback were also run live against a local hub).
