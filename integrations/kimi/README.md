# needs-you for Kimi Code CLI

When a Kimi Code CLI session asks you to approve a tool call, asks you a question, or finishes its turn and waits for your next message, a `needs` item appears on your Mac. It's resolved when you answer the approval, send the next prompt, interrupt the turn, a tool finishes, or the session ends.

It uses Kimi Code's [hooks](https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/customization/hooks.md) (`[[hooks]]` in `~/.kimi-code/config.toml`, or `$KIMI_CODE_HOME/config.toml`) and the same `needs-you-hook.sh` as the [Claude Code integration](../claude-code/README.md), started with a `kimi` argument. Opt-in, keys, links, leases and expiry work as described there. Kimi Code CLI only (the `kimi` command from `MoonshotAI/kimi-code`): the archived Python `kimi-cli` has no approval hook.

The machine must be a sender first: an invite link (add `--kimi-hooks user --alerts` to its one-liner) or [`scripts/setup-sender.sh`](../../scripts/setup-sender.sh). User guide: [docs/guides/kimi.md](../../docs/guides/kimi.md).

## Files

```
integrations/kimi/
├── kimi-hooks.toml          the block appended to <kimi home>/config.toml
└── install-kimi-hooks.sh    adds, replaces or removes that block, and copies the hook to <kimi home>/hooks/
```

## Install

```bash
integrations/kimi/install-kimi-hooks.sh                   # ~/.kimi-code/config.toml, or $KIMI_CODE_HOME
integrations/kimi/install-kimi-hooks.sh --kimi-home DIR
integrations/kimi/install-kimi-hooks.sh --dry-run
integrations/kimi/install-kimi-hooks.sh --uninstall
```

Kimi's config is TOML and Python 3.9 has no TOML parser, so the installer edits it as text, safely:

- **Only one block is ever touched.** It starts at `# needs-you (managed by install-kimi-hooks.sh; ...)` and ends at `# end needs-you`. Appending `[[hooks]]` tables at the end of a TOML file is always valid; a re-run replaces the block, `--uninstall` removes it, and everything else stays byte for byte (mode kept, a `config.toml.bak-<time>` written before any change, an unchanged file not rewritten).
- **Only the four keys Kimi allows** (`event`, `matcher`, `command`, `timeout`). Kimi refuses the whole config for any other key (checked live: `kimi doctor` reports `Unrecognized key`), so the version stamp is a comment line, `# needs-you-version: X.Y.Z`.
- **It refuses** a config where `hooks` is already a table (`[hooks]`, `[hooks.x]`) or a root inline list (`hooks = [...]`), a block with a start marker but no end, and a symlinked `config.toml`, `hooks/` or hook copy. Nothing is changed then; the invite installer skips Kimi with a warning and sets up the rest.
- The default home keeps `$HOME` in the commands (Kimi runs them through a shell), so the block is the same on every machine. With `--kimi-home DIR` (or `KIMI_CODE_HOME`), the commands name `DIR` itself.

Check the result with `kimi doctor`. Kimi reads hooks when it starts: restart it.

## What gets posted

| Kimi event | Hook mode | Action |
|---|---|---|
| `PermissionRequest` | `notify kimi` | `needs-you add`: **Kimi wants to run make** (the program from `display.command`), **Kimi wants to edit a.py**, **Kimi wants to fetch a page**, **Kimi wants approval for a plan** (the first lines of `display.plan`, `display.options` as steps), else **Kimi needs permission for &lt;tool&gt;** |
| `PreToolUse`, matcher `^AskUserQuestion$` | `notify kimi` | `needs-you add`: **Kimi asks “<question>”**, the questions and their choices in the body and as the item's `question` (Kimi approves this tool by itself, so it has no `PermissionRequest`) |
| `Stop` | `notify kimi` | resolves a question card the turn ended under, then `needs-you add`: **Kimi is waiting for you** (the turn ended). `NEEDS_YOU_AGENT_TURN_CARDS=0` keeps only approval, question and error cards |
| `StopFailure` | `notify kimi` | `needs-you add`: **Kimi stopped on an error**, with Kimi's one-line error message |
| `PermissionResult`, `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `Interrupt` | `resolve kimi` | `needs-you resolve`, only if this session posted something |
| `SessionStart` | `start kimi` | on a resume in the same process, resolves its earlier cards |
| `SessionEnd` | `end kimi` | resolves the session's card (`/exit`; Ctrl-C and SIGTERM fire none, and the lease clears the card at the next flush) |

- **Key:** `agent:<short-hostname>:<id>`, `<id>` being `$ORCA_TERMINAL_HANDLE` or Kimi's `session_id` (`session_<uuid>`).
- **Never sent:** the command line, the approval's `action` text, the session title, prompts, questions, tool input or output. A card names at most the program or a file's basename.
- **Source:** `--agent kimi-code --project <basename of the project dir>`.
- **Backgrounded, in a session of its own.** Kimi awaits `Stop`, `UserPromptSubmit`, `PreToolUse` and the session hooks, starts each hook through `sh -c` in a process group of its own, and kills that group (SIGTERM, then SIGKILL) when a hook runs past its timeout. So in `kimi` mode the hook reads its input, starts a copy with `setsid` (or perl's on macOS, which has no `setsid` binary) with no stdin, stdout or stderr, and exits 0 at once with no output: Kimi appends a `UserPromptSubmit` hook's stdout to the model's context and reads `Stop` output as a decision. Checked live with Kimi Code 2.1.1: a plain background child of a hook that ran past its timeout was killed, the `setsid` one survived.
- **Lease:** the foreground names the shell's parent (Kimi) before it returns, since that shell is gone by the time the copy looks. The 5-minute `needs-you flush` clears the card of a session that died.
- A one-shot `kimi -p` ends its turn and exits a moment later, so the turn-end card waits 2 seconds and is skipped once Kimi has exited. (`-p` approves tools by itself, so it has no approval cards either.)
- No exit 2 and no JSON output, ever: they would block a prompt or keep the agent working.

## Settings

The [Claude Code hook settings](../claude-code/README.md#settings) apply, plus:

| Variable | Default | Meaning |
|---|---|---|
| `NEEDS_YOU_AGENT_TURN_CARDS` | on | `0`: no card when a turn ends, only approval, question and error cards |
| `KIMI_CODE_HOME` | `~/.kimi-code` | Where Kimi, the installer, `needs-you doctor` and `needs-you update` look |

## Check and test

```bash
needs-you doctor      # a "kimi hooks" line
kimi doctor           # Kimi's own check of config.toml
echo '{"hook_event_name":"PermissionRequest","session_id":"session_test-1","cwd":"'"$PWD"'","tool_name":"Bash","display":{"command":"ls"}}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.kimi-code/hooks/needs-you-hook.sh notify kimi
echo '{"hook_event_name":"PermissionResult","session_id":"session_test-1"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.kimi-code/hooks/needs-you-hook.sh resolve kimi
```

`NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` logs to a file (stderr goes nowhere in this mode). `needs-you update` replaces the block when the hub's `kimi-hooks.toml` changes, and the hook copy. Tests: `tests/test_kimi.py` (payloads captured from Kimi Code 2.1.1; the full round trip, approval, question, turn end, prompt and `/exit`, was also run live in its TUI against a local hub).
