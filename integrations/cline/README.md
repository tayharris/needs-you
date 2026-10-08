# needs-you for Cline

When a Cline task finishes and waits for your next message, or ends on an error, a `needs` item appears on your Mac. It's resolved when you send a message, cancel, start or resume a task, or the session ends. Both the VS Code extension and the `cline` CLI.

**Fidelity: finished tasks only.** Cline runs no hook when it waits for an approval, so there is no card for those.

It uses Cline's file hooks (executables named after the event in `~/Documents/Cline/Hooks/`) and the same `needs-you-hook.sh` as the [Claude Code integration](../claude-code/README.md), started with a `cline` argument. Opt-in, keys, links, leases and expiry work as described there.

The machine must be a sender first: an invite link (add `--cline-hooks user --alerts` to its one-liner) or [`scripts/setup-sender.sh`](../../scripts/setup-sender.sh). User guide: [docs/guides/cline.md](../../docs/guides/cline.md).

## Files

```
integrations/cline/
└── install-cline-hooks.sh    writes the hook files and copies the hook
```

## Install

```bash
integrations/cline/install-cline-hooks.sh                          # ~/Documents/Cline/Hooks/
integrations/cline/install-cline-hooks.sh --cline-hooks-dir DIR
integrations/cline/install-cline-hooks.sh --dry-run
integrations/cline/install-cline-hooks.sh --uninstall
```

Each hook file is a few lines of `sh`, marked `# needs-you:`, that runs `~/.config/needs-you/cline/hooks/needs-you-hook.sh <mode> cline <Event>` (it does nothing if that's gone). Files without the marker are yours: never replaced or removed. A `TaskComplete` of your own stops the install (there would be no card); any other is skipped with a note. Symlinks are refused. `needs-you update` keeps the hook copy current; `needs-you uninstall-hooks --cline` removes the marked files and the copy offline.

## What gets posted

| Cline hook file | Hook mode | Action |
|---|---|---|
| `TaskComplete` | `notify cline` | `needs-you add`: **Cline finished** |
| `TaskError` (CLI) | `notify cline` | `needs-you add`: **Cline stopped on an error** |
| `UserPromptSubmit`, `TaskCancel` | `resolve cline` | `needs-you resolve`, only if this task posted something |
| `TaskStart`, `TaskResume` | `start cline` | resolves this task's card and the cards of earlier tasks of the same Cline process |
| `SessionShutdown` (CLI) | `end cline` | resolves the task's card |

- **Key:** `agent:<short-hostname>:<taskId>`.
- **Project:** the first of `workspaceRoots`.
- **Never sent:** the agent's final text (`turn.outputText`, `taskMetadata.result`), prompts, tool input or output.
- **Source:** `--agent cline`.
- Runs whose `parent_agent_id` is set (subagents) post nothing.
- Cline in VS Code waits up to 30 seconds for a hook; the hook prints nothing (Cline reads "no JSON" as "go on"), hands the work to a background copy and exits 0 at once.
- A one-shot `cline "task"` finishes and exits within a moment: the card waits 2 seconds and is skipped once Cline has exited.
- The lease is the process that ran the hook: the VS Code extension host, the one-shot `cline`, or for interactive CLI sessions the CLI's background hub process (`cline --cline-hub-daemon`), which outlives the terminal.

Payloads (Cline CLI 3.0.69, live): JSON on stdin with `clineVersion`, `hookName` (`agent_start`, `agent_end`, …), `timestamp`, `taskId`, `sessionContext`, `workspaceRoots`, `workspaceInfo`, `userId`, `agent_id`, `parent_agent_id`, plus per-event objects.

## Settings

The [Claude Code hook settings](../claude-code/README.md#settings) apply. VS Code starts the hooks, so set them in `~/.config/needs-you/env` rather than a shell profile.

## Check and test

```bash
needs-you doctor      # a "cline hooks" line
```

Tests: `tests/test_cline.py`.
