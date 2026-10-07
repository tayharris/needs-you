# Claude Code

needs-you gives Claude Code two pieces, for any repo or VM, with or without Orca:

- **Hooks:** a card appears when a Claude Code session is waiting on you (a permission prompt, a plan to approve, a question, idle waiting for input, or stopped on an API error) and clears itself when the session moves again. A low-priority card suggests `/compact` or `/clear` when a session's context is filling up.
- **Skill:** teaches the agent to post specific blockers ("choose A or B for ACME-123") and to resolve them.

This page covers what gets installed and where, what each hook posts, how to check it, and how to turn it off or remove it. Sessions over SSH, in tmux, VS Code Remote-SSH or Orca: [claude-code-everywhere.md](claude-code-everywhere.md). The hook's internals: [integrations/claude-code/README.md](../../integrations/claude-code/README.md).

## Install

The quickest route is an invite link. Paste the link's agent prompt into Claude Code, or run:

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --claude-hooks user --skill --alerts
```

The three Claude Code options are independent ([all installer options](add-a-sender.md#options)):

| Option | What it does |
|---|---|
| `--claude-hooks user` | Installs the hooks for every Claude Code session of this user. `project` installs them into the current directory's repo instead; `none` (the default) skips them. |
| `--alerts` | Turns the hooks on for every session here. Without it they stay quiet, except in Orca terminals ([Turning the hooks on](#turning-the-hooks-on)). |
| `--skill` | Installs the skill. |

### What `--claude-hooks user` writes

The installer downloads `install-hooks.sh`, `needs-you-hook.sh` and `hooks.json` from the hub (each checked against the sha256 on the join page) and runs `install-hooks.sh --user`. Everything lands under your home directory:

| File | What changes |
|---|---|
| `~/.claude/hooks/needs-you-hook.sh` | The hook script (bash, plus python3 to build cards), mode 755. |
| `~/.claude/settings.json` | Eight hook entries merged into `"hooks"` (below). Other settings and hooks are left alone, earlier needs-you entries are replaced, and an unchanged file isn't rewritten. |
| `~/.claude/settings.json.bak-<timestamp>` | A copy of the settings file from before the change (only when one existed). |
| `~/.local/state/needs-you/update.json` | Records which `hooks.json` was merged, so `needs-you doctor` and `needs-you update` know the entries are current. |

With `--alerts`, the installer also writes `NEEDS_YOU_AGENT_ALERTS=1` into `~/.config/needs-you/env`. With `--skill`, it writes `~/.claude/skills/needs-you/SKILL.md`. Restart open Claude Code sessions (or open `/hooks` in them) to pick up the hooks.

`--claude-hooks project` writes the same into the current directory instead: `./.claude/hooks/needs-you-hook.sh` and `./.claude/settings.json`, with commands that start `"$CLAUDE_PROJECT_DIR/.claude/hooks/..."` so the file works for everyone who clones the repo once it's committed. `needs-you update` and `needs-you doctor` only look at the user-level install.

`scripts/setup-sender.sh` (the manual sender setup) doesn't install the hooks. It writes the same settings (`--alerts` and the rest) to the env file and tells you to run `integrations/claude-code/install-hooks.sh`.

### Without an invite: from a checkout

On a machine that's already a sender (`needs-you` works in a shell there):

```bash
integrations/claude-code/install-hooks.sh                                  # every repo (user level)
integrations/claude-code/install-hooks.sh --project ~/src/my-repo          # one repo, committed
integrations/claude-code/install-hooks.sh --project ~/src/my-repo --local  # one repo, just you (settings.local.json)
integrations/claude-code/install-hooks.sh --dry-run                        # show the diff, write nothing
```

## The hooks

Every entry runs `needs-you-hook.sh` with one argument, `"async": true` and a 30-second timeout:

| Claude Code event | Hook runs | What it does |
|---|---|---|
| `Notification`, types `permission_prompt`, `idle_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input`, `quota_auto_resume_disabled` | `notify` | Posts the session's card. A `permission_prompt` or `idle_prompt` doesn't replace a more specific card from `PermissionRequest`. |
| `PermissionRequest` (any tool) | `notify` | Posts the session's card, titled by the tool: plan approval, a question, the program a command runs, the file an edit changes. Skipped when the request doesn't need your approval. |
| `StopFailure` | `notify` | Posts the session's card, titled by the API error. |
| `UserPromptSubmit`, `PostToolUse` | `resolve` | Resolves the session's card, if it posted one. |
| `Stop` | `stop` | Resolves the session's card (except an API-error card), then checks how full the context is and posts, updates or resolves the context card. |
| `SessionStart` | `start` | Remembers the model. After `/clear`, compaction or `/resume`, resolves the earlier cards of this Claude process and its context card. |
| `SessionEnd` | `end` | Resolves the session's card and its context card. |

### What you'll see

| Session state | Card title |
|---|---|
| Permission prompt for a command | **Claude wants to run git: my-repo** |
| Permission prompt for an edit | **Claude wants to edit config.yml: my-repo** |
| Plan ready (plan mode, `ExitPlanMode`) | **Approve Claude's plan: my-repo** |
| Claude asks you a question (`AskUserQuestion`) | **Claude asked you a question: my-repo** |
| Any other permission prompt | **Claude needs permission for <tool>: my-repo** (MCP tools as `<server> <tool>`) |
| Idle, waiting for your input | **Claude is waiting for you: my-repo** |
| MCP server asks for input / a sign-in | **Claude needs an answer: my-repo** / **Claude needs you to sign in: my-repo** |
| Claude Code's `agent_needs_input` notification | **Agent needs input: my-repo** |
| Usage limit, won't resume on its own | **Claude hit its usage limit: my-repo** |
| Turn ended on an API error | **Claude hit a rate limit**, **Claude needs you to sign in again**, **Claude stopped on a billing problem**, **Claude stopped on an API error**, ... |
| Context at 80% or more (low priority, a card of its own) | **Claude's context is 85% full: my-repo**, suggesting `/compact` or `/clear` |

`my-repo` is the basename of the project directory. Cards are kind `needs`, priority `normal` (the context card `low`), context `work` unless you set otherwise, and carry `--agent claude-code`.

The body holds Claude's notification text, the directory and host, and where the session runs (tmux pane, VS Code, SSH, or the Orca worktree and its `orca terminal switch` command). No prompts, transcript or tool input are sent: a permission card names at most the program or the file's basename. Cards get buttons where the hook can name the place: the Mac terminal tab, the folder in VS Code on the Mac, a Remote-SSH window with `NEEDS_YOU_SSH_ALIAS`, the Claude tab for VS Code extension sessions, or the Orca terminal ([details](claude-code-everywhere.md#buttons)).

### One card per session, cleared on its own

- **Keys:** `agent:<host>:<session>` for the session's card, `agent:<host>:<session>:context` for the context card. `<session>` is the Orca terminal handle in Orca, otherwise Claude's session id. Re-posting updates the card, so a session that asks five times shows one card.
- **Cleared** on your next prompt, the next tool call, the end of the turn (an API-error card waits for your next prompt), `/clear`, `/compact`, `/resume`, or the end of the session. The context card clears once the context is back under the threshold.
- **Killed sessions** never send `SessionEnd`. The hook records the Claude process id in `~/.local/state/needs-you/claude-hooks/`; the 5-minute `needs-you flush` the installer schedules resolves the card once that process is gone. As a backstop, every card expires 48 hours after its last post ([details](claude-code-everywhere.md#when-a-session-dies)).

The hooks always exit 0 and print nothing, so they can't block a tool call, keep Claude from stopping, or put text into the conversation. When no hub answers, the CLI queues the post and the flush sends it later.

## Turning the hooks on

Installed hooks do nothing until a session is opted in, so everyday interactive use stays quiet. A session that isn't opted in costs one bash check and never starts Python or touches the network.

| Setting | Effect |
|---|---|
| `NEEDS_YOU_AGENT_ALERTS=1` in the session's environment | on for that session |
| `NEEDS_YOU_AGENT_ALERTS=1` as a line in `~/.config/needs-you/env` (what `--alerts` writes) | on for every session on this machine |
| `$ORCA_TERMINAL_HANDLE` set (Orca started the session) | on |
| `NEEDS_YOU_AGENT_ALERTS=0` | off, even in Orca |

```bash
NEEDS_YOU_AGENT_ALERTS=1 claude      # one session
```

The environment wins over the file. The hooks read the same env file as the CLI: `$XDG_CONFIG_HOME/needs-you/env` when `XDG_CONFIG_HOME` is set (`~/.config/needs-you/env` otherwise), or the file `NEEDS_YOU_CONFIG` names; `NEEDS_YOU_ENV_FILE` points only the hooks somewhere else. A good pattern: leave it off on your laptop, turn it on for the VMs where agents run unattended.

## Options

Set in the environment or as lines in `~/.config/needs-you/env`:

```bash
NEEDS_YOU_AGENT_CONTEXT=personal      # default: NEEDS_YOU_DEFAULT_CONTEXT, else work
NEEDS_YOU_AGENT_PRIORITY=low          # urgent | normal | low; default normal
NEEDS_YOU_AGENT_LINK='Cursor=cursor://file{cwd}'     # one link instead of the automatic ones; none = no editor links
NEEDS_YOU_SSH_ALIAS=devbox            # this host's name in the Mac's ~/.ssh/config: a Remote-SSH button
NEEDS_YOU_CONTEXT_ALERT_PCT=80        # context card threshold in percent; 0 = off
NEEDS_YOU_CONTEXT_WINDOW=200000       # default 200000, 1000000 for a [1m] model
NEEDS_YOU_AGENT_EXPIRY_HOURS=48       # a card expires this long after its last post; 0 = never
NEEDS_YOU_ORCA_ENVIRONMENT='My Devbox'                # paired Orca server: its name in the Mac's Orca
NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log   # one debug line per hook call
```

The invite installer writes some of these for you: `--context-alert` (`NEEDS_YOU_CONTEXT_ALERT_PCT`), `--ssh-alias`, `--agent-link`, `--orca-environment`, and `--context` (`NEEDS_YOU_DEFAULT_CONTEXT`, which the cards follow unless `NEEDS_YOU_AGENT_CONTEXT` is set).

## The skill

The hooks only say *that* a session is waiting. The skill teaches Claude to post *what* it needs: a specific blocker with its options and links, or a `done` note when a long job you're waiting on finishes. It uses `needs-you add` / `resolve` / `done` with the rules from [AGENT-GUIDE.md](../AGENT-GUIDE.md): stable keys, the title is the action, link to where you act, no secrets, resolve what you post, no progress updates. It knows the hooks already cover permission prompts and waiting, and doesn't duplicate them.

`--skill` installs it to `~/.claude/skills/needs-you/SKILL.md`. By hand, from a checkout:

```bash
mkdir -p ~/.claude/skills
cp -R integrations/claude-code/skill/needs-you ~/.claude/skills/     # or <repo>/.claude/skills/ for one repo
```

Tell it your conventions in the repo's `CLAUDE.md`, for example:

```markdown
needs-you: use key prefix `acme:` and context `work` for this repo.
```

## Check it works

```bash
needs-you doctor
```

It's read-only and never posts. The two Claude Code lines:

| Line | OK means | Otherwise |
|---|---|---|
| `claude hooks` | `~/.claude/hooks/needs-you-hook.sh` exists, is executable and current, and `~/.claude/settings.json` references it. The line also says whether alerts are on (and where that's set), the context alert threshold, and any SSH alias or link template. | `INFO` not installed; `WARN` with the problem (script missing, not executable, not referenced, or an old hook) and the command to re-run. If alerts are off, the hint gives the line to turn them on. |
| `claude skill` | `~/.claude/skills/needs-you/SKILL.md` exists. | `INFO` not installed (optional). |

`needs-you doctor --json` prints the same for an agent. Then post a fake permission prompt and clear it:

```bash
echo '{"session_id":"test-1","cwd":"'"$PWD"'","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.claude/hooks/needs-you-hook.sh notify
# a card "Claude needs permission: <this folder>" appears; then:
echo '{"session_id":"test-1"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.claude/hooks/needs-you-hook.sh resolve
```

Add `NEEDS_YOU_HOOK_LOG=/dev/stderr` to either line to see what the hook did. Not working? [troubleshooting.md](troubleshooting.md#claude-code-hooks).

## Turn it off or uninstall

| To | Do |
|---|---|
| Quiet one session | Start it with `NEEDS_YOU_AGENT_ALERTS=0 claude`. |
| Quiet every session here, keep the hooks | Set `NEEDS_YOU_AGENT_ALERTS=0` in `~/.config/needs-you/env` (or delete the `=1` line; Orca sessions then still post). |
| Stop only the context card | `NEEDS_YOU_CONTEXT_ALERT_PCT=0` in the env file. |
| Remove the hooks | `integrations/claude-code/install-hooks.sh --uninstall` from a checkout (add `--project DIR [--local]` for a project install). It backs up `settings.json`, removes only the needs-you entries, and deletes `~/.claude/hooks/needs-you-hook.sh` unless another settings file next to it still uses it. Restart open sessions. |
| Remove the skill | `rm -rf ~/.claude/skills/needs-you` |
| Remove everything needs-you put on this machine | `curl -fsSL <join_url>/install.sh \| bash -s -- --uninstall` with any invite link from this hub that hasn't expired or been revoked: the CLI, the env file, the flush schedule, the PATH line, the state directory, the skill and the user-level hooks. |

Without a checkout, fetch the uninstaller from your hub:

```bash
. ~/.config/needs-you/env; d=$(mktemp -d)
curl -fsS "$NEEDS_YOU_URL/dl/install-hooks.sh" -o "$d/install-hooks.sh"
bash "$d/install-hooks.sh" --uninstall; rm -rf "$d"
```

The invite installer's `--uninstall` downloads the same script from the hub to remove the hooks. If the hub doesn't answer, it says so and leaves the hooks in place; remove them with one of the commands above. It doesn't touch project-level installs. Then revoke the machine's token ([Removing a sender](add-a-sender.md#removing-a-sender)).
