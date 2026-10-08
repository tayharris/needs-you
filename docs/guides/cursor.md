# Cursor

A card appears on your Mac when a Cursor agent finishes its turn and is waiting for your next message, or stops on an error. It clears itself when you send your next prompt or the chat ends.

**Finished turns only.** Cursor has no hook for "the agent is waiting for your approval", so you get **no card when Cursor asks to run a command or edit a file**: only when the turn is over. Cursor shows its own notification for approvals.

Quickest: add `--cursor-hooks user --alerts` to an invite link's one-liner (or paste the link's agent prompt into an agent on that machine; it names the flag):

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --cursor-hooks user --alerts
```

Cursor picks up the change by itself. Reference: [integrations/cursor/README.md](../../integrations/cursor/README.md).

## Manual install

On a sender machine, from a checkout of this repo:

```bash
integrations/cursor/install-cursor-hooks.sh    # merges into ~/.cursor/hooks.json
```

It backs up `~/.cursor/hooks.json`, adds three entries (`stop`, `beforeSubmitPrompt`, `sessionEnd`) next to your own hooks, and copies the hook to `~/.cursor/hooks/needs-you-hook.sh`. It never registers a permission hook such as `preToolUse` or `beforeShellExecution`: Cursor blocks the action when one of those prints nothing. `--uninstall` takes the entries out again, and so does `needs-you uninstall-hooks --cursor`, which needs no checkout and no hub.

## Opt in

Cursor starts hooks from the app, not your shell, so put the switch in the env file:

```bash
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env
```

The invite installer's `--alerts` writes that line.

## What you'll see

| Agent state | Card |
|---|---|
| Turn finished, waiting for you | **Cursor finished: my-repo** (Cursor's hook carries no text of the turn, so never a question) |
| Turn ended on an error | **Cursor stopped on an error: my-repo** |
| Waiting for your approval | none (Cursor has no hook for it) |

One card per chat (Cursor's `conversation_id`), updated in place. Prompts, your email address (which Cursor sends to every hook) and the transcript aren't sent. A turn you stopped yourself posts nothing. On the Mac the card has a **Cursor** button that opens the project. `NEEDS_YOU_AGENT_TURN_CARDS=0` turns the finished cards off (which leaves only errors).

**Your Claude Code hooks.** Cursor also runs the hooks in `~/.claude/settings.json` (Settings → Agents → Third-Party Imports, on by default). Given a Cursor payload they now exit at once, so they neither post nor clear the Cursor card. You don't need to change anything.

## Check it works

```bash
needs-you doctor    # the "cursor hooks" line should be OK
cd ~/.cursor && echo '{"conversation_id":"test-1","hook_event_name":"stop","status":"completed","workspace_roots":["/tmp/my-repo"]}' |
  NEEDS_YOU_AGENT_ALERTS=1 ./hooks/needs-you-hook.sh notify cursor
echo '{"conversation_id":"test-1","hook_event_name":"beforeSubmitPrompt"}' | NEEDS_YOU_AGENT_ALERTS=1 ./hooks/needs-you-hook.sh resolve cursor
```

The first command prints `{}` and the second `{"continue":true}` (Cursor reads a hook's output as its answer); the card arrives and goes a moment later. No card from a real chat? Check that `NEEDS_YOU_AGENT_ALERTS=1` is in the env file and that `~/.cursor/hooks.json` still has the three needs-you entries. In the `cursor-agent` CLI, one-shot `-p` runs post nothing: the agent has exited, so nobody is waiting. Add `NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` to the test commands above to log what the hook does ([troubleshooting](troubleshooting.md#cursor-cline-and-aider)).

Tested against Cursor's documented hook payloads, not a live Cursor session (that needs a Cursor login).
