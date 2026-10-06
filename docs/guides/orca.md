# Orca

Orca runs agents in worktrees and scheduled automations, often on several servers. needs-you gives every one of them a way to reach you when it stops on something only you can do, without you watching their terminals.

## Several Orca servers: one link

Make one invite with a use per server. In the Mac app: right-click the pill → **Settings…** → **Invite a machine**, **Uses** = the number of servers. On a server hub:

```bash
needs-you-admin invite create orca --role sender --uses 4 --ttl 72
```

Then on each Orca server, paste the agent prompt into an Orca terminal, or run:

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --claude-hooks user --skill --orca
```

Each server redeems the same link and gets **its own token**, named `orca-<hostname>` (e.g. `orca-build-1`, `orca-build-2`). Revoke one server without touching the others: **Settings… → Access** in the Mac app, or `needs-you-admin token revoke orca-build-2` on a server hub ([add-a-sender.md → Removing a sender](add-a-sender.md#removing-a-sender)). Running the installer again on a server keeps its token without spending a use, until the link expires (also after its last use is spent); give provisioning scripts a link with a long enough expiry (up to 90 days).

What the flags give you:

| Flag | Effect on an Orca server |
|---|---|
| `--claude-hooks user` | Agent sessions that Orca starts post a card when they wait on a permission prompt or input, and clear it when they move again. Orca sets `$ORCA_TERMINAL_HANDLE`, which switches the hooks on for its sessions only. |
| `--skill` | Agents know when and how to post a specific blocker ("choose A or B for ACME-123") and to resolve it. |
| `--orca` | Writes the automation prompt block to `~/.config/needs-you/orca-snippet.md` and prints it. |

The installer also adds a 5-minute `needs-you flush`, so alerts raised while your Mac sleeps arrive when it wakes.

Check from an Orca terminal on each server: `command -v needs-you` (if it's missing, `~/.local/bin` isn't on the PATH Orca gives agents; add it, or set `NEEDS_YOU_BIN`).

## Agent sessions

With the hooks installed, nothing else is needed. Cards are keyed `agent:<host>:<terminal handle>`, so agents on different servers never collide. To link back to the terminal:

```bash
echo "NEEDS_YOU_AGENT_LINK='Orca=orca://terminal/{handle}'" >> ~/.config/needs-you/env
```

> The `orca://` deep-link format is **unverified**. Test one with `open 'orca://...'` on the Mac before relying on it, and drop the link if it doesn't open anything.

## Automations: add the prompt block

Automations are agent prompts on a schedule, so the change is text: paste the block from `--orca` into each automation prompt (or the template they're rendered from). [integrations/orca/README.md](../../integrations/orca/README.md) has per-automation versions:

- a **ticket fixer** (e.g. an hourly "Redo" fixer): one item per blocked ticket, resolved when the ticket moves, plus a `done` summary,
- a **worktree cleanup**: one item per branch it won't delete, with a state-file reconcile so earlier items get resolved,
- a **session/memory reaper**: an urgent item only on anomalies, keyed per host,
- **automation failure** reporting.

Use keys that include the host when the same automation runs on several servers (`work:$(hostname -s):memory`), and keys that don't when they describe one shared thing (`work:ACME-123:redo-blocked`), so two servers working the same ticket update one card.

Keep setting the board status alongside the item:

```bash
orca worktree set --worktree active --workspace-status in-review --comment "Blocked: needs a deploy decision (see needs-you)"
```

needs-you is the alert; the board is the record.

## Check it works

From an Orca terminal:

```bash
needs-you add --key "work:orca-test:hello" --title "Orca can reach needs-you" --agent "orca:test"
needs-you resolve --key "work:orca-test:hello"
```

Then run one automation by hand (`orca automations run ...`) and watch for its card.
