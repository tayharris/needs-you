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

`--uninstall` removes it, and so does `needs-you uninstall-hooks --opencode`, which needs no checkout and no hub (it leaves a symlinked plugin alone). No opencode config file is changed.

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

## Tell opencode when to post (optional)

The hooks cover "opencode is waiting". For the agent to post on its own when it's blocked on you, finished something you're waiting on, or hit something broken, give it the rules the Claude Code skill gives Claude: add `--agent-instructions opencode` to the invite's one line.

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --agent-instructions opencode
```

It appends a marked block (`<!-- needs-you:begin ... -->` to `<!-- needs-you:end -->`) to `~/.config/opencode/AGENTS.md` (opencode's global rules; once that file exists, opencode stops falling back to `~/.claude/CLAUDE.md`). The file is created if it's missing, backed up before it changes, and never written through a symlink. The text is generated from the skill, so the two say the same. `needs-you update` keeps the block current, and `needs-you uninstall-hooks --instructions` takes exactly the block out again (and deletes the file if nothing else is in it). To give opencode the needs-you tools over MCP as well, see [MCP server](mcp.md).

## Check it works

```bash
needs-you doctor    # the "opencode plugin" line should be OK
echo '{"hook_event_name":"Stop","session_id":"ses_test","cwd":"'"$PWD"'"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.config/opencode/hooks/needs-you-hook.sh notify opencode
echo '{"session_id":"ses_test"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.config/opencode/hooks/needs-you-hook.sh resolve opencode
```

No card from a real session? Restart opencode after installing or updating, and check that `NEEDS_YOU_AGENT_ALERTS=1` reaches it. `NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` logs each hook call.
