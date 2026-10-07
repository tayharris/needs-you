# Needs You for macOS

A small floating pill that shows what your machines, projects and agents need from you. **It runs its own hub**, so there's no server to set up: agents and servers post straight to your Mac over Tailscale (or to `localhost` if they run on the Mac). Remote, always-on hubs are an optional extra. The pill sits on every Space and over full-screen apps, and it never takes focus from what you're typing.

- Idle: a small, faint pill reading `Nothing needs <you>` (about 35% opacity), so you can always drag it or right-click to hide it. Hover shows `all clear · needs <you> · this Mac · <time>`.
- Waiting: a count pill with a priority-coloured ring. The other context's count shows faintly (`3 · 1`), and `2 new` counts what arrived or changed since you last opened the panel. **Settings → Panel → Collapsed pill** sets the pill's own size, whether it also shows the top card's title or only a coloured dot (count on hover), and a work | personal or by-priority split.
- New item: the pill springs out to a preview of it for 14 s (**Settings → Alerts → Arrivals**: 5 / 10 / 14 / 20 / 30 s, or until you click or point at it). Pointing at the preview holds it; it goes 2 s after the pointer leaves.
- Click: a 360 pt card list (urgent → normal → low, then Recent). It stays open when you click in another app or open a card's link, so you can keep reading the card; Escape, the chevron or the shortcut closes it (**Settings → Panel → Open panel → Collapse when clicking elsewhere** brings back the old behaviour). Drag its free edge (the bottom, or the top when the panel sits in a bottom corner) to make the list taller or shorter; double-click the edge for the automatic height. Links open only for allowed schemes (`https`, `slack`, `vscode`, `cursor`, `figma`, `msteams`, `discord`, `linear`; `vscode`/`cursor` only in the shapes of `LinkPolicy.editorLinkPattern`). The app's own actions, `needsyou://orca/terminal` and `needsyou://terminal/focus` (`OrcaJump`, `TerminalJump` in Core; `OrcaJumpRunner`, `TerminalJumpRunner` in the app), are the **Terminal** button; see [docs/guides/mac-app.md](../docs/guides/mac-app.md#terminal-button).
- Right-click the pill, or use the moon button in the header, to snooze for 15 min / 30 min / 1 hr / 3 hr / until tomorrow. **⌃⌥Space** (or the shortcut you record in Settings → Panel → Keyboard) shows or hides it.
- Cards waiting 4 h or more show their age by the title (`5 h`, `2 d`, amber after 2 days). A card's **…** menu has **Dismiss All from <host>**.
- Drag it anywhere, on any display, in any state (idle, count, preview, or by the expanded header). It stays exactly where you drop it (pulled back onto the screen if it would be lost off an edge), remembered per display layout. When it expands or shows a new item, it grows away from the nearest screen edges. **Settings → Panel → Snap to corners** (off by default) snaps it to the nearest corner instead. **Reset Position** (menu bar menu or right-click) puts it back in the top-right corner.
- A menu bar icon shows the same count (see below).

Requires macOS 14 and Swift 5.10 or later. The Command Line Tools are enough; Xcode is not needed. The built-in hub uses Apple's `/usr/bin/python3`, which comes with the Command Line Tools.

## Install

```bash
cd mac
scripts/install.sh      # release build (scripts/bundle.sh, ad-hoc signed) → /Applications/NeedsYou.app, launched in the background
```

`scripts/bundle.sh` alone just builds `dist/NeedsYou.app`.

The app shows as **Needs You**; the file is `NeedsYou.app` (no space, so scripts don't need quoting). It's an agent app (`LSUIElement`): no Dock icon and no app menus. Look for the pill in the top-right corner and the pill-shaped icon in the menu bar.

To update an installed copy, use `scripts/install.sh` (see [Updating](#updating)) rather than copying over a running app.

**Open at login:** in Settings, turn on **Open at login**. This registers the app with `SMAppService.mainApp`, so run it from `/Applications` first. If macOS asks, approve it in System Settings → General → Login Items. To remove it, turn the toggle off, or remove it from that list.

**Gatekeeper / security tools:** the build is ad-hoc signed (`codesign -s -`). A copy you built yourself runs without a prompt. A copy someone sends you may need right-click → Open the first time. Endpoint security tools (SentinelOne and similar) may flag ad-hoc signed apps. Developer ID signing is on the roadmap (`docs/roadmap/distribution.md`). Since the app keeps nothing in the Keychain, a new ad-hoc signature on every build doesn't cause password prompts.

## Menu bar icon

On by default (Settings → Panel → **Show menu bar icon**). It's a monochrome template icon, so it follows the menu bar's light or dark look.

- With open `needs` items it shows the count, tinted with the highest priority's colour (**Show count in menu bar**, on by default). A small dot on the icon means the hub can't be reached.
- The menu: a status line (`All clear · This Mac`, `3 need you · hub2`); the top 5 open items (clicking one opens its first allowed link, or shows the panel expanded); **Show Floating Panel** (checked while it's shown); **Snooze ▸** 15 min / 30 min / 1 hr / 3 hr / until tomorrow; **Reset Position**; **Work** / **Personal**; **Invite a Machine…** (only with an owner token); **Settings…**; **About Needs You**; **Quit Needs You**, which stops the local hub cleanly.
- Opening the menu never activates the app or takes focus. Only Settings…, Invite a Machine… and About bring a window forward.

### Hiding the floating panel

Hide it from the menu bar (**Show Floating Panel**), the pill's right-click menu (**Hide Floating Panel**), the **×** in the expanded header, or the shortcut (**⌃⌥Space** by default). It stays hidden across launches until you show it again the same ways.

- While it's hidden, new items only update the menu bar count. An urgent item gives the icon one brief pulse. Turn on **Urgent items show the panel even when hidden** (off by default) to have urgent items bring the panel back instead.
- A snooze is different: it ends by itself, and **Urgent items break through a snooze** (on by default) still applies to it.
- The menu bar icon and the panel can't both be hidden. With the icon off, hiding the panel is refused (the shortcut beeps); with the panel hidden, the icon can't be turned off.

## Settings

Settings is a sidebar of short pages, like System Settings (a `NavigationSplitView`; the page list is `SettingsTab` in `NeedsYouCore/SettingsPages.swift`). Each page has a title and a one-line summary, each setting a one-line explanation, and every page scrolls. The window opens at 760 × 520 (smaller on a short screen; at least 640 × 420).

- **General**: a first-run welcome (when no hub is set up), your name, **Open at login**, demo mode.
- **Hubs**:
  - **This Mac**: **Run hub on this Mac** and its two addresses with **Copy**: *On this Mac* (`http://127.0.0.1:8765`) and *From your other machines (Tailscale)* (`http://<name>.<tailnet>.ts.net:8765`, or the 100.x address). Without Tailscale it says why other machines can't reach the hub and links to the Tailscale guide.
  - **Join a hub**: join someone else's hub with a link made for this Mac (see [Join a hub with a link](#join-a-hub-with-a-link)).
  - **Invite a machine**: see [below](#invite-a-machine). Without an owner token it says how to get one.
  - **Access**: open invites and machines, with **Revoke** (only with an owner token).
  - **Hubs (manual)**: the hand-entered hub list (the This Mac row also shows its tailnet URL).
- **Panel**: **Collapsed pill** (with sample pills) — Pill size (small / medium / large, on top of Size), Shows (count only / count and top item / minimal dot), Split (none / work | personal / by priority), New since last opened (on); **Look** (with a live sample card) — Size (compact / regular / large: the pill, the cards' type and the open panel's width), Card text size (small / default / large / extra large, body text only), Card text (full / first 3 lines / title only), Compact links, Cards before scrolling (as many as fit / 2 / 3 / 5 / 8), Opacity (100–60 % when not hovered); Show floating panel, menu bar icon and count, Snap to corners; **Open panel**: Collapse when clicking elsewhere (off by default), and the list height set by dragging the panel's edge, with **Automatic** to undo it; **Keyboard**: the global shortcut with **Change…** (records the next key press in the Settings window; Esc cancels) and whether it registered.
- **Alerts**: Urgent items and Normal and low items, each Off / Subtle / Normal / Bright (the glow, how many times it pulses, the ring, and a tint at Bright). Urgent never goes below Subtle. The preview pills play the style when it changes. **Arrivals**: how long the new-item preview (and the "3 waited" Later peek) stays out, 14 s by default. Also: urgent breaks through a snooze, urgent shows a hidden panel, the work/personal schedule and the morning summary. **Delivery**: the tier (Interrupt / Ambient / Later) for normal, low, done/info and other-context items, Urgent items break through Focus, Allow focus links from other apps, and a table of what each focus level does. **Bypass rules** (key prefix, agent prefix or host; at most 50). **On the work screen**: where previews spring out, and the urgent edge glow. Focus itself is in the right-click and menu bar menus, or `needsyou://focus` ([docs/guides/mac-app.md](../docs/guides/mac-app.md#focus-heads-down-except-what-you-choose)).
- **Integrations**: **Hotkey also opens the top card's first link** (off by default): the shortcut runs the top card's Terminal jump or opens its VS Code window (or first allowed link) instead of showing or hiding the panel, and shows or hides as usual when there's nothing to open. Live updates (SSE).
- **Updates**: see [docs/guides/updates.md](../docs/guides/updates.md).
- **Advanced**: **Reset to defaults** for the look and alerts.

Menu items and links open a given page with `SettingsWindowController.show(tab:)`: **Invite a Machine…** opens Invite a machine, a `needsyou://connect` link opens Join a hub.

Every default is the original look, except two deliberate changes: arrivals stay out 14 s (was 4 s) and the open panel no longer collapses on a click elsewhere. The values are plain keys in `defaults read app.needsyou.mac` (`panelSize`, `cardTextSize`, `cardBodies`, `compactLinks`, `maxVisibleCards`, `panelOpacity`, `pillSize`, `pillDetail` (`count`, `topItem`, `dot`), `pillSplit` (`none`, `context`, `priority`), `pillShowNew`, `pillLastOpenedAt` (seconds since 1970, set when the panel opens and closes), `alertStyleUrgent`, `alertStyleOther`, `hotKey` as `control+option+space`, `hotKeyOpensTopLink`, `tierNormal`, `tierLow`, `tierDoneInfo`, `tierOtherContext`, `urgentBreaksFocus`, `allowFocusLinks`, `bypassRules` (JSON), `previewDisplay`, `edgeGlow`, `previewSeconds` (0 = until clicked or pointed at), `collapseOnClickOutside`, `expandedListHeight` (points, 0 = automatic), and the current focus as `focusLevel`/`focusUntil`/`focusSource`); an unknown or invalid value falls back to the default. The size and alert tables are in `NeedsYouCore` (`PanelStyle.swift`, `PillContent.swift`, `AlertStyle.swift`, `CardLayout.swift`, `HotKeyCombo.swift`, `Delivery.swift`, `BypassRules.swift`, `FocusLink.swift`, `WorkDisplay.swift`, `PanelBehavior.swift`) with tests.

A shortcut needs ⌃, ⌥ or ⌘, and ones macOS or every app owns (⌘Space, ⌃Space, ⌘Tab, ⌘Q, the screenshot keys, ...) are refused. If the new one is taken by another app, the old one stays.

## The hub on this Mac (default)

**Run hub on this Mac** is on by default (Settings → This Mac). At launch the app starts the bundled hub (`Contents/Resources/hub/needs_you_hub.py`) as a child process:

- It listens on `127.0.0.1:8765` and, if the Mac is on a tailnet, on its Tailscale address (100.64.0.0/10). Never on `0.0.0.0`.
- Other machines are told to use the Mac's MagicDNS name (from `tailscale status --json`), else its Tailscale IP, else `http://127.0.0.1:8765`.
- Data lives in `~/Library/Application Support/NeedsYou/` (`hub.db`, plus `owner.token`, mode 600). The hub's output goes to the unified log, not to files: `log stream --predicate 'subsystem == "app.needsyou.mac"'`.
- If the hub exits it's restarted with backoff. When the network changes or the Mac wakes, the app re-checks the Tailscale address and restarts the hub if it moved. Quitting the app stops the hub (and the hub exits by itself if the app dies).
- This Mac is always first in the hub list, with an owner token, so **Invite a machine** works straight away.

If Settings says Python isn't available, install Apple's command line tools (`xcode-select --install`), or turn the local hub off and connect to a remote hub. If it says port 8765 is in use, quit whatever holds it (`lsof -nP -iTCP:8765 -sTCP:LISTEN`).

## Invite a machine

In Settings → **Invite a machine** (it needs an owner token, which the local hub gives you; without one the page says how to get one): enter a name, pick a role (**Sender** for a server or agent, **Another Mac** = reader, or **Owner** = reader that can invite too), the number of uses (1–20) and an expiry, then **Create invite**. Copy one of:

- **Agent prompt**: paste into an agent (Claude Code, etc.) on the new machine: "Set up needs-you alerts on this machine: read <join_url> and follow it."
- **Shell one-liner**: run on the new machine: `curl -fsSL <join_url>/install.sh | bash -s -- --yes`.
- **Mac link**: for another Mac (reader/owner invites); open it there.

Tailscale is recommended: the join URL uses the hub's MagicDNS name (`…ts.net`). Any https URL also works.

## Join a hub with a link

This is the receiving side: to read from someone else's hub (or your own always-on hub), get a Mac invite link made for this Mac. It comes from another Mac's Settings → **Invite a machine** (role **Another Mac** or **Owner**, then **Mac link**), or from a server hub's admin (`needs-you-admin invite create my-mac --role owner`, which prints the link). Then either:

- click/open the `needsyou://connect?hub=…&code=…` link (the app asks first, opens Settings → **Join a hub** and shows the result), or
- paste it, or an `http(s)://<hub>/join/<code>` URL, into Settings → **Join a hub**. When the page opens and the clipboard holds a join link, it's filled in for you ("Found a link on your clipboard"); **Paste** does the same by hand. Only text `ConnectLink.parse` accepts goes into the field, and a link for this Mac's own hub is never prefilled (`ConnectLinkClipboard` in Core). The clipboard is read only while that page is open.

The app redeems the code (sending this Mac's host name), adds every hub URL the hub returns to your list (deduplicated, after this Mac), and stores the token and its role in `tokens.json` for each. Tokens replicate between hubs, so one token works on all of them. A used or expired link, an unreachable hub, or a plain `http://` URL that isn't on Tailscale each get a clear message.

## Manual setup (fallback)

In Settings → **Hubs (manual)**, add a hub URL, e.g. `http://hub-a.example.ts.net:8765`, and a read/patch token you were given. Press **Test**, then **Save & Connect**. Hubs are polled in order (this Mac first): the first reachable one is used and the next takes over on errors or timeouts. A failed hub is retried after 2 minutes. The hover line shows which one is in use. Hand-entered tokens have no known role, so they don't enable inviting.

Tokens are stored in `tokens.json` (see [Where config lives](#where-config-lives)). Hub URLs and other settings are in `defaults read app.needsyou.mac`.

Plain `http://` is allowed for `*.ts.net` (Tailscale MagicDNS), `localhost`, IP addresses and local network names; Tailscale encrypts the traffic. Any other host needs `https://`.

**Just looking?** Click **Try demo mode** in Settings → General (or turn on **Demo mode** there) to see fixture items, with a new one arriving every 45 s. Demo mode doesn't run the hub.

## Where config lives

Nothing is kept in the Keychain. Everything is in two places:

| What | Where |
|---|---|
| Remote hub tokens and their roles | `~/Library/Application Support/NeedsYou/tokens.json` (directory mode 700, file mode 600, written atomically, keyed by hub URL) |
| The local hub's items, tokens (hashed), invites | `~/Library/Application Support/NeedsYou/hub.db` |
| The local hub's owner token | `~/Library/Application Support/NeedsYou/owner.token` (mode 600) |
| Hub URLs, your name, toggles, panel positions | `defaults read app.needsyou.mac` |

- If `tokens.json` doesn't parse, it's moved aside to `tokens.json.corrupt-<time>` and the app starts with no remote tokens (re-connect with a link). Nothing is deleted.
- Prefs carry a `prefsVersion`. Migrations only move forward and never delete keys, so rolling back to an older build loses nothing.
- **Upgrading from a build that used the Keychain:** remote hub tokens used to be in the login Keychain. This build deliberately never reads it (on a Mac whose login keychain password is out of sync, every access prompts, endlessly). Re-connect each remote hub once with a Mac link from its owner (Settings → **Join a hub**), or paste its token under **Hubs (manual)**; Settings points out which hubs need it. The hub on this Mac needs nothing: its token was already file-only. The old Keychain items are harmless; delete them in Keychain Access (search "NeedsYou") if you like.

## Updating

```bash
cd mac
scripts/install.sh                 # build, quit the running app, swap it in, relaunch
scripts/install.sh --rollback      # back to the previous version (run again to undo)
scripts/install.sh --app path/to/NeedsYou.app   # install a build you already have
```

`install.sh` builds with `scripts/bundle.sh`, copies the new app next to the installed one with `ditto`, then quits the running app gracefully by bundle id (it stops its hub cleanly) and waits for it to exit, falling back to SIGTERM (which the app also treats as Quit). It moves the old copy to `/Applications/NeedsYou.app.previous`, moves the new one into place, and relaunches it in the background (`open -g`, no focus steal). If the new version doesn't stay running, the previous one is put back. The path, bundle id and data stay the same, so settings, tokens, the hub's data and the login item carry over.

`scripts/upgrade-test.sh` runs the whole update and rollback against throwaway copies: a test bundle id, `--dest` in a temp dir, a temp support dir and defaults suite, and a hub on a random high port. It never touches `/Applications` or the running app.

## Staying small

The app keeps nothing on disk except a few `UserDefaults` keys and the files above (the hub's own database is the hub's business):

- In memory it holds only open items. Closed ones are dropped as soon as the hub says so; local "done/dismiss" markers expire after 24 h (500 at most), and card snoozes go when they end or their item closes.
- Network requests use one ephemeral `URLSession` with no URL cache and no cookies.
- Panel positions are remembered for the 10 most recently used display layouts; tokens and their roles are pruned with the hub list.
- Switching hubs cancels the old poll loop and stream; there's one 15 s UI timer for the app's lifetime.

## Develop

```bash
swift build                                  # debug build of everything
scripts/test.sh                              # unit tests (see below)
NEEDS_YOU_DEMO=1 swift run NeedsYou          # run in demo mode without bundling
NEEDS_YOU_DEMO=1 dist/NeedsYou.app/Contents/MacOS/NeedsYou &   # the bundle, in demo mode
NEEDS_YOU_SUPPORT_DIR=$(mktemp -d) dist/NeedsYou.app/Contents/MacOS/NeedsYou &   # throwaway hub data
```

`open` doesn't pass environment variables (except with `open --env`), so run the binary inside the bundle directly. A copy with the real bundle id still writes AppKit's own state (window and status item positions) to the real app's defaults domain; for a fully separate trial copy build one with another id: `NEEDS_YOU_BUNDLE_ID=app.needsyou.mac.trial NEEDS_YOU_NO_URL_SCHEME=1 NEEDS_YOU_DIST=/tmp/ny scripts/bundle.sh`. Useful variables:

| Variable | Effect |
|---|---|
| `NEEDS_YOU_DEMO=1` | Demo feed, no hub |
| `NEEDS_YOU_DEMO_INJECT_SECONDS=n` | Demo: a new item every n s (default 45, 0 = off) |
| `NEEDS_YOU_DEMO_FIXTURE=file.json` | Demo seed items (the hub's list shape) |
| `NEEDS_YOU_POLL_SECONDS=n` | Poll interval (default 30; 5 in demo) |
| `NEEDS_YOU_EXPAND=1` | Start expanded (still never takes focus) |
| `NEEDS_YOU_SNAPSHOT_DIR=dir` | Write a PNG of each panel state into dir (no Screen Recording permission needed) |
| `NEEDS_YOU_SUPPORT_DIR=dir` | `hub.db`, `owner.token` and `tokens.json` here instead of Application Support |
| `NEEDS_YOU_DEFAULTS_SUITE=name` | Read and write settings in this defaults suite instead of `app.needsyou.mac` |
| `NEEDS_YOU_HUB_PORT=n` | Run the local hub on port n instead of 8765 (test copies next to the real app) |
| `NEEDS_YOU_HUB_LOOPBACK_ONLY=1` | Local hub on 127.0.0.1 only; skip the tailnet address and `tailscale status` |
| `NEEDS_YOU_HUB_SCRIPT=path` | Run this `needs_you_hub.py` instead of the bundled one |

`swift run NeedsYou` finds the hub at `../hub/needs_you_hub.py` in the repo. `scripts/bundle.sh` copies `hub/`, `cli/needs-you` and `integrations/claude-code/` into `Contents/Resources/` with the repo layout, so the hub serves the CLI and the Claude Code files to joining machines (`/dl`).

To try a link by hand: `open 'needsyou://connect?hub=http%3A%2F%2F127.0.0.1%3A9&code=bogus'` should show "Couldn't reach the hub" in Settings.

**Tests.** `swift test` needs XCTest, which ships with Xcode but not with the Command Line Tools. `scripts/test.sh` runs `swift test` when XCTest is available. Otherwise it runs the same test files (symlinked into `Sources/NeedsYouSelfTest`) through the tiny `MiniXCTest` shim with `swift run needsyou-selftest`. When you add a test class, register it in `Sources/NeedsYouSelfTest/main.swift` and symlink the file. Network tests use a stubbed `URLProtocol`.

**Layout.**

- `Sources/NeedsYouCore`: model, hub client, failover, demo feed, merge/count rules, link policy, limited markdown, snooze/schedule maths, panel geometry and free positioning, `FloatingPanel`, connect links and invites (`Connect.swift`), the local hub's command line and network detection (`LocalHub.swift`), bounded prefs and `prefsVersion` migrations (`Prefs.swift`), the `tokens.json` store (`TokenStore.swift`), menu bar rules and text (`MenuBar.swift`). Unit-tested.
- `Sources/NeedsYou`: the app (AppKit `NSPanel` + SwiftUI). `LocalHubController` runs the hub child; `ConnectController` redeems links and creates invites; `MenuBarController` owns the status item. `Phase3/` holds the new-item preview, work/personal schedule, 7:30 summary and SSE. It plugs in through `AppModel` hooks and can be removed.
- `Resources/Info.plist`: bundle metadata (`app.needsyou.mac`, display name "Needs You", `LSUIElement`, the `needsyou` URL scheme, ATS exceptions).

**Focus rule.** The panel must never become key or main, and must never activate the app. `FloatingPanel` hard-wires `canBecomeKey`/`canBecomeMain` to false, and `FloatingPanelTests` guards it. The only code that activates the app is `SettingsWindowController.show()` and `AboutPanel.show()`, which run only from a user click (Settings…, Invite a Machine…, the set-up pill, About, or opening a `needsyou://` link). The menu bar menu and dragging the pill never activate it. Starting or restarting the hub never activates anything. Don't put text fields or focusable views in the panel.
