# Gemini CLI

A card appears on your Mac when a Gemini CLI session needs you: it asks to approve a shell command, an edit, an MCP tool or a web fetch, or it finished its turn and is waiting for your next message. The card clears itself when you send the next prompt, a tool runs, or the session ends.

Quickest: add `--gemini-hooks user --alerts` to an invite link's one-liner (or paste the link's agent prompt into Gemini CLI; it names the flag):

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --gemini-hooks user --alerts
```

Restart open Gemini CLI sessions afterwards. Reference: [integrations/gemini/README.md](../../integrations/gemini/README.md).

## Manual install

On a sender machine, from a checkout of this repo:

```bash
integrations/gemini/install-gemini-hooks.sh     # adds the hooks to ~/.gemini/settings.json
```

It backs up `settings.json` and keeps your other settings and hooks. If your `settings.json` has comments, it stops without changing anything; merge `integrations/gemini/gemini-hooks.json` by hand. `--uninstall` removes it, and so does `needs-you uninstall-hooks --gemini`, which needs no checkout and no hub.

## Opt in

The same switch as for Claude Code and Codex:

```bash
NEEDS_YOU_AGENT_ALERTS=1 gemini                              # one session
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env   # every session on this machine
```

## What you'll see

| Session state | Card |
|---|---|
| Approve a shell command | **Gemini wants to run npm: my-repo** |
| Approve an edit | **Gemini wants to edit app.py: my-repo** |
| Approve an MCP tool | **Gemini needs permission for github create_pr: my-repo** |
| Approve a web fetch | **Gemini wants to fetch a page: my-repo** |
| Turn finished, waiting for you | **Gemini is waiting for you: my-repo** |

One card per session, updated in place. No command lines, diffs, URLs, prompts or replies are sent. `NEEDS_YOU_AGENT_TURN_CARDS=0` keeps only the approval cards.

## Check it works

```bash
needs-you doctor    # the "gemini hooks" line should be OK
echo '{"hook_event_name":"AfterAgent","session_id":"test-1","cwd":"'"$PWD"'"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.gemini/hooks/needs-you-hook.sh notify gemini
echo '{"session_id":"test-1"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.gemini/hooks/needs-you-hook.sh resolve gemini
```

Nothing shows up? `/hooks` in Gemini CLI should list the needs-you entries; `hooksConfig.enabled` must not be `false`; and `NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` logs each call ([troubleshooting](troubleshooting.md#claude-code-hooks) explains the log lines).
