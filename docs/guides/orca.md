# Orca

Orca runs agents in worktrees and scheduled automations. needs-you gives both a way to reach you when they stop on something only you can do.

Prerequisite: the machine running Orca is a sender ([add-a-sender.md](add-a-sender.md)) and `needs-you` is on the `PATH` that Orca terminals get. Check from an Orca terminal: `command -v needs-you`.

## Agent sessions: install the Claude Code hooks

```bash
integrations/claude-code/install-hooks.sh
```

That's all. Orca sets `$ORCA_TERMINAL_HANDLE` in its terminals, which switches the hooks on for those sessions only. When an agent hits a permission prompt or sits idle, a card appears keyed `agent:<host>:<terminal handle>`; it clears when the agent moves again. Details: [claude-code.md](claude-code.md).

To add a link back to the terminal:

```bash
echo "NEEDS_YOU_AGENT_LINK='Orca=orca://terminal/{handle}'" >> ~/.config/needs-you/env
```

> The `orca://` deep-link format is **unverified**. Test one with `open 'orca://...'` on the Mac before relying on it, and drop the link if it doesn't open anything.

## Automations: add a prompt block

Automations are agent prompts on a schedule, so the change is text: tell the agent when to `needs-you add`, `resolve` and `done`. [integrations/orca/README.md](../../integrations/orca/README.md) has copy-paste blocks for:

- a shared **preamble** with the posting rules,
- a **ticket fixer** (e.g. an hourly "Redo" fixer): one item per blocked ticket, resolved when the ticket moves, plus a `done` summary,
- a **worktree cleanup**: one item per branch it won't delete, with a state-file reconcile so items from earlier runs get resolved,
- a **session/memory reaper**: urgent item only on anomalies,
- **automation failure** reporting.

If your automations are rendered from templates, edit the templates, not the live prompts.

Keep setting the board status (`orca worktree set --workspace-status ... --comment ...`) as before. needs-you is the alert; the board is the record.

## Check it works

From an Orca terminal:

```bash
needs-you add --key "work:orca-test:hello" --context work --title "Orca can reach needs-you" --agent "orca:test"
needs-you resolve --key "work:orca-test:hello"
```

Then run one automation by hand (`orca automations run ...`) and watch for its card.
