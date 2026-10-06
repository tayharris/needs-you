# 0001. The hub runs inside the Mac app by default

- Status: Accepted
- Date: 2026-10-06

## Context

The first design ([PLAN.md](../PLAN.md), decisions 1 and 4) put the hub on 2–3 always-on Linux machines, with the Mac as a pull-only reader. That works, but the first-run cost is high: before seeing a single item, a new user has to pick servers, run `install-hub.sh` on each, share a peer secret, and mint tokens on the command line. Most people who'd try needs-you have one Mac and a few agents, not a fleet of VMs.

The Mac is also the only place items are shown, so a hub there is never "further away" than the reader.

## Decision

`NeedsYou.app` embeds a hub and runs it by default. It listens on loopback and, when Tailscale is up, on the Mac's tailnet address (never on all interfaces). Machines and agents join with **invite links** made in the app ("Invite a machine"): an agent prompt to paste into Claude Code, or a `curl` one-liner, which redeems a one-time code for a sender token.

Server hubs remain supported as **optional** always-on peers that replicate with the app's hub using the existing protocol ([0003](0003-peer-replication.md)).

## Consequences

- Zero servers to try it: install the app, invite a machine, post.
- When the Mac sleeps or leaves the tailnet, senders can't reach the embedded hub. The CLI's offline outbox queues and delivers later, and `curl`-only senders lose alerts unless they retry. Anyone who needs immediate delivery while the laptop is closed (or a phone widget, see [ios-widget.md](../roadmap/ios-widget.md)) needs an always-on hub: [0004](0004-always-on-hub.md).
- The app now hosts a network listener, which matters for Gatekeeper, the macOS firewall and endpoint security tools on managed Macs ([distribution.md](../roadmap/distribution.md)).
- The embedded hub must speak exactly the same `/v1` and replication protocol as `hub/needs_you_hub.py`. Whether it runs the Python hub as a child process or is a Swift port is an implementation detail decided on the invite branches; either way the conformance suite ([ai-first.md](../roadmap/ai-first.md)) is what keeps them equal.
- The panel's never-take-focus rule is unaffected: the hub has no UI.
