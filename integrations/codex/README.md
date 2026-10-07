# needs-you for OpenAI Codex CLI

When a Codex CLI session asks you to approve a command, an edit or an MCP tool call, or finishes its turn and waits for your next message, a `needs` item appears on your Mac. It's resolved as soon as you answer, the next tool runs, you interrupt the turn, or the session ends.

It uses Codex's [lifecycle hooks](https://learn.chatgpt.com/docs/hooks) (`~/.codex/hooks.json`) and the same `needs-you-hook.sh` as the [Claude Code integration](../claude-code/README.md), started with a `codex` argument. Everything that page says about opt-in, keys, links (Orca, the Mac terminal tab, VS Code), leases and expiry applies here too.

The machine must be a sender first: an invite link from the Mac app (add `--codex-hooks user --alerts` to its one-liner), or [`scripts/setup-sender.sh`](../../scripts/setup-sender.sh) ([guide](../../docs/guides/add-a-sender.md)). User guide: [docs/guides/codex.md](../../docs/guides/codex.md).

## Files

```
integrations/codex/
├── codex-hooks.json          the hook entries (user-level paths), for reference or hand-merging
└── install-codex-hooks.sh    merges them into <codex home>/hooks.json and copies the hook
```

The hook itself is [`../claude-code/needs-you-hook.sh`](../claude-code/needs-you-hook.sh); the installer copies it to `~/.codex/hooks/needs-you-hook.sh`.

## Install

```bash
integrations/codex/install-codex-hooks.sh                 # ~/.codex/hooks.json, or $CODEX_HOME/hooks.json
integrations/codex/install-codex-hooks.sh --codex-home DIR
integrations/codex/install-codex-hooks.sh --dry-run       # show the change
integrations/codex/install-codex-hooks.sh --uninstall
```

The installer backs up `hooks.json` first (`hooks.json.bak-<timestamp>`), replaces only its own entries (any command containing `needs-you-hook.sh`), appends them after existing groups so the positions of other hooks (Orca's, your own) don't move, refuses a file that isn't valid JSON, and doesn't rewrite an unchanged file.

**Trust them once.** Codex runs a hook only after you've reviewed it: start Codex, open `/hooks`, and trust the needs-you entries. Until then Codex skips them with a warning at startup. Re-running the installer keeps the same entries, so they stay trusted. (`codex --dangerously-bypass-hook-trust` skips the check for one run.)

`hooks = false` under `[features]` in `config.toml` turns every hook off; the installer and `needs-you doctor` say so.

## Turn it on

Same switch as the Claude Code hooks: nothing is posted unless `NEEDS_YOU_AGENT_ALERTS=1` (environment or `~/.config/needs-you/env`, which the invite installer's `--alerts` writes) or the session runs in an Orca terminal (`$ORCA_TERMINAL_HANDLE`). `NEEDS_YOU_AGENT_ALERTS=0` turns it off.

## What gets posted

| Codex event | Hook mode | Action |
|---|---|---|
| `PermissionRequest` | `notify codex` | `needs-you add`: **Codex wants to run make**, **Codex wants to edit config.py** (`apply_patch`; "2 files" for more), **Codex needs permission for linear create_issue** (MCP) |
| `Stop` | `notify codex` | `needs-you add`: **Codex is waiting for you** (the turn ended). `NEEDS_YOU_CODEX_TURN_CARDS=0` keeps only approval cards |
| `UserPromptSubmit`, `PostToolUse`, `Interrupt` | `resolve codex` | `needs-you resolve`, only if this session posted something |
| `SessionStart` (`clear`, `resume`, `compact`) | `start codex` | resolves the cards this Codex process posted before |
| `SessionEnd` | `end codex` | resolves the session's card |

- **Key:** `agent:<short-hostname>:<id>`, `<id>` being `$ORCA_TERMINAL_HANDLE` or the Codex `session_id`. One card per session, updated in place.
- **Title** names the tool and at most the program (the first word of a shell command that isn't `VAR=value`, a flag or a wrapper) or a file's basename from the patch header. Never the command line, the patch, `tool_input.description`, the prompt or Codex's last message: they can hold secrets.
- **Source:** `--agent codex --project <basename of cwd>`.
- The `PermissionRequest`, `Stop`, `UserPromptSubmit`, `PostToolUse` and `SessionStart` entries are `"async": true`, so Codex never waits on the network and the hook can't approve or deny anything. `SessionEnd` and `Interrupt` always run synchronously in Codex with a 1-3 s limit: the hook drops its marker and starts the resolve in the background, then exits.
- Every mode exits 0 and prints nothing (Codex would add plain stdout to the model's context).
- Markers live in `~/.local/state/needs-you/claude-hooks/` (shared with the Claude hook), carrying the lease that the 5-minute `needs-you flush` uses to resolve the card of a Codex process that died. Cards also expire 48 hours after their last post (`NEEDS_YOU_AGENT_EXPIRY_HOURS`).

Not covered: Codex's context usage (no `/compact` card), API errors (Codex has no `StopFailure` hook), and sessions running only in the Codex IDE extension or cloud.

### Why not `notify`?

Codex also has a single `notify = ["program"]` in `config.toml`, called with a JSON argument (`{"type": "agent-turn-complete", "thread-id": ..., "cwd": ..., ...}`) at the end of each turn. It never fires for approvals, has no event to resolve the card with, and holds one program, often already used for desktop notifications. The hooks cover all of that, so this integration doesn't use it.

## Settings

All the [Claude Code hook settings](../claude-code/README.md#settings) apply (`NEEDS_YOU_AGENT_CONTEXT`, `NEEDS_YOU_AGENT_PRIORITY`, `NEEDS_YOU_AGENT_LINK`, `NEEDS_YOU_SSH_ALIAS`, `LC_NEEDS_YOU_TERM`, `NEEDS_YOU_AGENT_EXPIRY_HOURS`, `NEEDS_YOU_ORCA_ENVIRONMENT`, `NEEDS_YOU_BIN`, `NEEDS_YOU_HOOK_LOG`), plus:

| Variable | Default | Meaning |
|---|---|---|
| `NEEDS_YOU_CODEX_TURN_CARDS` | on | `0`: no card when a turn ends, only approval prompts |
| `CODEX_HOME` | `~/.codex` | Where the installer, `needs-you doctor` and `needs-you update` look |

## Check and test

```bash
needs-you doctor          # a "codex hooks" line: installed, trusted, alerts on or off

echo '{"hook_event_name":"PermissionRequest","session_id":"test-1","cwd":"'"$PWD"'","tool_name":"Bash","tool_input":{"command":"make test"}}' |
  NEEDS_YOU_AGENT_ALERTS=1 NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.codex/hooks/needs-you-hook.sh notify codex
echo '{"session_id":"test-1"}' |
  NEEDS_YOU_AGENT_ALERTS=1 NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.codex/hooks/needs-you-hook.sh resolve codex
```

`needs-you update` keeps `~/.codex/hooks/needs-you-hook.sh` current and re-merges the entries when `codex-hooks.json` changes. Tests: `tests/test_codex.py`. Troubleshooting: [docs/guides/troubleshooting.md](../../docs/guides/troubleshooting.md#codex-hooks).
