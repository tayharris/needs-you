# Claude Code

Two pieces, for any repo or VM, with or without Orca:

- **Hooks:** a card appears when a Claude Code session is waiting on you (a permission prompt, or idle waiting for input) and clears itself when the session moves again.
- **Skill:** teaches the agent to post specific blockers ("choose A or B for ACME-123") and to resolve them.

Quickest: an invite link installs both. Paste the link's agent prompt into Claude Code, or run `curl -fsSL <join_url>/install.sh | bash -s -- --yes --claude-hooks user --skill` ([add-a-sender.md](add-a-sender.md)). The rest of this page is the manual route and the reference.

Prerequisite for the manual route: the machine is a sender (an invite link, or `./scripts/setup-sender.sh`), so `needs-you` works in a shell there. The commands below run from a checkout of this repo.

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
NEEDS_YOU_AGENT_CONTEXT=personal      # default: NEEDS_YOU_DEFAULT_CONTEXT, else work
NEEDS_YOU_AGENT_PRIORITY=low          # default normal
NEEDS_YOU_AGENT_LINK='VS Code=vscode://file{cwd}'     # one link, placeholders {handle} {session} {cwd} {host}
NEEDS_YOU_ORCA_ENVIRONMENT='My Devbox'                # paired Orca server: its name in the Mac's Orca
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
# a work-context card appears (prefix NEEDS_YOU_AGENT_CONTEXT=personal for personal); then:
echo '{"session_id":"test-1"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.claude/hooks/needs-you-hook.sh resolve
```

Not working? [troubleshooting.md](troubleshooting.md#claude-code-hooks).
