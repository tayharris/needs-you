# 0007. Founding design: one inbox, senders post, the Mac pulls

- Status: Accepted (records the first design; [0001](0001-hub-in-mac-app.md) changed where the hub runs by default)
- Date: 2026-10-06

## Context

Agents and automations get blocked on a person: a push decision, a feature flag, an approval. Left alone they write "needs you" into their own log and carry on, and nobody sees it. Ticket comments and chat messages either don't repeat or get lost in other traffic. What's missing is one place every machine and agent can drop "I need you for X" that the person actually sees without going looking, and that stays quiet otherwise.

What it has to do:

1. Any machine on the private network can add an item with one HTTP call or one CLI command. If the hub can't be reached, the item is kept and sent later.
2. Re-posting the same problem updates the existing item instead of adding a duplicate (an hourly automation must not stack 24 copies).
3. Whoever posted an item can mark it resolved (the agent got unblocked, the ticket moved).
4. On the Mac: nearly invisible when nothing is waiting; a noticeable but tasteful animation when something arrives; the count when collapsed and formatted cards with links when expanded; hide or snooze; on every Space and display, over full-screen apps, without taking focus; work items in work hours and personal ones outside them; a start-of-day summary.
5. Agent tools (Claude Code, Orca) can report "needs you" and "done" for their sessions automatically.
6. A link on a card opens the URL or the app it points to.

## Decision

```
 servers / agents / automations / CI             Mac
 ───────────────────────────────────             ───
  needs-you CLI ─┐                                NeedsYou.app
  curl ──────────┼──► hub (HTTP + SQLite) ◄──── polls every 30 s
  Claude hooks ──┘     private network only        (or SSE stream)
```

- **One name: needs-you.** It's a product others install, not a personal tool. Binaries are `needs-you` (sender CLI), `needs_you_hub.py` and `needs_you_admin.py`; the app is `NeedsYou.app`; environment variables are `NEEDS_YOU_*`.
- **Only the Mac shows anything.** Servers, CI and agents only send.
- **The hub is the single source of truth**: one small HTTP service with SQLite. The hub and the CLI use the Python 3 standard library only ([0002](0002-python-stdlib-only.md)). The Mac app is Swift/SwiftUI.
- **The Mac pulls; it is never pushed to.** A laptop sleeps, changes networks and goes off VPN. Senders write to a hub, and the Mac catches up when it wakes.
- **Senders** use a tiny CLI with an offline outbox, or plain `curl`. Claude Code hooks and other automations use the CLI.
- **Private network only.** The hub listens on loopback or its Tailscale address, never on `0.0.0.0` or a public port.
- **Upsert by `key`.** A POST with a key that's already open updates that item. `updated_at` moves, but the card only re-animates when its title, body or priority actually changed, which keeps hourly automations quiet.
- **The count** is open `needs` items in the current context only. `done` and `info` items go in a quieter Recent list, expire (24 h by default) and never raise the count.
- **One token per sender**, so one can be revoked without touching the others, and the hub records which token posted what. Reader tokens can't create items. The hub validates lengths, enums, link schemes (an allow-list, because agents write these links) and caps open items per token as a runaway-agent guard.
- **Redundant hubs are optional.** Hubs replicate every write to their peers and converge by `key` ([0003](0003-peer-replication.md)). The CLI tries its hubs in order and queues when none answer; the Mac polls the first reachable hub and fails over.
- **Built for others**: install scripts and a guide for each piece (the Mac app, a hub, a sender machine, Claude Code in any repo, Orca automations).

The wire contract is [API.md](../API.md); the sender rules are [AGENT-GUIDE.md](../AGENT-GUIDE.md); the Mac app's design is in [mac/README.md](../../mac/README.md#design).

## Consequences

- Nothing is lost while the Mac sleeps, as long as senders can queue (the CLI) or reach an always-on hub ([0004](0004-always-on-hub.md)).
- Dedupe by key puts the burden of picking stable keys on senders; AGENT-GUIDE spells it out.
- Item text is shown on a screen and stored on hubs, so senders must keep secrets, code and customer data out of it (AGENT-GUIDE rules).
- The first build order was: hub and CLI; the Mac app (pill, count, cards, links, snooze, all-Spaces); arrivals animation, the work/personal schedule, the morning summary and SSE; agent integrations; then extras (an iPhone widget, a chat fallback for urgent items). The hub later moved into the Mac app by default ([0001](0001-hub-in-mac-app.md)).
