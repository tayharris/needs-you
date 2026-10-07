# opencode

A card appears on your Mac when an opencode session needs you: it asks for permission to run a command, edit a file, fetch a page or use a folder outside the project, it asks you a question, or it goes idle waiting for your next message. The card clears itself when you reply or the session starts working again.

Quickest: add `--opencode-plugin --alerts` to an invite link's one-liner (or paste the link's agent prompt into opencode; it names the flag):

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --opencode-plugin --alerts
```

Then restart opencode. Reference: [integrations/opencode/README.md](../../integrations/opencode/README.md).

## Manual install

On a sender machine, from a checkout of this repo:

```bash
integrations/opencode/install-opencode-plugin.sh    # ~/.config/opencode/plugins/needs-you.js
```

`--uninstall` removes it. No opencode config file is changed.

## Opt in

```bash
NEEDS_YOU_AGENT_ALERTS=1 opencode                            # one session
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env   # every session on this machine
```

## What you'll see

| Session state | Card |
|---|---|
| Permission for a shell command | **opencode wants to run git: my-repo** |
| Permission for an edit | **opencode wants to edit main.ts: my-repo** |
| A question for you | **opencode asked you a question: my-repo** |
| Idle, waiting for you | **opencode is waiting for you: my-repo** |

One card per session, updated in place. Commands, patterns, questions and answers aren't sent. `NEEDS_YOU_AGENT_TURN_CARDS=0` keeps only the permission and question cards.

## Check it works

```bash
needs-you doctor    # the "opencode plugin" line should be OK
echo '{"hook_event_name":"Stop","session_id":"ses_test","cwd":"'"$PWD"'"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.config/opencode/hooks/needs-you-hook.sh notify opencode
echo '{"session_id":"ses_test"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.config/opencode/hooks/needs-you-hook.sh resolve opencode
```

No card from a real session? Restart opencode after installing or updating, and check that `NEEDS_YOU_AGENT_ALERTS=1` reaches it. `NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` logs each hook call.
