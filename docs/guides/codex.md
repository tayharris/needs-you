# OpenAI Codex CLI

A card appears on your Mac when a Codex CLI session needs you: it asks to run a command, apply an edit or call an MCP tool, or it finished its turn and is waiting for your next message. The card clears itself as soon as you answer or the session moves on.

Quickest: an invite link installs it. Add `--codex-hooks user --alerts` to the link's one-liner, or paste the link's agent prompt into Codex (it names the flag):

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --codex-hooks user --alerts
```

On a machine that runs Claude Code too, add `--claude-hooks user --skill` in the same line. Then **trust the hooks once**: start Codex, open `/hooks`, and trust the needs-you entries. Codex skips hooks nobody has reviewed.

The rest of this page is the manual route and what to expect. Reference: [integrations/codex/README.md](../../integrations/codex/README.md).

## Manual install

Prerequisite: the machine is a sender (an invite link, or `./scripts/setup-sender.sh`), so `needs-you` works in a shell there. From a checkout of this repo:

```bash
integrations/codex/install-codex-hooks.sh     # adds the hooks to ~/.codex/hooks.json ($CODEX_HOME if set)
```

It backs up `hooks.json`, keeps every other hook (Orca's included), and is safe to re-run. `--dry-run` shows the change; `--uninstall` removes it. Then trust them in `/hooks` and restart open Codex sessions.

## Opt in

Installed hooks do nothing until a session is opted in, the same switch as the Claude Code hooks:

```bash
NEEDS_YOU_AGENT_ALERTS=1 codex                               # one session
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env   # every session on this machine (the installer's --alerts)
```

Sessions in an Orca terminal are on automatically; `NEEDS_YOU_AGENT_ALERTS=0` turns it off even there.

## What you'll see

| Session state | Card |
|---|---|
| Approval prompt for a shell command | **Codex wants to run make: my-repo** |
| Approval prompt for an edit | **Codex wants to edit config.py: my-repo** |
| Approval prompt for an MCP tool | **Codex needs permission for linear create_issue: my-repo** |
| Turn finished, waiting for you | **Codex is waiting for you: my-repo** |

One card per session (key `agent:<host>:<session>`), updated rather than duplicated. It's resolved on your next prompt, the next tool run, an interrupt (Esc), `/clear`, or the end of the session. A Codex process that's killed is cleaned up by the 5-minute `needs-you flush`; any card expires 48 hours after its last post.

Cards name at most the program or a file's basename. No command lines, patches, prompts or Codex replies are sent. The buttons are the same as for Claude Code: the Orca terminal, the Mac terminal tab, VS Code folders ([details](claude-code-everywhere.md#buttons)).

Only want approval prompts, not a card at the end of every turn?

```bash
echo 'NEEDS_YOU_AGENT_TURN_CARDS=0' >> ~/.config/needs-you/env
```

## Check it works

```bash
needs-you doctor    # the "codex hooks" line should be OK
echo '{"hook_event_name":"Stop","session_id":"test-1","cwd":"'"$PWD"'"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.codex/hooks/needs-you-hook.sh notify codex
# a "Codex is waiting for you" card appears; then:
echo '{"session_id":"test-1"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.codex/hooks/needs-you-hook.sh resolve codex
```

## Remove it

```bash
needs-you uninstall-hooks --codex                         # offline: no hub, no checkout
integrations/codex/install-codex-hooks.sh --uninstall     # or from a checkout
```

Both take out only the needs-you entries (with a backup of `hooks.json`) and delete the hook copy, and refuse a symlinked `hooks.json` or hook. `needs-you uninstall-hooks` with no option removes every agent's hooks; the invite installer's `--uninstall` runs it.

Not working? [troubleshooting.md](troubleshooting.md#codex-hooks).
