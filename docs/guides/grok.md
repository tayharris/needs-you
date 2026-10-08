# Grok Build

A card appears on your Mac when a Grok Build session needs you: it asks for permission to run a tool, or it finished its turn and has waited a minute for your next message. The card clears itself when you answer, the next tool runs, you send your next prompt, or the session ends.

This is for **Grok Build**, xAI's `grok` command (`~/.grok`), not the community `grok-cli` (npm `grok-dev`).

Quickest: add `--grok-hooks user --alerts` to an invite link's one-liner (or paste the link's agent prompt into Grok; it names the flag):

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --grok-hooks user --alerts
```

Then restart running Grok sessions: Grok reads its hooks when it starts. Reference: [integrations/grok/README.md](../../integrations/grok/README.md).

## Grok and the Claude Code hooks

Grok also runs the Claude Code hooks from `~/.claude/settings.json` (on by default). So on a machine with needs-you's Claude Code hooks, Grok sessions already get cards, labelled Grok. You still get **one card per wait** either way:

- **With `--grok-hooks`:** Grok's own hooks post, and the Claude Code hooks do nothing in a Grok session.
- **Without it:** the Claude Code hooks post for Grok. `needs-you doctor`'s `grok hooks` line says so.

Install `--grok-hooks` on a machine that runs Grok without Claude Code, or if you turned Grok's Claude compatibility off (`[compat.claude] hooks = false`).

## Manual install

On a sender machine, from a checkout of this repo:

```bash
integrations/grok/install-grok-hooks.sh    # ~/.grok/hooks/needs-you.json (or $GROK_HOME/hooks/)
```

It writes its own file, `needs-you.json`, next to a copy of the hook in `~/.grok/hooks/`, and changes no other file. Grok always trusts hooks there. `--uninstall` removes both, and so does `needs-you uninstall-hooks --grok`, which needs no checkout and no hub.

## Opt in

The same switch as for the other agents:

```bash
NEEDS_YOU_AGENT_ALERTS=1 grok                                # one session
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env   # every session on this machine
```

## What you'll see

| Session state | Card |
|---|---|
| A permission prompt | **Grok needs permission: my-repo** |
| Waiting for your next message, a minute after the turn | **Grok finished: my-repo** |
| The turn failed on an error | **Grok hit a rate limit: my-repo** (or **Grok stopped on an error**) |

Grok gives the hook no text of the turn, so its turn card always says finished. `NEEDS_YOU_TURN_TEXT=0` keeps the old **Grok is waiting for you** card (and no session name).

One card per session, updated in place. Grok's permission notification doesn't say which tool, so neither does the card. The "waiting" card comes from Grok's `idle_prompt` notification, about 60 seconds after the turn ends, as in Claude Code, and not at all if you type first; an open permission card is kept rather than replaced by it. Commands, prompts, Grok's replies and tool output aren't sent. `NEEDS_YOU_AGENT_TURN_CARDS=0` keeps only the permission and error cards. Subagents post nothing; their waits show in the main session.

## Check it works

```bash
needs-you doctor    # the "grok hooks" line should be OK
grok inspect        # lists needs-you's hooks under Hooks
echo '{"hook_event_name":"Notification","notificationType":"permission_prompt","session_id":"test-1","cwd":"'"$PWD"'"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.grok/hooks/needs-you-hook.sh notify grok
echo '{"hook_event_name":"UserPromptSubmit","session_id":"test-1"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.grok/hooks/needs-you-hook.sh resolve grok
```

The card arrives a moment after the first command returns: the hook hands its work to the background so Grok never waits on it. No card from a real session? Restart Grok after installing or updating, check that `NEEDS_YOU_AGENT_ALERTS=1` reaches it, that you didn't switch the hooks off in `/hooks`, and that no organization policy allows only managed hooks (`needs-you doctor` reports both). If you run Grok with `GROK_HOME` set, install with that same `GROK_HOME`. `NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` logs each hook call ([troubleshooting](troubleshooting.md#grok-build-hooks)).
