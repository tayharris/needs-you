# Stale items: a safety net for senders that don't resolve

Status (2026-10-08): built and shipped in 0.1.2. Nothing left to plan here. How it works for users: [Troubleshooting → Duplicate or stale cards](../guides/troubleshooting.md#duplicate-or-stale-cards).

The contract is that the sender resolves what it posted. This plan covered the cases where it can't (a killed agent session, a lost marker file, an automation that crashed or stopped reporting a blocker) and added four safety nets:

| | What | Where it's documented |
|---|---|---|
| A | **Process leases.** The agent hook records the agent's process; the 5-minute `needs-you flush` resolves the card once that process is gone. Since 0.1.4 it also compares the start time in UTC, so a `TZ` difference between cron and the shell can't clear a live session's card. | [Claude Code](../guides/claude-code.md), each agent's guide |
| B | **A 48-hour expiry on agent cards** (`NEEDS_YOU_AGENT_EXPIRY_HOURS`), pushed out by each new post. Aider's cards expire after an hour, since Aider never says when you answered. | [Claude Code](../guides/claude-code.md), [Aider](../guides/aider.md) |
| C | **Expiry for scheduled automations:** post with `--expires-in` of about twice the schedule and re-post while the blocker holds. | [Orca](../guides/orca.md) |
| D | **App side:** the age on cards waiting 4 hours or more, and **Dismiss All from &lt;host&gt;** in a card's menu. | [Mac app](../guides/mac-app.md) |

Rejected, and still not recommended:

- **A "completed" notification as a second item** (`done` after `needs`): it adds a card instead of removing one. Resolve already removes the card everywhere.
- **Hub-side "stale after N hours" logic**: the hub can't tell a live wait from a dead one. The sender can.
