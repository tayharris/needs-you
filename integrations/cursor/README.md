# needs-you for Cursor

When a Cursor agent finishes its turn and waits for your next message, or stops on an error, a `needs` item appears on your Mac. It's resolved when you send the next prompt or the chat ends.

**Fidelity: finished turns only.** Cursor has no hook for "waiting for approval", so there is no card when the agent asks to run a command or edit a file.

It uses Cursor's [hooks](https://cursor.com/docs/hooks) (`~/.cursor/hooks.json`) and the same `needs-you-hook.sh` as the [Claude Code integration](../claude-code/README.md), started with a `cursor` argument. Opt-in, keys, links, leases and expiry work as described there.

The machine must be a sender first: an invite link (add `--cursor-hooks user --alerts` to its one-liner) or [`scripts/setup-sender.sh`](../../scripts/setup-sender.sh). User guide: [docs/guides/cursor.md](../../docs/guides/cursor.md).

## Files

```
integrations/cursor/
├── cursor-hooks.json          the entries merged into ~/.cursor/hooks.json
└── install-cursor-hooks.sh    merges them and copies the hook to ~/.cursor/hooks/
```

## Install

```bash
integrations/cursor/install-cursor-hooks.sh                  # ~/.cursor/hooks.json
integrations/cursor/install-cursor-hooks.sh --dry-run
integrations/cursor/install-cursor-hooks.sh --uninstall
```

The installer backs `hooks.json` up, removes any needs-you entries (a `command` naming `needs-you-hook.sh`), adds the current ones after your own, and leaves everything else as it was. It refuses invalid JSON and a symlinked `hooks.json` or `hooks/`. The commands are `./hooks/needs-you-hook.sh …`: Cursor runs user hooks from `~/.cursor`. Cursor reloads the file by itself. `needs-you update` keeps the hook copy and the entries current; `needs-you uninstall-hooks --cursor` removes them offline.

## What gets posted

| Cursor event | Hook mode | Action | Prints |
|---|---|---|---|
| `stop`, `status: completed` | `notify cursor` | `needs-you add`: **Cursor finished** (no text of the turn in the payload) | `{}` |
| `stop`, `status: error` | `notify cursor` | `needs-you add`: **Cursor stopped on an error** | `{}` |
| `stop`, `status: aborted` | `notify cursor` | nothing (you stopped it) | `{}` |
| `beforeSubmitPrompt` | `resolve cursor` | `needs-you resolve`, only if this chat posted something | `{"continue":true}` |
| `sessionEnd` | `end cursor` | resolves the chat's card | `{}` |

- **Key:** `agent:<short-hostname>:<conversation_id>`.
- **Project:** the first of `workspace_roots` (a user hook's working directory is `~/.cursor`).
- **Never sent:** `user_email` (Cursor sends it to every hook), prompts, attachments, the transcript.
- **Source:** `--agent cursor`. On the Mac the card gets a `cursor://file/...` button.
- **No permission hooks.** `preToolUse`, `beforeShellExecution`, `beforeMCPExecution`, `beforeReadFile`, `beforeTabFileRead` and `subagentStart` block the action when a hook's output is empty or invalid; none is registered, and `needs-you doctor` warns if one names the hook.
- **Output.** Cursor reads each hook's stdout as its answer. The hook prints its one line before anything else (also when alerts are off or the input is unreadable), so `beforeSubmitPrompt` always gets `{"continue":true}`: the docs don't say what an empty answer means there. Then it hands the work to a background copy and exits 0.
- A `cursor-agent -p` run ends its turn and exits at once: the turn-end card waits 2 seconds and is skipped once Cursor has exited.
- **Cursor runs the Claude Code hooks too** (`~/.claude/settings.json`, "Include Third-Party Plugins, Skills, and Other Configs", on by default): `Stop`, `UserPromptSubmit`, `SessionStart`, `SessionEnd`. Their payloads carry `cursor_version` and `conversation_id`, which Claude Code's never do, so the hook started without an agent argument exits at once on them: no double post, no Claude `Stop` clearing the Cursor card, no wasted work.

## Settings

The [Claude Code hook settings](../claude-code/README.md#settings) apply. Cursor starts hooks from the app, so set them in `~/.config/needs-you/env` rather than a shell profile.

## Check and test

```bash
needs-you doctor      # a "cursor hooks" line
```

Tests: `tests/test_cursor.py` (payloads replayed from Cursor's hooks reference; no live Cursor run, which needs a login).
