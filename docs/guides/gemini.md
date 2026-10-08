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
| A question (`ask_user`) | **Gemini asks “Which test runner should the new package use?”: my-repo**, each choice a step |
| A plan to approve | **Gemini wants approval for a plan: my-repo** |
| Turn finished, waiting for you | **Gemini is waiting for you: my-repo** |

One card per session, updated in place. No command lines, diffs, URLs, prompts or replies are sent. A question's text and choices are on the card: the question (cleaned, anything token-shaped redacted, clamped) in the title and body, each choice as a read-only step. Answer in Gemini CLI; ticking a step on the Mac answers nothing. `NEEDS_YOU_AGENT_QUESTIONS=0` keeps question text off the card ([ADR 0009](../adr/0009-questions-on-cards.md)). `NEEDS_YOU_AGENT_TURN_CARDS=0` keeps only the approval cards.

**Trusted folders only.** Gemini CLI runs no hooks at all, the needs-you ones included, in a folder you haven't trusted (folder trust is on by default). Trust a project when Gemini asks, or turn folder trust off with `"security": {"folderTrust": {"enabled": false}}` in `~/.gemini/settings.json`.

If you **deny** an approval (Esc, or "No, suggest changes"), Gemini runs no hook, so that card stays until your next prompt or the end of the session.

## Tell Gemini CLI when to post (optional)

The hooks cover "Gemini CLI is waiting". For the agent to post on its own when it's blocked on you, finished something you're waiting on, or hit something broken, give it the rules the Claude Code skill gives Claude: add `--agent-instructions gemini` to the invite's one line.

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --agent-instructions gemini
```

It appends a marked block (`<!-- needs-you:begin ... -->` to `<!-- needs-you:end -->`) to `~/.gemini/GEMINI.md` (Gemini CLI's global context file; if you renamed it with `context.fileName`, copy the block there). The file is created if it's missing, backed up before it changes, and never written through a symlink. The text is generated from the skill, so the two say the same. `needs-you update` keeps the block current, and `needs-you uninstall-hooks --instructions` takes exactly the block out again (and deletes the file if nothing else is in it). To give Gemini CLI the needs-you tools over MCP as well, see [MCP server](mcp.md).

## Check it works

```bash
needs-you doctor    # the "gemini hooks" line should be OK
echo '{"hook_event_name":"AfterAgent","session_id":"test-1","cwd":"'"$PWD"'"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.gemini/hooks/needs-you-hook.sh notify gemini
echo '{"session_id":"test-1"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.gemini/hooks/needs-you-hook.sh resolve gemini
```

Nothing shows up? Check you trusted the folder (above); `/hooks` in Gemini CLI should list the needs-you entries; `hooksConfig.enabled` must not be `false`; and `NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` logs each call ([troubleshooting](troubleshooting.md#claude-code-hooks) explains the log lines).
