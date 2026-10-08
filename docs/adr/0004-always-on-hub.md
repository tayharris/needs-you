# 0004. An always-on hub

- Status: **Proposed**
- Date: 2026-10-06
- Phases 1–2 (the Mac's hub peering with an always-on hub, the conformance suite): designed in [0012](0012-mac-hub-peers.md)

## Context

With the hub embedded in the Mac app ([0001](0001-hub-in-mac-app.md)), nothing is always on. While the laptop sleeps:

- CLI senders queue in their outbox (fine), but `curl`-only senders (CI, webhooks) lose alerts unless they retry.
- Nothing outside the tailnet can post at all (GitHub org webhooks, see [future.md](../roadmap/future.md)).
- A phone can't refresh a widget ([ios-widget.md](../roadmap/ios-widget.md)), exactly when it matters most.

"Always on" is an architecture need, and the answer has to be **maintainable**: something a user can run for years without babysitting, and something this project can keep correct across implementations. Replication ([0003](0003-peer-replication.md)) already lets any number of hubs join the mesh, so the question is what the always-on peer is.

## Options

### (a) The Python hub on an always-on box over Tailscale (exists today)

`scripts/install-hub.sh` on any Linux machine with systemd: a VM, a NAS, a Raspberry Pi, an old Mac mini (macOS needs a launchd plist instead of systemd).

- **For:** exists and tested; stdlib only, so nothing to update but the file itself; data never leaves the user's machines; tailnet-only, no public surface.
- **Against:** someone has to own a box: OS updates, disk, power, Tailscale login expiry. Not reachable from outside the tailnet (webhooks, a phone without Tailscale). `http.server` is fine on a tailnet, not on the internet.
- **Maintenance for the project:** low. It's the reference implementation.

### (b) A container image of the same hub

`ghcr.io/tayharris/needs-you-hub`: `python:3.12-slim` + the two hub files, a volume for the DB, config via env. Tailscale either on the host or as a sidecar (`tailscale/tailscale` container with `TS_AUTHKEY`, hub binds the sidecar's tailnet IP).

- **For:** one command on any Docker host, NAS (Synology, Unraid), or Fly.io/Railway-style hosts; same code as (a), so no protocol drift; easy upgrades (`docker pull`).
- **Against:** still a host to own; the sidecar pattern is fiddly; image publishing and CVE rebuilds become a project chore. On a PaaS it's public unless the sidecar is used.
- **Maintenance:** low–medium (a Dockerfile and a CI publish job).

### (c) A Cloudflare Worker + Durable Object hub

A TypeScript Worker implementing the same `/v1` API and the replication protocol, with one Durable Object per hub using the **SQLite storage backend** (the same schema as the Python hub). The user already has a Cloudflare account.

- **For:** always on with no box to maintain; global, cheap (free tier likely covers personal use); HTTPS by default, so the **phone widget and GitHub webhooks reach it directly**, no Funnel or Tailscale on the phone; DO alarms can run expiry checks, the escalation fallback and push relays. It joins the existing mesh as a peer, so the Mac and server hubs keep working when Cloudflare is unreachable.
- **Against:**
  - **Public internet.** Needs strict tokens (already hashed and per-sender), rate limiting (Cloudflare rate-limiting rules, plus the volume guard), optional **Cloudflare Access** in front of reader endpoints (service tokens for the Mac/phone), and a careful CORS/headers posture. Replication endpoints must be peer-secret-only and could be restricted further with mTLS or Access service tokens.
  - **Data at Cloudflare.** Item titles, short bodies and links are stored by a third party. The AGENT-GUIDE rules (no secrets, no customer data) make this tolerable, but it breaks the "no cloud" promise for users who enable it, so it's opt-in and clearly labelled.
  - **A second implementation** in a second language. Validation tables, LWW, the same-key merge, `since` cursors and SSE semantics must stay in lockstep. That's only maintainable with a **shared protocol conformance suite** run against every implementation in CI. Without it, this option should not ship.
  - Cloudflare-specific limits: request CPU time, DO single-threaded throughput (ample here), SSE via streaming responses or WebSocket hibernation.
- **Maintenance:** medium–high for the project; near zero for the user.

### (d) Tailscale Funnel in front of (a)

`tailscale funnel` exposes the box's hub (or one path of it) on a public `*.ts.net` HTTPS URL.

- **For:** no new code; public reachability for webhooks and phones without Tailscale.
- **Against:** puts the stdlib `http.server` hub directly on the internet (not designed for it; no rate limiting); Funnel is all-or-nothing per port/path; still a box to maintain. Acceptable only for a narrow, separate webhook receiver path that verifies signatures, as sketched in [future.md](../roadmap/future.md), not for the hub API.
- **Maintenance:** low code, higher security risk.

## Comparison

| | (a) Python on a box | (b) Container | (c) Cloudflare DO | (d) Funnel + (a) |
|---|---|---|---|---|
| User maintenance | A box | A Docker host | None | A box |
| Reachable without Tailscale | No | No (sidecar) / yes (PaaS) | Yes | Yes |
| Data leaves user's machines | No | No (self-host) | Yes (titles/links) | No |
| Public attack surface | None | None / some | Yes, managed | Yes, unmanaged |
| Second implementation | No | No | **Yes** | No |
| Works with phone widget | With Tailscale on | With Tailscale on | Yes | Yes |
| Exists today | Yes | No | No | Partly |

## Decision (proposed)

1. **Keep (a) as the self-hosted always-on option**, and document Raspberry Pi and Mac mini (launchd) setups. It's the reference implementation.
2. **Build the protocol conformance suite first** (`protocol/conformance/`, black-box over HTTP, see [ai-first.md](../roadmap/ai-first.md)). Run it in CI against the Python hub and the embedded hub. This is the gate for everything after it.
3. **Plan (c) as the "managed, zero-maintenance" option**, opt-in, built only after step 2, and required to pass the same suite in CI before release. Ship it with Cloudflare Access support, rate limits and a clear "your item text is stored at Cloudflare" notice.
4. **(b)** is cheap to add on top of (a) when someone asks for it; not a priority.
5. **(d)** is not recommended for the hub API. Use it only for a narrow, signature-verified webhook receiver if (c) doesn't exist yet.

### Phased path

| Phase | What | Gate |
|---|---|---|
| 1 | Docs: (a) on a Pi / Mac mini, "add an always-on peer to your Mac hub" via an invite | None |
| 2 | `protocol/` spec + conformance suite; CI runs it against the Python hub | Suite covers validation, upsert, resolve, `since`, roles, volume guard, LWW, same-key merge |
| 3 | Cloudflare hub prototype in `hubs/cloudflare/` (Worker + SQLite DO), passing the suite; deploy guide with `wrangler` | 100% conformance in CI |
| 4 | Opt-in in the Mac app ("Add a managed hub"), Access service-token support in clients, phone widget pointing at it | Security review: tokens, rate limits, Access, logs never include item text |
| 5 | Optional: container image (b) | Demand |

## Consequences

- The conformance suite becomes a required part of any API change (the `api-change` skill gains a step).
- Repo layout gains `protocol/` and a `hubs/` (or similar) home for implementations ([ai-first.md](../roadmap/ai-first.md) proposes the moves).
- The privacy promise splits in two: "self-hosted: nothing leaves your machines" and "managed: titles and links stored at Cloudflare". The site and docs must say which mode a user is in.
- Open decisions: who pays for and operates a shared managed hub, if anyone (versus each user deploying their own Worker to their own Cloudflare account, which keeps data in the user's account and is the default assumption here); whether Access is required or optional; how a Cloudflare hub authenticates to tailnet-only peers (it can't reach them, so replication would be pull-from-Cloudflare by the tailnet hubs, an asymmetric mode the protocol needs to allow).
