# Focus tiers: how loudly a card arrives, and what breaks through

Status: plan, nothing built, 2026-10-07.

Today every new `needs` item in the current context gets the same arrival (the pill springs out with a glow, urgent pulses twice). Out of context it's a faint second number. Snoozed or hidden, an urgent item breaks through (`SnoozeBreakthrough`, `HiddenArrivalPolicy`, settings `urgentBreaksSnooze` on, `urgentShowsHiddenPanel` off). There's no notion of "I'm heads-down", and the app doesn't know about macOS Focus. This plan adds **delivery tiers**, maps them from what the app already knows (priority, context, schedule, snooze) plus a focus state, and defines **bypass**. All of it is Mac-side: **no wire change**.

Constraints that shape it: the panel never takes focus or activates the app (hard rule 2); no new dependencies without an ADR (system frameworks are fine); pure logic goes in `NeedsYouCore` with tests.

## Findings: what macOS lets a non-sandboxed, ad-hoc-signed AppKit app know

| Mechanism | What it gives | Requirements | Verdict |
|---|---|---|---|
| `INFocusStatusCenter` (Intents) | `focusStatus.isFocused`: on/off only, no Focus name | Authorization prompt **and** the Communication Notifications capability, which Apple scopes to messaging apps and which needs a provisioning profile ([Apple forums](https://developer.apple.com/forums/thread/690081), [Focus Status API](https://developer.apple.com/forums/thread/682143)) | Not viable for an ad-hoc build, and only a bool |
| **Focus filters** (`SetFocusFilterIntent`, App Intents, macOS 13+; our minimum is 14) | The user adds a needs-you filter to any Focus in System Settings → Focus, with parameters we define. The system runs our intent's `perform()` when that Focus turns on, and again with the defaults when it turns off; `current` reads the active configuration ([SetFocusFilterIntent](https://developer.apple.com/documentation/appintents/setfocusfilterintent), [WWDC22 "Meet Focus filters"](https://developer.apple.com/videos/play/wwdc2022/10121)) | AppIntents is a system framework (no ADR). Its metadata (`Metadata.appintents`) is produced by Xcode's `ExtractAppIntentsMetadata` build phase; `swift build` (our `bundle.sh`) doesn't run it. **Spike:** run `appintentsmetadataprocessor` from `bundle.sh`, or build the app target with `xcodebuild` | **Recommended** source of "which Focus is on", if the spike works |
| `~/Library/DoNotDisturb/DB/Assertions.json` | Raw Focus state | Full Disk Access on current macOS; undocumented format ([Six Colors](https://sixcolors.com/link/2021/11/help-a-mac-automation-find-focus/), [automators.fm](https://talk.automators.fm/t/get-current-focus-mode-via-script/12423)) | No: asking for Full Disk Access to read one file is the wrong trade |
| Shortcuts automation ("When Focus turns on, open `needsyou://focus?...`") | Any Focus → our URL handler | The user builds a personal automation; the URL handler already exists (`needsyou://connect`) | A fallback that needs no build change; one `needsyou://focus` action |
| `UNUserNotificationCenter` banners | System banners that macOS itself silences under Focus | Authorization prompt. **Time Sensitive** (breaks through Focus) needs the `com.apple.developer.usernotifications.time-sensitive` entitlement, which needs a real signing identity; Critical needs Apple approval | Banners can't bypass Focus in an ad-hoc build. Also, **clicking a banner activates the posting app**, which collides with hard rule 2 |

So: the pill is the only channel that can "break through" for an ad-hoc build, and it already sits above everything without taking focus. That makes it the bypass channel by construction.

## Design

### Tiers

| Tier | What the person sees | Counts in the badge |
|---|---|---|
| **Interrupt** | Today's arrival: spring-out preview with a glow pulse (urgent twice), optional sound, and when hidden or snoozed, a break-through per today's rules. Peeks on the work display ([human-gates.md](human-gates.md) step 6) | Yes |
| **Ambient** | No spring-out. The count changes, the ring takes the priority colour, and a single soft brighten of the pill (honours Reduce Motion). Visible on expand | Yes |
| **Later** (digest) | Not announced and not counted. Collected in a **Later** section at the bottom of the expanded view, then delivered as one quiet peek ("3 waited while you were focused") when the focus or snooze ends, at the morning summary, or at the next work-hours start | No (shown as a faint `+3`) |

Tiers are about **arrival**. Once an item is on the list it's the same card in every tier; Done, Dismiss, per-card snooze and links don't change.

### Default mapping

`DeliveryPolicy.tier(item, state) -> Tier`, pure. State = current context (schedule plus override), panel visibility (shown, snoozed until, hidden), focus (none, or a level from the in-app focus or a Focus filter), and bypass rules.

| Item | No focus | Focus "Quiet" | Focus "Urgent only" | Snoozed / hidden |
|---|---|---|---|---|
| `needs` urgent, in context | Interrupt | Interrupt | Interrupt | Interrupt if `urgentBreaksSnooze` (today: on) |
| `needs` normal, in context | Interrupt | Ambient | Later | Later |
| `needs` low, in context | Ambient | Later | Later | Later |
| `needs`, other context | Later (the faint second number, as today) | Later | Later | Later |
| urgent, other context | Interrupt (today's behaviour: urgent breaks through in either context) | Interrupt | Interrupt | as above |
| `done` / `info` | Ambient (in Recent, never counted, as today) | Later | Later | Later |
| A bypass rule matches | the rule's tier | the rule's tier | the rule's tier | the rule's tier |

"Snoozed / hidden" keeps exactly today's behaviour for urgent; the change is that what's held back is collected under Later and delivered at the end instead of only being in the list.

### Focus state: three sources, one value

1. **In-app focus** (no permission, build first): right-click menu and menu bar → **Focus** → *Quiet* or *Urgent only*, for 30 min / 1 h / 2 h / until the schedule's next boundary (`WorkSchedule.nextBoundary`) / until turned off; plus **Agents and urgent only** (below). A small moon on the pill shows it. This is the time-boxed "do not disturb except agents".
2. **macOS Focus filter** (after the spike): `NeedsYouFocusFilter: SetFocusFilterIntent` with parameters *Level* (Normal / Quiet / Urgent only / Agents and urgent only) and *Context* (keep / work / personal). The user attaches it to their own Focuses ("Work" → Quiet; "Do Not Disturb" → Urgent only; "Personal" → context personal). `perform()` sets the shared focus state; deactivation restores the default.
3. **`needsyou://focus?level=quiet&minutes=60`** for Shortcuts automations and scripts (validated like `OrcaJump`; `level` from the fixed set, `minutes` 1–720). Lets people without the filter wire any Focus to it.

Precedence: the in-app setting by hand wins until it ends; then the Focus filter; then none.

### Bypass

"Bypass" means: **this item arrives as Interrupt no matter the focus or snooze**. It never means taking focus.

- **Urgent bypasses** by default (AGENT-GUIDE rule 6 already promises "it breaks through snooze"). A setting can turn that off for Focus only (for presentations).
- **Rules** in Settings → Alerts, evaluated top to bottom, first match wins: match on key prefix (`agent:` = every Claude Code session, `work:gh:deploy:`), `source.agent` prefix (`orca:`, `claude-code`), or `source.host` (`devbox`); action *Always interrupt*, *Never interrupt* (Ambient at most), or *Always later*. At most 50 rules, stored as JSON in UserDefaults (bounded like `PlacementBook`).
- **"Agents and urgent only"**: a built-in focus level equal to the rule "key prefix `agent:` → interrupt" plus urgent; everything else Later. It's the "heads-down, but tell me when an agent is blocked" mode.
- **Noisy sender guard:** a sender (token, via `source.host` + `source.agent`) whose items would interrupt more than 6 times in an hour is held to Ambient for the rest of that hour, with one line in the expanded header saying so. Keeps a looping automation from defeating the tiers; the hub's 60-open-items guard stays the hard limit.

Senders don't get a new field: priority is already their lever, and the person's rules decide the rest. AGENT-GUIDE gains one sentence: "`urgent` breaks through the person's focus; use it only for broken-now or blocked-today".

### Banners vs. the pill

The pill stays the primary and only required channel. System banners are **not** added in this plan: under Focus the system silences them (no Time Sensitive without a real identity), and a banner click activates the app (hard rule 2). Revisit with a Developer ID, as an opt-in for the Interrupt tier only when the panel is hidden, and only if a banner click can be shown not to activate NeedsYou (or the rule gets an explicit exception).

An optional sound for Interrupt (off by default, one system sound, urgent only or all Interrupts) covers "I'm looking at the other display".

## Recommendation

Build the tiers as pure Core logic first, with the in-app focus as the only focus source, then wire the arrival path to them. That alone delivers "heads-down except agents" and Later digests with no permission prompts and no build change. Then run the Focus filter spike; if `bundle.sh` can produce the App Intents metadata, add the filter; if not, ship `needsyou://focus` and a short guide for a Shortcuts automation instead.

## Build list

All Mac-only. No API change. New Core types get tests in `mac/Tests/NeedsYouCoreTests/`, registered in `mac/Sources/NeedsYouSelfTest/main.swift` and symlinked (see `mac/README.md`).

1. **`DeliveryPolicy` in Core.** `mac/Sources/NeedsYouCore/Delivery.swift`: `enum DeliveryTier { interrupt, ambient, later }`; `enum FocusLevel { normal, quiet, urgentOnly, agentsAndUrgent }`; `struct FocusState { level, until: Date?, source }`; `DeliveryPolicy.tier(for: Item, context:, visibility:, focus:, rules:, urgentBreaksSnooze:, now:)` implementing the table. Fold `SnoozeBreakthrough` and `HiddenArrivalPolicy` (in `MenuBar.swift`) into it, keeping their current results as test cases so nothing changes with no focus set. Tests: `DeliveryPolicyTests.swift`, one test per table cell.
2. **`BypassRule` in Core.** Same file or `BypassRules.swift`: `struct BypassRule: Codable { match: .keyPrefix/.agentPrefix/.host, value, action }`, `RuleBook` (≤ 50 rules, decode tolerant of unknown cases, first match wins). Tests: matching, cap, decoding junk.
3. **`NoisySenderGuard` in Core.** Sliding one-hour window per sender, threshold 6; pure with injected `now`. Tests.
4. **Later collection in `ItemStore`.** `ItemStore` records which open items arrived as Later and when; `laterItems(now:)` and `releaseLater()` (on focus or snooze end, the morning summary, the next work start). Tests in `ItemStoreTests.swift`.
5. **Wire the arrival path.** `mac/Sources/NeedsYou/AppModel.swift` `handleAnnouncements`: ask `DeliveryPolicy` per item; Interrupt → today's announcer/pulse; Ambient → a new soft `PulseRequest(style: .ambient)`; Later → no announcement. Badge counts exclude Later (`ItemStore.needsCount` gains the filter). `ExpandedView.swift`: a collapsed **Later** section; the release peek ("3 waited while you were focused"). Never activates; `FloatingPanelTests` passes unchanged.
6. **In-app focus controls.** Right-click menu and `MenuBarController`: Focus → Quiet / Urgent only / Agents and urgent only × durations (reuse `SnoozeOption.until` and `WorkSchedule.nextBoundary`); Off. Moon glyph on the pill. Persist `FocusState` in UserDefaults so a relaunch keeps it (new keys, no migration needed).
7. **Settings → Alerts.** Tier table preview (read-only, from `DeliveryPolicy`), "Urgent breaks through Focus" toggle, the rule editor (in the Settings window, which may take focus), the Interrupt sound option. `AppSettings.swift` keys.
8. **`needsyou://focus` action.** Core: `FocusLink.parse` (`level` from the fixed set, `minutes` 1–720, nothing else), tests; `AppDelegate` URL handling next to `ConnectLink` and `OrcaJump`. It's not an item link: the hub doesn't accept it in items and `LinkPolicy` doesn't open it from cards (only the system URL handler reaches it), so no allow-list change. Docs: `docs/guides/mac-app.md` with a Shortcuts automation recipe.
9. **Spike: Focus filter metadata.** On a Mac with Xcode: add a minimal `SetFocusFilterIntent` to the app target behind `#if canImport(AppIntents)`; try (a) `xcrun appintentsmetadataprocessor` invoked from `mac/scripts/bundle.sh` after `swift build`, (b) `xcodebuild -scheme NeedsYou` on the package. Check that the filter shows in System Settings → Focus for the ad-hoc build, and that `perform()` runs on Focus on and off. Write the result into this file. `mac/scripts/test.sh` must still run without Xcode (keep the intent out of Core).
10. **Focus filter** (if 9 works). `mac/Sources/NeedsYou/FocusFilter.swift`: `NeedsYouFocusFilter` with *Level* and *Context* parameters and a display representation; `perform()` hops to the main actor and sets the filter-sourced `FocusState`. CI: the `mac` job's `bundle.sh` run fails if the metadata is missing. Docs: `docs/guides/mac-app.md`.
11. **Sender contract** (docs only). `docs/AGENT-GUIDE.md` rule 6 and `integrations/claude-code/skill/needs-you/SKILL.md`: urgent breaks through focus; low may wait for a digest.

## Open decisions

1. Default for normal items under "Quiet": Ambient (recommended) or Later?
2. Does a context switch by the schedule (for example 18:00) count as a "release Later" moment, or only the morning summary?
3. Should `done` items ever interrupt (a long job you were waiting on)? Recommended: no; a bypass rule can opt a key in.
4. Banners: revisit only with a Developer ID, and only if a click can be kept from activating the app.
