# iPhone widget and companion app

Status (2026-10-08): plan only. Nothing is built: no `/v1/summary`, no iOS target. It depends on an always-on hub ([ADR 0004](../adr/0004-always-on-hub.md)) and a paid Apple Developer account; see [next-big-item.md](next-big-item.md).

Goal: a home-screen and lock-screen widget showing the needs-you count and the top items. Tapping an item or one of its links opens the right app (Jira, GitHub, Slack, Orca, ...) through deep links or universal links. A small SwiftUI companion app holds the connection and handles taps.

## The hard part: reaching a hub from a phone

The phone can only reach a hub that it can route to and that is awake.

- **Tailscale is required** for a tailnet-only hub: the Tailscale iOS app must be connected (it's a VPN profile; it can stay "always on" with on-demand rules). Widgets and the app use the system network stack, so tailnet MagicDNS names resolve while the VPN is up.
- **The Mac's embedded hub sleeps.** When the laptop lid is closed, the phone can't refresh at all, which is exactly when a phone widget is most useful. So for the phone, **an always-on hub is effectively required**: a server hub replicating with the Mac (option (a) in [ADR 0004](../adr/0004-always-on-hub.md)), or the managed Cloudflare hub (option (c)), which the phone reaches over HTTPS without Tailscale at all.
- The Mac stays the primary reader; the phone is a second reader with its own `reader` token, so it can be revoked alone.

### Refresh options

| Option | How | Freshness | Cost / constraints |
|---|---|---|---|
| **WidgetKit timeline polling** | `TimelineProvider` fetches `GET /v1/summary` and returns an entry with `.after(now + 15 min)` | ~15–60 min. iOS gives a frequently viewed widget roughly 40–70 reloads per day, and reloads are deferred on low power | No server changes. Fails silently when Tailscale is off; show the "as of" time |
| **Background App Refresh** | `BGAppRefreshTask` in the companion app fetches, writes to the App Group, calls `WidgetCenter.shared.reloadAllTimelines()` | Opportunistic, iOS decides; often hours | Users can disable it; adds no freshness guarantee over timelines |
| **Foreground refresh** | The app refreshes on open and via pull-to-refresh, then reloads widgets | Instant when used | Only when the user opens it |
| **APNs push** | The hub (or a relay) sends a push when an item is created/changes; the app's Notification Service Extension or a background push reloads the widget. iOS 17+ also supports **widget push updates** for Live Activities | Seconds | Needs an APNs key (paid Apple Developer account) and a **relay** that holds it, see below |

Plan: ship polling + foreground refresh first (no server), add push later.

### Push and privacy

APNs needs a server holding an APNs auth key (`.p8`). A self-hosted hub can't safely ship one key to every user, so pushes go through a **relay**:

- **Option P1: our relay** (a Cloudflare Worker). The hub sends `{device_token, badge_count}` only: **no titles or links** (a "content-free" push). The phone then fetches details over Tailscale. The relay sees device tokens and counts, never item text. Needs rate limits and per-hub relay tokens.
- **Option P2: the managed Cloudflare hub** (ADR 0004 (c)) sends pushes itself. Simpler, but item data already lives at Cloudflare in that mode.
- **Option P3: bring your own APNs key.** Power users configure their key on their server hub. No third party, high setup cost.

Recommendation: P1 with content-free pushes when push is added; it keeps the "no cloud sees your items" promise for self-hosted users.

## Architecture

```
NeedsYouCore (Swift package, multiplatform: macOS 14 + iOS 17)
  ├─ Models, HubClient, FailoverFeed, LinkPolicy, LimitedMarkdown, Schedule
  └─ (AppKit-only bits like FloatingPanel stay in the macOS target)

NeedsYou iOS app (SwiftUI)          NeedsYou widget extension (WidgetKit)
  - connect via invite / QR            - reads token + hubs from the shared Keychain
  - list, Done/Dismiss, Snooze         - fetches /v1/summary in the TimelineProvider
  - opens links                        - App Intents for Done / Snooze (iOS 17)
        └──────── App Group: group.app.needsyou.mac ────────┘
                  (cached summary JSON, settings)
        Keychain access group shared by app + widget (token)
```

### Shared code

- Make `mac/Package.swift` multiplatform (`platforms: [.macOS(.v14), .iOS(.v17)]`). Move AppKit-specific files (`FloatingPanel.swift`, `PanelGeometry.swift`) out of `NeedsYouCore` into the macOS app target, or guard them with `#if os(macOS)`.
- `HubClient` uses `URLSession`, which works in widget extensions (keep requests short: the widget has a few seconds and ~30 MB).
- `LinkPolicy` stays the single allow-list.
- A future repo move (see [ai-first.md](ai-first.md)) would lift `NeedsYouCore` to `apple/NeedsYouCore` shared by `apple/mac` and `apple/ios`.

### Connecting

- The Mac app's **Invite a device** shows a QR code encoding `needsyou://connect?hub=<url-encoded hub>&code=<invite code>` (the link format Macs already use to connect to a hub). The iOS app registers the `needsyou` URL scheme and also has a QR scanner (`DataScannerViewController`).
- The app redeems the invite (`POST /v1/invites/redeem`, which exists) for a **reader** token, then stores it in the Keychain with `kSecAttrAccessGroup` set to the shared group and `kSecAttrAccessibleAfterFirstUnlock` (widgets run while the phone is locked).
- Several hubs, in failover order, like the Mac.

## Widget families

| Family | Content |
|---|---|
| `systemSmall` | The count, a ring in the highest open priority's color (red/amber/slate), "all clear" when zero, "as of 10:42" |
| `systemMedium` | Top 3 open `needs` items (urgent → normal → low, oldest first): title, source, age. Each row is a `Link` |
| `systemLarge` | Optional: top 6 plus a "Recent done" line |
| `accessoryCircular` (lock screen) | Count in a gauge ring |
| `accessoryRectangular` (lock screen) | Count + first item's title |
| `accessoryInline` | `2 need you` |

Work/personal: the widget uses the same schedule as the Mac (configurable per widget with an `AppIntentConfiguration`: "Work", "Personal", "Auto").

### Interactive widgets (iOS 17)

- `Button(intent: ResolveItemIntent(id:))` → **Done** (PATCH `status=resolved`) and `SnoozeIntent(minutes:)` (local, stored in the App Group).
- Intents run in the widget extension process, so they need the token from the shared Keychain and must finish in a few seconds. On failure, show the item again on the next timeline.

### Live Activities (stretch)

For `urgent` items: a Live Activity on the lock screen and Dynamic Island with the title and a Done button, started by the app (or by a push-to-start token, iOS 17.2+, which needs the push relay). Ends when the item resolves.

## Opening the right app

Flow: the widget row uses `Link(destination:)` (medium/large) or `widgetURL` (small, one URL for the whole widget) → **the companion app opens** with `needsyou://open?item=<id>&link=<n>` → the app looks up the link, checks the allow-list, then `UIApplication.shared.open(url)`.

Why route through the app instead of linking straight to `https://...`: one place to apply `LinkPolicy`, mark the item `seen_at`, and fall back gracefully.

| Scheme | iOS behaviour |
|---|---|
| `https` | **Universal links** open the native app when it's installed and claims the domain: Jira Cloud (`*.atlassian.net`), GitHub (`github.com`), Slack (`*.slack.com` / `app.slack.com`), Figma, Teams, Discord. Otherwise Safari. Use `open(url, options: [.universalLinksOnly: true])` first, then fall back to a normal open. |
| `slack`, `msteams`, `discord`, `figma` | Custom schemes the iOS apps register. Must be listed in `LSApplicationQueriesSchemes` in the app's Info.plist to use `canOpenURL`; if not installed, fall back to the item's next `https` link |
| `orca`, `vscode`, `cursor` | Desktop-only today (no iOS apps). Not openable on iOS: show the link as text, and prefer an `https` link from the same item. If Orca ships an iOS app, add `orca` to `LSApplicationQueriesSchemes` |
| anything else | Not allowed, same as the Mac (shown as text) |

Keep the **same allow-list** as the hub and `LinkPolicy.swift`. Senders that want phone-friendly items should include an `https` link (AGENT-GUIDE already says "link to where they act").

## Hub API additions

- **`GET /v1/summary`** (reader): a compact response for widgets, so a timeline fetch is one small request:

  ```jsonc
  {"server_time": "...", "hub_id": "hub-a",
   "counts": {"work": {"urgent": 1, "normal": 2, "low": 0}, "personal": {...}},
   "top": [ {"id": "...", "title": "...", "priority": "urgent", "context": "work",
             "source": {...}, "created_at": "...", "links": [...]} ]}  // max 6, needs only
  ```

  Query: `?context=work|personal|all&limit=6`.
- **Device registration for push** (later): `POST /v1/devices` `{platform: "ios", apns_token, relay}`; the hub forwards content-free pushes via the relay on writes that change counts.
- Follow the `api-change` skill: `docs/API.md`, hub, tests, Mac client (it can use `/v1/summary` for the idle hover line too).

## Phases

| Phase | What | Done when |
|---|---|---|
| 0 | Make `NeedsYouCore` multiplatform; add `/v1/summary` | Core builds for iOS in CI; summary endpoint tested |
| 1 | iOS app: connect via QR/link, list, Done/Dismiss, open links. TestFlight | Tapping a Jira item opens the Jira app |
| 2 | Widgets: small, medium, lock screen; polling timelines | Count updates within 30 min with Tailscale on |
| 3 | Interactive Done/Snooze (App Intents) | Done from the widget resolves on the hub |
| 4 | Push via relay (content-free), then Live Activities for urgent | An urgent item reaches the lock screen in seconds |

## Open decisions

1. **Paid Apple Developer account** (needed for TestFlight, App Groups on device, APNs). Personal or organization (non-profit)?
2. **Distribution:** TestFlight only, or the App Store? App Review will need a demo mode (the Mac's demo feed can be reused).
3. **Push relay:** yes/no, and if yes P1 (content-free relay) vs P2 (managed hub).
4. **Tailscale-only vs the managed hub** for phone users (ADR 0004).
5. Minimum iOS: 17 (interactive widgets) is assumed.
