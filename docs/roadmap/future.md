# Future ideas

Status: plans only. Each has enough detail to start; none is scheduled.

## iPhone widget

Its own plan: [ios-widget.md](ios-widget.md).

## GitHub org webhooks

Goal: PR review requests, failed checks on `main`, and Dependabot alerts in a team org post to needs-you without a per-repo workflow step.

The hub is tailnet-only, and GitHub's webhook senders aren't on the tailnet. Options:

| Option | How | Trade-off |
|---|---|---|
| **Tailscale Funnel on a narrow path** | On a server hub: `tailscale funnel --set-path /hooks/github 8766` in front of a separate tiny listener (not the hub port) that only accepts `POST /hooks/github`, verifies `X-Hub-Signature-256` with the webhook secret, maps events to items, and calls the hub on loopback with a sender token | Public endpoint, but only one verified path; the hub itself stays private |
| **GitHub Action + Tailscale Action** | An org-level reusable workflow (`on: pull_request`, `check_suite`, ...) joins the tailnet with `tailscale/github-action` (ephemeral, `tag:ci`) and posts with curl, like `integrations/ci/github-actions.yml` | No public endpoint; needs the workflow in each repo (or a required workflow via org rulesets) and spends Actions minutes |
| **Managed hub** | The Cloudflare hub (ADR 0004 (c)) exposes `/hooks/github` directly | Only if that hub exists |

Files to add: `integrations/github-webhook/` (`receiver.py`, stdlib `http.server` + `hmac`; an event → item mapping table; a systemd unit), a guide, tests with recorded payloads. Keys: `work:<repo>:pr-<n>:review`, resolved when the review is submitted or the PR closes. Per-person routing comes from the team mode below.

Open: which events are worth an interruption (review requested: yes; every failed check: no, only on default branch).

## Discord/Slack fallback for urgent items

Goal: if an `urgent` item isn't seen on any Mac within N minutes (no `seen_at`), send it to a phone-reachable channel.

- Hub config: `"escalation": {"after_minutes": 10, "webhook": "https://discord.com/api/webhooks/..."}`. The webhook URL is a secret: store it like `peer_secret` (file or env), never in the DB or logs.
- A hub thread checks open urgent items with `seen_at IS NULL` and `created_at < now - after`, posts title + one `https` link (no body), and records `escalated_at` so it sends once. Only the hub that minted the item escalates (`origin_hub`), so replicas don't double-send.
- This is the first feature that sends item text off the tailnet. Off by default, and documented as such.
- API: `escalated_at` becomes a new item field (follow the `api-change` skill).

## Team mode

Goal: one shared hub for a small team; each person sees their own items and shared ones.

- Items get optional `to` (a person id or a group like `oncall`). Absent = the hub owner (today's behaviour).
- Tokens get an `owner` person. A reader token sees items addressed to its person or its groups, plus unaddressed ones if it's the hub owner.
- Senders address people by handle (`--to sam`); the hub resolves handles from a `people` table (`handle`, `display`, `groups`).
- Routing rules (see [ai-first.md](ai-first.md) "Routing") build on this.
- Volume guard per sender per recipient.
- Privacy: a team hub holds everyone's items; personal context items should stay on personal hubs. Recommend separate hubs for work and personal and let the Mac app read both (it already supports several hubs; it would need several *independent* hub sets).

Open: is this a hub feature, or just "run one hub per person, and senders post to the right one"? The latter needs no code.

## In-app help and onboarding

- First run: a short 3-step sheet in Settings (it may activate the app, the panel may not): "Your hub is running", "Invite a machine", "Try demo mode".
- A **"Test alert"** button that posts an `info` item through the local hub.
- A help menu item in the pill's right-click menu linking to the guides (the site's docs once hosted).
- Empty states with one action ("No machines yet. Invite one").
- A **diagnostics** pane: hub reachable, token role, peers and outbox depth (from `/v1/health` with a token), last poll, and a "copy diagnostics" button that never includes tokens. Mirrors `needs-you doctor` ([ai-first.md](ai-first.md)).
