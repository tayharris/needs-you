# Stale items: a safety net for senders that don't resolve

Status: A, B and C are built (see the Claude Code integration README and the Orca prompt block). D is built in the Mac app (the age badge and **Dismiss All from <host>**; see mac/README.md).

The contract is that the sender resolves what it posted, so a card you never saw and that got handled disappears without you ever seeing it. That works when the sender is alive to resolve. This page covers the cases where it isn't, and what to add.

## How cards go stale today

| Case | What happens now | How often |
|---|---|---|
| A Claude session is killed (terminal closed, `kill`, reboot, OOM, an Orca terminal closed) | No `SessionEnd`, so no resolve. A `needs` card has no expiry, so it stays until you dismiss it. | Common on devboxes |
| The hook's marker file is lost (`~/.local/state` cleaned, a new container) | Every later resolve is skipped, because resolves only run when the marker exists. The card stays. | Rare |
| An automation stops reporting a thing (the ticket moved) but its prompt has no resolve step, or it crashed | The card stays. The Orca block now has an explicit resolve step and the reconcile pattern, but nothing enforces either. | Likely, per automation |
| The user handles it somewhere else (approves in Jira, answers in Slack) and the agent never runs again | Stays until the agent's next run, or forever | Depends |

Already handled: a session that moves on after you answer (`UserPromptSubmit`, `PostToolUse` and `Stop` resolve it), `done` and `info` items (24 h expiry), and offline hubs (resolves queue behind the add).

## Options

### A. Lease the hook's cards to a live process (recommended)

When the hook posts, it writes the Claude process id (`$PPID`) and its start time into the marker. `needs-you flush`, which already runs every 5 minutes from cron or a LaunchAgent on every sender, checks each marker: if that process is gone (or the pid now belongs to a different start time), it resolves the key and removes the marker.

- Catches every killed or crashed session within 5 minutes, on the machine that knows the truth.
- No wire change and no app change. Changes are in `needs-you-hook.sh` and the CLI's `flush`, plus tests.
- Cost: one `kill -0` per marker every 5 minutes.
- To check first: Claude Code may start hooks through a shell wrapper, so `$PPID` can be that wrapper rather than Claude. Walk up the parent chain to the first `claude`/`node` process, and test it with async hooks.
- In Orca, the key is the terminal handle, so a new session in the same terminal posts over the same card. That's correct.

### B. A long default expiry on hook cards (backstop)

The hook passes `--expires-in 48` (a `NEEDS_YOU_AGENT_EXPIRY_HOURS` setting). Each re-post pushes it out. It catches a lost marker and a machine that never comes back.

- Cost: a session really waiting more than 48 hours with no new notification drops off the pill. That's acceptable, since 48 hours of silence means it isn't urgent.
- One line in the hook.

### C. Lease expiry for scheduled automations

An automation that runs every N hours posts its blockers with `--expires-in <2N>` and re-posts them on every run while they still apply. A blocker the run stops reporting expires on its own, even if the prompt's resolve step is skipped or the run crashes.

- No code change: a line in the Orca prompt block and the integration README ("hourly automations: `--expires-in 3`").
- Keeps the explicit resolve as the fast path, with expiry as the fallback.

### D. App-side: show age, and dismiss by source

The pill already shows items until they're resolved, dismissed or expired. Show the age on old cards ("2 d"), and add **Dismiss all from this host** to a card's menu.

- Helps with any stale card from any sender, including ones we don't control.
- Mac app only: no wire change (dismissing uses the existing PATCH).

### Not recommended

- **A "completed" notification as a second item** (`done` after `needs`): it adds a card instead of removing one, which is the noise needs-you exists to cut. Resolve already removes the card everywhere.
- **Hub-side "stale after N hours" logic**: the hub can't tell a live wait from a dead one. The sender can.

## Proposal

1. **A + B together** for Claude Code cards: A gives a 5-minute clean-up of dead sessions, and B is the backstop. About a day's work with tests.
2. **C** as a one-line change to the Orca prompt block, plus a test that the installer and README still match.
3. **D** when the Mac app next changes.
