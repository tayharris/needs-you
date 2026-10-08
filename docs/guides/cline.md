# Cline

A card appears on your Mac when a Cline task finishes and is waiting for your next message, or stops on an error. It clears itself when you send a message, cancel, start or resume a task, or the session ends. It works for the Cline VS Code extension and the `cline` CLI.

**Finished tasks only.** Cline runs no hook when it waits for your approval, so you get **no card when Cline asks to run a command or edit a file**: a long task that stops on an approval looks "running" until it finishes.

Quickest: add `--cline-hooks user --alerts` to an invite link's one-liner (or paste the link's agent prompt into an agent on that machine; it names the flag):

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --cline-hooks user --alerts
```

Reference: [integrations/cline/README.md](../../integrations/cline/README.md).

## Manual install

On a sender machine, from a checkout of this repo:

```bash
integrations/cline/install-cline-hooks.sh    # ~/Documents/Cline/Hooks/
```

A Cline hook is an executable named after its event, with no extension, in `~/Documents/Cline/Hooks/` (both the extension and the CLI read it). The installer writes seven small ones (`TaskComplete`, `TaskError`, `UserPromptSubmit`, `TaskCancel`, `TaskStart`, `TaskResume`, `SessionShutdown`) that run a copy of the hook in `~/.config/needs-you/cline/hooks/`. It never replaces a hook file of your own: it skips that event and says so (and stops if your own is `TaskComplete`, since there'd be no card). `--uninstall` removes only its own files, and so does `needs-you uninstall-hooks --cline`, which needs no checkout and no hub.

In VS Code, Cline's **Enable Hooks** setting must be on (it is by default).

## Opt in

VS Code starts Cline's hooks from the editor, not your shell, so put the switch in the env file:

```bash
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env
```

The invite installer's `--alerts` writes that line.

## What you'll see

| Task state | Card |
|---|---|
| Task finished, waiting for you | **Cline finished: my-repo** |
| Task finished on a question to you (VS Code) | **Cline asks: Do you want CI wired up too? · my-repo** |
| Task ended on an error | **Cline stopped on an error: my-repo** |
| Waiting for your approval | none (Cline has no hook for it) |

A finished turn's card names the session when the agent gives it a name, and when the turn's last message ends on a question to you, the card is that question instead: **Cline asks: Should I push the branch? · my-repo** (cleaned, token-shaped text redacted, clamped). `NEEDS_YOU_TURN_TEXT=0` keeps the old **Cline is waiting for you** card with no name or question.

One card per task (Cline's `taskId`). Starting or resuming a task clears the cards of earlier tasks in the same Cline. Cline's final answer, which it hands to the hook, and your prompts aren't sent. Subagent runs post nothing, and neither does a one-shot `cline "task"`: it has exited, so nobody is waiting. `NEEDS_YOU_AGENT_TURN_CARDS=0` turns the finished cards off.

The `cline` CLI's interactive sessions run in a background hub process that outlives the terminal, so a card from a session you then quit stays until your next task, the hub process stops, or 48 hours pass.

## Check it works

```bash
needs-you doctor    # the "cline hooks" line should be OK
echo '{"taskId":"test-1","hookName":"agent_end","workspaceRoots":["'"$PWD"'"]}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/Documents/Cline/Hooks/TaskComplete
echo '{"taskId":"test-1","hookName":"prompt_submit"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/Documents/Cline/Hooks/UserPromptSubmit
```

The card arrives a couple of seconds after the first command returns (the hook works in the background, so Cline never waits on it) and goes after the second. Add `NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` to log what the hook does ([troubleshooting](troubleshooting.md#cursor-cline-and-aider)).

Tested live with the Cline CLI 3.0.69 against a local model stub; the VS Code extension uses the same hook files.
