# needs-you for GitHub Copilot CLI

When a GitHub Copilot CLI session asks for permission (a shell command, a web fetch, any other tool), asks you a question, or finishes its turn and waits for your next message, a `needs` item appears on your Mac. It's resolved when you send the next prompt, a tool finishes, or the session ends.

It uses Copilot CLI's [hooks](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference) (every `*.json` in `~/.copilot/hooks/`, or `$COPILOT_HOME/hooks/`) and the same `needs-you-hook.sh` as the [Claude Code integration](../claude-code/README.md), started with a `copilot` argument. Opt-in, keys, links, leases and expiry work as described there.

The machine must be a sender first: an invite link (add `--copilot-hooks user --alerts` to its one-liner) or [`scripts/setup-sender.sh`](../../scripts/setup-sender.sh). User guide: [docs/guides/copilot.md](../../docs/guides/copilot.md).

## Files

```
integrations/copilot/
├── copilot-hooks.json          the hooks file, installed as <copilot home>/hooks/needs-you.json
└── install-copilot-hooks.sh    copies it and the hook into <copilot home>/hooks/
```

## Install

```bash
integrations/copilot/install-copilot-hooks.sh                    # ~/.copilot/hooks/, or $COPILOT_HOME/hooks/
integrations/copilot/install-copilot-hooks.sh --copilot-home DIR
integrations/copilot/install-copilot-hooks.sh --dry-run
integrations/copilot/install-copilot-hooks.sh --uninstall
```

The hooks file is ours alone, so nothing is merged: the installer writes `needs-you.json` and `needs-you-hook.sh` and leaves every other file in `hooks/` alone. It refuses a symlinked `hooks/` or file (it won't write through one). The commands find the hook through `${COPILOT_HOME:-$HOME/.copilot}`, so the file is the same on every machine and `needs-you update` replaces it as is. User-level hooks need no trust step; `"disableAllHooks": true` in `settings.json` or `config.json` turns all hooks off, and the installer and `needs-you doctor` say so. Copilot reads hooks when it starts: restart it.

## What gets posted

The file uses Copilot's camelCase events, whose payloads name the session `sessionId`.

| Copilot event | Hook mode | Action |
|---|---|---|
| `notification`, matcher `permission_prompt` | `notify copilot` | `needs-you add`: **Copilot wants to run make** (the program from the message `Run command: …`), **Copilot wants to fetch a page** (`Fetch URL: …`), else **Copilot needs your approval** |
| `notification`, matcher `elicitation_dialog` | `notify copilot` | `needs-you add`: **Copilot asks “<the MCP server's message>”** (redacted, clamped), else **Copilot asked you a question** |
| `agentStop` | `notify copilot` | `needs-you add`: **Copilot is waiting for you** (the turn ended). `NEEDS_YOU_AGENT_TURN_CARDS=0` keeps only permission and question cards |
| `userPromptSubmitted`, `postToolUse`, `postToolUseFailure` | `resolve copilot` | `needs-you resolve`, only if this session posted something |
| `sessionEnd` | `end copilot` | resolves the session's card |

- **Key:** `agent:<short-hostname>:<id>`, `<id>` being `$ORCA_TERMINAL_HANDLE` or Copilot's `sessionId`.
- **Never sent:** the notification message beyond the program name (it holds the whole command line or URL), prompts, tool arguments or tool output.
- **Source:** `--agent copilot-cli --project <basename of the project dir>`.
- **No decision hooks.** `preToolUse` and `permissionRequest` aren't used: a failing hook there denies the tool. `notification` fires only when a prompt is really shown; `permissionRequest` also fires for calls the rules allow on their own.
- Copilot waits for most hooks and reads their stdout as JSON (a notification's `additionalContext` would reach the model). So in `copilot` mode the hook reads its input, starts a background copy with no stdin, stdout or stderr, and exits 0 at once with no output. The copy keeps the lease on the Copilot process, so the 5-minute `needs-you flush` clears the card of a session that died.
- A one-shot `copilot -p` ends its turn and exits within a moment, so the turn-end card waits 2 seconds and is skipped once Copilot has exited: nobody is waiting.
- Cancelling a permission prompt with Esc fires no hook in Copilot CLI 1.0.93, so that card stays until the next prompt or the session ends. Copilot's `agent_idle` and `agent_completed` notifications are about background agents and post nothing.

## Settings

The [Claude Code hook settings](../claude-code/README.md#settings) apply, plus:

| Variable | Default | Meaning |
|---|---|---|
| `NEEDS_YOU_AGENT_TURN_CARDS` | on | `0`: no card when a turn ends, only permission and question cards |
| `COPILOT_HOME` | `~/.copilot` | Where Copilot, the installer, `needs-you doctor` and `needs-you update` look |

## Check and test

```bash
needs-you doctor      # a "copilot hooks" line
echo '{"sessionId":"test-1","cwd":"'"$PWD"'","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Run command: ls"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.copilot/hooks/needs-you-hook.sh notify copilot
echo '{"sessionId":"test-1"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.copilot/hooks/needs-you-hook.sh resolve copilot
```

`NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` logs to a file (stderr goes nowhere in this mode). `needs-you update` keeps `needs-you.json` and the hook copy current. Tests: `tests/test_copilot.py`.
