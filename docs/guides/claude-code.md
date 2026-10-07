# Claude Code

Two pieces, for any repo or VM, with or without Orca:

- **Hooks:** a card appears when a Claude Code session is waiting on you (a permission prompt, a plan to approve, a question, idle waiting for input, or stopped on an API error) and clears itself when the session moves again. A low-priority card suggests `/compact` or `/clear` when a session's context is filling up.
- **Skill:** teaches the agent to post specific blockers ("choose A or B for ACME-123") and to resolve them.

Quickest: an invite link installs both and turns them on. Paste the link's agent prompt into Claude Code, or run `curl -fsSL <join_url>/install.sh | bash -s -- --yes --claude-hooks user --skill --alerts` ([add-a-sender.md](add-a-sender.md)). The rest of this page is the manual route and the reference.

Prerequisite for the manual route: the machine is a sender (an invite link, or `./scripts/setup-sender.sh`), so `needs-you` works in a shell there. The commands below run from a checkout of this repo.

Sessions over SSH, in tmux, VS Code Remote-SSH or Orca, and the shortest copy-paste setup: [claude-code-everywhere.md](claude-code-everywhere.md). Full reference: [integrations/claude-code/README.md](../../integrations/claude-code/README.md).

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
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env   # every session on this machine (the installer's --alerts)
```

Sessions started by Orca (`$ORCA_TERMINAL_HANDLE` set) are on automatically. `NEEDS_YOU_AGENT_ALERTS=0` turns it off even there.

A good pattern: leave it off on your laptop, turn it on for the VMs where agents run unattended.

### What you'll see

| Session state | Card |
|---|---|
| Permission prompt for a command or an edit | **Claude wants to run git: my-repo**, **Claude wants to edit config.yml: my-repo** |
| Plan ready (plan mode) | **Approve Claude's plan: my-repo** |
| Asks you a question | **Claude asked you a question: my-repo** |
| Other permission prompt | **Claude needs permission for <tool>: my-repo** |
| Idle, waiting for your input | **Claude is waiting for you: my-repo** |
| MCP server asks for input / sign-in | **Claude needs an answer** / **Claude needs you to sign in** |
| Turn ended on an API error | **Claude hit a rate limit**, **Claude needs you to sign in again**, **Claude stopped on an API error**, ... |
| Usage limit, won't auto-resume | **Claude hit its usage limit: my-repo** |
| Context 80% full (low priority, its own card) | **Claude's context is 85% full: my-repo**, suggesting `/compact` or `/clear` |

Each session has one card (key `agent:<host>:<session>`), updated rather than duplicated. It's resolved on your next prompt, the next tool call, the end of the turn (except an API-error card, which waits for your next prompt), or the end of the session. The context card (`agent:<host>:<session>:context`) resolves once the context is back under the threshold, after `/clear`, `/compact` or `/resume`, and at the end of the session. A session that's killed instead is cleaned up by the 5-minute `needs-you flush` once its Claude process is gone, or expires 48 hours after its last post ([details](claude-code-everywhere.md#when-a-session-dies)).

The body holds Claude's notification text, the directory and host. No prompts, transcript or tool input are sent; a permission card names at most the program or the file's basename. Cards get editor buttons where the hook can name them: the folder in VS Code on the Mac, a Remote-SSH window with `NEEDS_YOU_SSH_ALIAS`, the Claude tab for VS Code extension sessions ([details](claude-code-everywhere.md#buttons)).

### Options

Set in the environment or in `~/.config/needs-you/env`:

```bash
NEEDS_YOU_AGENT_CONTEXT=personal      # default: NEEDS_YOU_DEFAULT_CONTEXT, else work
NEEDS_YOU_AGENT_PRIORITY=low          # default normal
NEEDS_YOU_AGENT_LINK='Cursor=cursor://file{cwd}'     # one link instead of the automatic ones; none = no editor links
NEEDS_YOU_SSH_ALIAS=devbox            # this host's name in the Mac's ~/.ssh/config: a Remote-SSH button
NEEDS_YOU_CONTEXT_ALERT_PCT=80        # context card threshold in percent; 0 = off
NEEDS_YOU_CONTEXT_WINDOW=200000       # default 200000, 1000000 for a [1m] model
NEEDS_YOU_AGENT_EXPIRY_HOURS=48       # a card expires this long after its last post; 0 = never
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
