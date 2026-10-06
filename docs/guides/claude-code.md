# Claude Code

Two pieces, for any repo or VM, with or without Orca:

- **Hooks:** a card appears when a Claude Code session is waiting on you (a permission prompt, or idle waiting for input) and clears itself when the session moves again.
- **Skill:** teaches the agent to post specific blockers ("choose A or B for ACME-4170") and to resolve them.

Prerequisite: the machine is a sender (`./scripts/setup-sender.sh`, see [add-a-sender.md](add-a-sender.md)), so `needs-you` works in a shell there.

Full reference: [integrations/claude-code/README.md](../../integrations/claude-code/README.md).

## Hooks

### Install

```bash
# every repo on this machine
integrations/claude-code/install-hooks.sh

# or one repo, committed so collaborators get it
integrations/claude-code/install-hooks.sh --project ~/src/my-repo

# or one repo, just for you
integrations/claude-code/install-hooks.sh --project ~/src/my-repo --local
```

It backs up the settings file first, only touches its own entries, and is safe to re-run. `--dry-run` shows the change; `--uninstall` removes it. Restart open sessions afterwards.

### Opt in

Installed hooks do nothing until a session is opted in, so everyday interactive use stays quiet:

```bash
NEEDS_YOU_AGENT_ALERTS=1 claude                              # one session
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env   # every session on this machine
```

Sessions started by Orca (`$ORCA_TERMINAL_HANDLE` set) are on automatically. `NEEDS_YOU_AGENT_ALERTS=0` turns it off even there.

A good pattern: leave it off on your laptop, turn it on for the VMs where agents run unattended.

### What you'll see

| Session state | Card |
|---|---|
| Permission prompt | **Claude needs permission: my-repo** |
| Idle, waiting for your input | **Claude is waiting for you: my-repo** |
| MCP server asks for input / sign-in | **Claude needs an answer** / **Claude needs you to sign in** |

Each session has one card (key `agent:<host>:<session>`), updated rather than duplicated. It's resolved on your next prompt, the next tool call, the end of the turn, or the end of the session.

The body holds Claude's notification text, the directory and host. No prompts, transcript or tool input are sent.

### Options

Set in the environment or in `~/.config/needs-you/env`:

```bash
NEEDS_YOU_AGENT_CONTEXT=personal      # default work
NEEDS_YOU_AGENT_PRIORITY=low          # default normal
NEEDS_YOU_AGENT_LINK='Orca=orca://terminal/{handle}'   # one link; orca:// format is unverified
```

## The skill

```bash
mkdir -p ~/.claude/skills
cp -R integrations/claude-code/skill/needs-you ~/.claude/skills/
```

Claude reads it when it's blocked on you or finishing work you're waiting for, and uses `needs-you add` / `resolve` / `done` with the rules from [AGENT-GUIDE.md](../AGENT-GUIDE.md): stable keys, the title is the action, link where you act, no secrets, resolve what you post.

Tell it your conventions in the repo's `CLAUDE.md`, for example:

```markdown
needs-you: use key prefix `acme:` and context `work` for this repo.
```

## Check it works

```bash
echo '{"session_id":"test-1","cwd":"'"$PWD"'","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.claude/hooks/needs-you-hook.sh notify
# card appears; then:
echo '{"session_id":"test-1"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.claude/hooks/needs-you-hook.sh resolve
```

Not working? [troubleshooting.md](troubleshooting.md#claude-code-hooks).
