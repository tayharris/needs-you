# GitHub Copilot CLI

A card appears on your Mac when a GitHub Copilot CLI session needs you: it asks for permission to run a command or fetch a page, it asks you a question, or it finished its turn and is waiting for your next message. The card clears itself when you answer, the next tool runs, you send your next prompt, or the session ends.

Quickest: add `--copilot-hooks user --alerts` to an invite link's one-liner (or paste the link's agent prompt into Copilot CLI; it names the flag):

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --copilot-hooks user --alerts
```

Then restart Copilot CLI: it reads its hooks when it starts. Reference: [integrations/copilot/README.md](../../integrations/copilot/README.md).

## Manual install

On a sender machine, from a checkout of this repo:

```bash
integrations/copilot/install-copilot-hooks.sh    # ~/.copilot/hooks/needs-you.json (or $COPILOT_HOME/hooks/)
```

It writes its own file, `needs-you.json`, next to a copy of the hook in `~/.copilot/hooks/`, and changes no other file there. User-level hooks need no trust step. `--uninstall` removes both, and so does `needs-you uninstall-hooks --copilot`, which needs no checkout and no hub.

## Opt in

The same switch as for the other agents:

```bash
NEEDS_YOU_AGENT_ALERTS=1 copilot                             # one session
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env   # every session on this machine
```

## What you'll see

| Session state | Card |
|---|---|
| Permission for a shell command | **Copilot wants to run make: my-repo** |
| Permission to fetch a page | **Copilot wants to fetch a page: my-repo** |
| Any other permission prompt | **Copilot needs your approval: my-repo** |
| A question for you | **Copilot asked you a question: my-repo** |
| Turn finished, waiting for you | **Copilot is waiting for you: my-repo** |

One card per session, updated in place. Command lines, URLs, questions, prompts and tool output aren't sent: a card names at most the program. `NEEDS_YOU_AGENT_TURN_CARDS=0` keeps only the permission and question cards.

If you **cancel** a permission prompt with Esc, Copilot runs no hook, so that card stays until your next prompt or the end of the session.

## Check it works

```bash
needs-you doctor    # the "copilot hooks" line should be OK
echo '{"sessionId":"test-1","cwd":"'"$PWD"'","stopReason":"end_turn"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.copilot/hooks/needs-you-hook.sh notify copilot
echo '{"sessionId":"test-1"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.copilot/hooks/needs-you-hook.sh resolve copilot
```

The card arrives a moment after the first command returns: the hook hands its work to the background so Copilot never waits on it. No card from a real session? Restart Copilot CLI after installing or updating, check that `NEEDS_YOU_AGENT_ALERTS=1` reaches it, and that no `"disableAllHooks": true` is set in `~/.copilot/settings.json` or `config.json` (`needs-you doctor` says so). If you run Copilot with `COPILOT_HOME` set, install with that same `COPILOT_HOME`. `NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` logs each hook call ([troubleshooting](troubleshooting.md#claude-code-hooks) explains the log lines).
