# needs-you for Claude Code

Two independent pieces. Use either or both, in any repo or VM, with or without Orca.

| Piece | What it does | Install |
|---|---|---|
| **Hooks** | When a Claude Code session stops to ask for permission or sits waiting for input, a `needs` item appears on your Mac. It's resolved automatically as soon as the session moves again. | `./install-hooks.sh` |
| **Skill** | Teaches the agent when and how to post a specific blocker ("choose A or B for ACME-123") and to resolve it afterwards. | copy `skill/needs-you` to `~/.claude/skills/` |

Both call the `needs-you` CLI, so set the machine up as a sender first: an invite link from the Mac app (its installer can add the hooks and the skill too, with `--claude-hooks user --skill`), or [`scripts/setup-sender.sh`](../../scripts/setup-sender.sh) ([guide](../../docs/guides/add-a-sender.md)).

## Files

```
integrations/claude-code/
├── hooks.json            the hook config (user-level paths), for reference or hand-merging
├── needs-you-hook.sh     the hook itself: bash + python3, always exits 0
├── install-hooks.sh      merges hooks.json into a settings.json (python3, with a backup)
└── skill/needs-you/SKILL.md
```

## Hooks

### Install

```bash
# user level: every repo on this machine (~/.claude/settings.json)
integrations/claude-code/install-hooks.sh

# project level: commit .claude/settings.json and .claude/hooks/ so everyone gets it
integrations/claude-code/install-hooks.sh --project /path/to/repo

# project level, just for you (settings.local.json, normally gitignored)
integrations/claude-code/install-hooks.sh --project /path/to/repo --local

# preview, or remove
integrations/claude-code/install-hooks.sh --dry-run
integrations/claude-code/install-hooks.sh --uninstall
```

The installer:

- copies `needs-you-hook.sh` to `~/.claude/hooks/` (or `<repo>/.claude/hooks/`),
- backs up the settings file to `settings.json.bak-<timestamp>` before changing it,
- replaces any earlier needs-you entries and leaves every other setting and hook alone,
- doesn't rewrite the file if nothing changed, so it's safe to run from provisioning scripts,
- writes through a symlinked settings file (dotfile managers) and keeps its mode,
- refuses to touch a settings file that isn't valid JSON.

Restart running sessions (or open `/hooks` in Claude Code) to pick up the change.

### Turn it on

The hooks are installed everywhere but do nothing unless the session is opted in, so ordinary interactive use stays quiet:

| Condition | Effect |
|---|---|
| `$ORCA_TERMINAL_HANDLE` is set (Orca started the session) | on |
| `NEEDS_YOU_AGENT_ALERTS=1` in the environment | on |
| `NEEDS_YOU_AGENT_ALERTS=1` as a line in `~/.config/needs-you/env` | on for every session on this machine (good for headless VMs) |
| `NEEDS_YOU_AGENT_ALERTS=0` | off, even inside Orca |

```bash
# just this session
NEEDS_YOU_AGENT_ALERTS=1 claude

# this whole VM
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env
```

### What gets posted

| Claude Code event | Hook action |
|---|---|
| `Notification` with `notification_type` `permission_prompt`, `idle_prompt`, `elicitation_dialog`, `elicitation_url_dialog` or `agent_needs_input` | `needs-you add` (kind `needs`) |
| `UserPromptSubmit`, `PostToolUse`, `Stop`, `SessionEnd` | `needs-you resolve`, only if this session posted something |

- **Key:** `agent:<short-hostname>:<id>`, where `<id>` is `$ORCA_TERMINAL_HANDLE` if set, else the Claude `session_id`. Characters outside `A-Za-z0-9._-` become `_`. Re-posting the same key updates the item, so a session that asks five times shows one card.
- **Title:** what's needed plus the project, e.g. `Claude needs permission: my-repo` or `Claude is waiting for you: my-repo`. The project is the basename of `$CLAUDE_PROJECT_DIR` (else `cwd`).
- **Body:** Claude's notification message (trimmed to 400 characters), the working directory and host, where the session runs (the tmux pane as `session:window.pane` plus `tmux attach -t <session>`, `VS Code`, or `SSH`), and the short session id. In Orca, instead: the worktree path (from `$ORCA_WORKTREE_ID`) and the command that jumps to the terminal, `orca terminal switch --terminal <handle>` (plus `--environment <name>` when `NEEDS_YOU_ORCA_ENVIRONMENT` is set). No prompt text, transcript or tool input is sent.
- **Links:** in Orca, a **Terminal** link, `needsyou://orca/terminal?handle=<handle>[&environment=<name>]`, which the Mac app shows as a button that runs the same switch and brings Orca forward. A hub too old to accept it gets the card without it.
- **Source:** `--agent claude-code --project <project>`; the CLI adds the host.

The resolve side keeps a marker file per session in `~/.local/state/needs-you/claude-hooks/`, so `Stop` and `PostToolUse` (which fire constantly) cost a file check and no network call unless there is something to resolve.

A killed session (closed terminal, `kill`, reboot, OOM) never sends `SessionEnd`, so two things clean up after it:

- **Lease:** the marker records the key, the Claude process id and its start time. `needs-you flush`, which the installer schedules every 5 minutes, resolves the card once that process is gone or its pid belongs to a newer process. Markers written by older hooks have no lease and are left alone.
- **Expiry:** each card expires 48 hours after its last post (`NEEDS_YOU_AGENT_EXPIRY_HOURS`), for a machine that never comes back to run the flush. A gated-off event costs about 5 ms of bash and never starts Python.

### Settings

Set these in the environment or as lines in `~/.config/needs-you/env` (the environment wins):

| Variable | Default | Meaning |
|---|---|---|
| `NEEDS_YOU_AGENT_ALERTS` | unset | `1` opts in, `0` opts out (see above) |
| `NEEDS_YOU_AGENT_CONTEXT` | `NEEDS_YOU_DEFAULT_CONTEXT`, else `work` | `work` or `personal` |
| `NEEDS_YOU_AGENT_PRIORITY` | `normal` | `urgent`, `normal` or `low` |
| `NEEDS_YOU_AGENT_LINK` | unset | One link, `Label=url-template`. Placeholders: `{handle}`, `{session}`, `{cwd}`, `{host}` (URL-encoded). A template using `{handle}` is skipped outside Orca. |
| `NEEDS_YOU_AGENT_EXPIRY_HOURS` | `48` | A card expires this many hours after its last post; `0` never expires |
| `NEEDS_YOU_ORCA_ENVIRONMENT` | unset | On a paired Orca server: the name the Mac's Orca gives it (`orca environment list`), so the jump command finds the terminal |
| `NEEDS_YOU_BIN` | `needs-you` on `PATH`, else `~/.local/bin/needs-you` | CLI path |
| `NEEDS_YOU_HOOK_LOG` | unset | Append one debug line per call to this file |

Link examples:

```bash
# Orca cards already get a Terminal button (needsyou://orca/terminal?...);
# Orca itself has no terminal or worktree deep link (1.4.220).

# Open the folder in VS Code or Cursor on the Mac (only useful if the path exists there)
NEEDS_YOU_AGENT_LINK='VS Code=vscode://file{cwd}'
```

### Guarantees

- Every hook exits 0 and writes nothing to stdout, so it can never block a tool call, stop Claude from stopping, or inject text into the conversation.
- Every hook is registered with `"async": true` and a 30 s timeout, so Claude never waits on the network. The CLI itself queues to its outbox when no hub answers.
- Untrusted text (Claude's message, paths) is passed to the CLI as an argument list from Python, never through shell quoting.

### Doing it by hand

`hooks.json` is the exact block the installer merges, with user-level paths. To install manually: copy `needs-you-hook.sh` to `~/.claude/hooks/`, `chmod +x` it, and merge the `hooks` object into `~/.claude/settings.json`, appending to any event arrays you already have.

### Troubleshooting

```bash
# Simulate a permission prompt (fake session id)
echo '{"session_id":"test-1","cwd":"'"$PWD"'","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}' |
  NEEDS_YOU_AGENT_ALERTS=1 NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.claude/hooks/needs-you-hook.sh notify

# ...and its resolve
echo '{"session_id":"test-1"}' |
  NEEDS_YOU_AGENT_ALERTS=1 NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.claude/hooks/needs-you-hook.sh resolve
```

If nothing shows up, see [troubleshooting](../../docs/guides/troubleshooting.md#claude-code-hooks).

## Skill

```bash
mkdir -p ~/.claude/skills
cp -R integrations/claude-code/skill/needs-you ~/.claude/skills/
```

Or put it in one repo at `<repo>/.claude/skills/needs-you/`. Claude loads it when it's blocked on you or finishing something you're waiting for. It's a condensed [`docs/AGENT-GUIDE.md`](../../docs/AGENT-GUIDE.md). If your project uses its own key prefixes (for example `acme:` for work items), say so in the repo's `CLAUDE.md`.
