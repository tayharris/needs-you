# The next big item: four candidates

Status (2026-10-08): a comparison for the owner. The recommendation (A) is at the end, with a first plan for it. A was taken up on the recommendation: steps 1–6 are designed in [ADR 0012](../adr/0012-mac-hub-peers.md) (Proposed) and built on `tay/mac-hub-peers`; the owner accepted ADR 0012 (step 7) for when it merges.

The candidates are the four larger items left on the roadmap after 0.1.5. The questions and choices on cards work is already under way, so it isn't compared here.

## What each one is

| | Candidate | Plan |
|---|---|---|
| A | **An always-on hub** ([ADR 0004](../adr/0004-always-on-hub.md), Proposed): the Mac's hub peers with an always-on server hub, then a protocol conformance suite, and only later a managed (Cloudflare) hub | ADR 0004 phases 1–3 |
| B | **iPhone widget and companion app** | [ios-widget.md](ios-widget.md) |
| C | **Focus tiers steps 9–11**: follow macOS Focus through a Focus filter, plus one sentence in the sender contract | [focus-tiers.md](focus-tiers.md) |
| D | **GitHub org webhooks**: events reach the hub in seconds, for a whole org, without a per-repo step | [future.md](future.md#github-org-webhooks) |

## A finding that changes the picture

**Today the Mac's own hub doesn't replicate with server hubs.** The app starts its hub with no peers (`LocalHubPlan.arguments` in `mac/Sources/NeedsYouCore/LocalHub.swift`). Server hubs replicate only with each other. Invites made on the Mac list only the Mac's URL (`hub_urls` is the hub's own URL plus its peers), so senders set up from the Mac never fail over to a server hub. The app reads one hub at a time, this Mac's first (`FailoverFeed`), so it never shows items posted to a server hub while its own hub answers. Several docs said the opposite until this change ([HUB.md](../HUB.md#with-the-apps-built-in-hub) now says what's true).

So "add an always-on server hub so alerts land while the Mac sleeps" only works today if you make your sender invites on the server hub, or if the Mac stops running its own hub. That's the gap behind A, and it also blocks B and D: a phone and a webhook both need an always-on hub, and nothing they post would reach the Mac's hub.

## Comparison

| | A. Always-on hub (phases 1–2) | B. iPhone widget | C. Focus filter (9–11) | D. GitHub webhooks |
|---|---|---|---|---|
| **Value** | High. Fixes a gap in what the docs promised; alerts land while the Mac sleeps, for every sender, with no change to senders; it's the base for B and D | High for someone away from the Mac, but only with an always-on hub to read from | Low to medium. In-app focus, bypass rules and the `needsyou://focus` Shortcuts recipe already cover most of it; this saves building two Shortcuts automations | Low for one person: the `needs-you-github` poller already covers review requests, deploy approvals, CI and PR state within 5 minutes. Medium for a team org |
| **Cost** | Medium: 2–3 sessions. Python and docs on Linux; a small Mac change (pass peers and a secret to the embedded hub) and a Settings screen | High: 5+ sessions. A multiplatform Core, an iOS app and widget extension, a `/v1/summary` API change, TestFlight | Small: a 0.5-session spike, then about 1 session if it works | Medium: a receiver (stdlib `http.server` + `hmac`), an event mapping, a guide; 1–2 sessions |
| **Depends on** | Nothing new. Server hubs, replication and invites already exist | A (a hub the phone can reach while the Mac sleeps), a paid Apple Developer account, Xcode | Xcode on the build Mac to produce App Intents metadata, which `swift build` doesn't | A public endpoint: Tailscale Funnel on a narrow path, or the managed hub (A phase 3); team mode for routing |
| **Risk** | Low to medium. Replication is tested; the new parts are a peer secret on the Mac (stored like the owner token, never logged) and two clocks for last-writer-wins | High. App Review, Tailscale on the phone, push needs a relay, a second UI to maintain | Medium that the spike fails for an ad-hoc signed build; nothing ships if it does | Medium. The first public endpoint in the project; signature checks and rate limits must be right |
| **Owner decisions** | Peer by invite (recommended) or by hand-entered secret; whether the Mac shows peer status | Developer account (personal or org), TestFlight vs App Store, push relay | None beyond "is it worth a spike" | Funnel vs waiting for the managed hub; which events interrupt |

## Recommendation

**A, scoped to ADR 0004 phases 1 and 2: peer the Mac's hub with an always-on server hub, set up from an invite, then the conformance suite.** Not the Cloudflare hub yet.

- It fixes what users were told already works: "add a server hub so alerts land while the Mac sleeps".
- B and D both need it first. C doesn't, but C is small enough to do as a side task whenever someone has a Mac with Xcode.
- It's mostly Python on Linux, where the tests are fast, and it changes nothing for senders.
- The conformance suite also guards the API changes coming with questions on cards (phase B of that work adds an item field and an answer path).

## First plan for A

Each step is one reviewable change with its tests. "API" means the `api-change` skill applies.

1. **Embedded hub takes peers** (Mac, small). `mac/Sources/NeedsYouCore/LocalHub.swift`: `LocalHubPlan` gains `peers: [String]` and a `peerSecretPath`, and passes `--peer URL` (each) and `--peer-secret-file PATH`; the secret lives in `~/Library/Application Support/NeedsYou/peer-secret`, mode 600, never logged. `needsRestart` also compares peers. Tests: `LocalHubTests` (arguments, no secret on the command line).
2. **A peer invite** (API). `POST /v1/invites` accepts `role: "peer"` (owner only); redeeming one returns the peer secret and the redeeming hub's `public_url` is added to the inviting hub's peers (stored in the database, since the Mac's hub has no config file). Replication of the peer list itself is out of scope. Files: `hub/needs_you_hub.py`, `hub/needs_you_admin.py`, `docs/API.md`, `tests/test_invites.py`, `tests/test_replication.py`. Open question for the ADR: a peer invite carries a long-lived secret, so it's one use and short-lived by default.
3. **`install-hub.sh --join <link>`** (server side). The server redeems the peer invite, writes `peer_secret_file` and the Mac as a peer in `hub.json`, and starts. Tests: `tests/test_install.py`-style with a fake hub.
4. **Settings → Your inbox → Always-on hub** (Mac). "Add an always-on hub" makes a peer invite and copies the one-liner (`curl ... | sudo bash -s -- --join <link>` or the `install-hub.sh` line); a row per peer shows the replication status from `/v1/health` (`peers`). Never takes focus outside the Settings window (hard rule 2).
5. **Invites list every hub.** With peers, `hub_urls` already includes them, so new sender invites made on the Mac list the server hubs too. Check `needs-you doctor`'s `hubs` line and the invite installer with two URLs. Docs: [HUB.md](../HUB.md#with-the-apps-built-in-hub) (the "today" note goes), [quickstart](../guides/quickstart.md), [concepts](../guides/concepts.md), README.
6. **Conformance suite** (`protocol/conformance/`, stdlib `unittest`, black-box over HTTP with `NEEDS_YOU_CONFORMANCE_URL` and tokens): validation tables, upsert and dedupe, resolve, `since` and `next` paging, roles, the volume guard, replication last-writer-wins and the same-key merge. Pull the cases out of `tests/test_api.py`, `test_validation.py`, `test_paging.py` and `test_replication.py`. CI runs it against a hub it starts. `api-change` skill: a step to update it.
7. **ADR 0004 to Accepted** for phases 1–2, with phase 3 (the managed hub) still Proposed.

Not in this plan: a container image, Tailscale Funnel, the Cloudflare hub, the phone.
