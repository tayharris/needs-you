# Needs You for macOS

A small floating pill that shows what your machines, projects and agents need from you. **It runs its own hub**, so there's no server to set up: agents and servers post straight to your Mac over Tailscale (or to `localhost` if they run on the Mac). Remote, always-on hubs are an optional extra. The pill sits on every Space and over full-screen apps, and it never takes focus from what you're typing.

- Idle: a faint 28×10 pill. Hover shows `all clear · needs <you> · this Mac · <time>`.
- Waiting: a count pill with a priority-coloured ring. The other context's count shows faintly (`3 · 1`).
- Click: a 360 pt card list (urgent → normal → low, then Recent). Links open only for allowed schemes (`https`, `orca`, `slack`, `vscode`, `cursor`, `figma`, `msteams`, `discord`).
- Right-click the pill, or use the moon button in the header, to snooze for 15 min / 30 min / 1 hr / 3 hr / until tomorrow. **⌃⌥Space** shows or hides it.
- Drag it anywhere: it snaps to the nearest corner, remembered per display layout.

Requires macOS 14 and Swift 5.10 or later. The Command Line Tools are enough; Xcode is not needed. The built-in hub uses Apple's `/usr/bin/python3`, which comes with the Command Line Tools.

## Install

```bash
cd mac
scripts/bundle.sh                       # release build → dist/NeedsYou.app (ad-hoc signed)
cp -R dist/NeedsYou.app /Applications/  # or: ditto dist/NeedsYou.app /Applications/NeedsYou.app
open /Applications/NeedsYou.app
```

The app shows as **Needs You**; the file is `NeedsYou.app` (no space, so scripts don't need quoting). It's an agent app (`LSUIElement`): no Dock icon and no menu bar. Look for the pill in the top-right corner.

**Open at login:** in Settings, turn on **Open at login**. This registers the app with `SMAppService.mainApp`, so run it from `/Applications` first. If macOS asks, approve it in System Settings → General → Login Items. To remove it, turn the toggle off, or remove it from that list.

**Gatekeeper / security tools:** the build is ad-hoc signed (`codesign -s -`). A copy you built yourself runs without a prompt. A copy someone sends you may need right-click → Open the first time. Endpoint security tools (SentinelOne and similar) may flag ad-hoc signed apps; sign with a Developer ID if that happens.

## The hub on this Mac (default)

**Run hub on this Mac** is on by default (Settings → This Mac). At launch the app starts the bundled hub (`Contents/Resources/hub/needs_you_hub.py`) as a child process:

- It listens on `127.0.0.1:8765` and, if the Mac is on a tailnet, on its Tailscale address (100.64.0.0/10). Never on `0.0.0.0`.
- Other machines are told to use the Mac's MagicDNS name (from `tailscale status --json`), else its Tailscale IP, else `http://127.0.0.1:8765`.
- Data lives in `~/Library/Application Support/NeedsYou/` (`hub.db`, plus `owner.token`, mode 600, with a copy in the Keychain). The hub's output goes to the unified log, not to files: `log stream --predicate 'subsystem == "app.needsyou.mac"'`.
- If the hub exits it's restarted with backoff. When the network changes or the Mac wakes, the app re-checks the Tailscale address and restarts the hub if it moved. Quitting the app stops the hub (and the hub exits by itself if the app dies).
- This Mac is always first in the hub list, with an owner token, so **Invite a machine** works straight away.

If Settings says Python isn't available, install Apple's command line tools (`xcode-select --install`), or turn the local hub off and connect to a remote hub. If it says port 8765 is in use, quit whatever holds it (`lsof -nP -iTCP:8765 -sTCP:LISTEN`).

## Invite a machine

In Settings → **Invite a machine** (shown when you have an owner token, which the local hub gives you): enter a name, pick a role (**Sender** for a server or agent, **Another Mac** = reader, or **Owner** = reader that can invite too), the number of uses (1–20) and an expiry, then **Create invite**. Copy one of:

- **Agent prompt**: paste into an agent (Claude Code, etc.) on the new machine: "Set up needs-you alerts on this machine: read <join_url> and follow it."
- **Shell one-liner**: run on the new machine: `curl -fsSL <join_url>/install.sh | bash -s -- --yes`.
- **Mac link**: for another Mac (reader/owner invites); open it there.

Tailscale is recommended: the join URL uses the hub's MagicDNS name (`…ts.net`). Any https URL also works.

## Connect with a link

To read from someone else's hub (or your own always-on hub), get a Mac invite link from its owner and either:

- click/open the `needsyou://connect?hub=…&code=…` link (the app opens Settings and shows the result), or
- paste it, or an `http(s)://<hub>/join/<code>` URL, into Settings → **Connect with link**.

The app redeems the code (sending this Mac's host name), adds every hub URL the hub returns to your list (deduplicated, after this Mac), and stores the token and its role in the Keychain for each. Tokens replicate between hubs, so one token works on all of them. A used or expired link, an unreachable hub, or a plain `http://` URL that isn't on Tailscale each get a clear message.

## Manual setup (fallback)

Under **Hubs**, add a hub URL, e.g. `http://hub.example.ts.net:8765`, and a read/patch token you were given. Press **Test**, then **Save & Connect**. Hubs are polled in order (this Mac first): the first reachable one is used and the next takes over on errors or timeouts. A failed hub is retried after 2 minutes. The hover line shows which one is in use. Hand-entered tokens have no known role, so they don't enable inviting.

Tokens are stored in your login Keychain (service `app.needsyou.mac`, one item per hub URL). Hub URLs and other settings are in `defaults read app.needsyou.mac`.

Plain `http://` is allowed for `*.ts.net` (Tailscale MagicDNS), `localhost`, IP addresses and local network names; Tailscale encrypts the traffic. Any other host needs `https://`.

**Just looking?** Click **Try demo mode** in Settings to see fixture items, with a new one arriving every 45 s. Demo mode doesn't run the hub.

## Staying small

The app keeps nothing on disk except a few `UserDefaults` keys and the Keychain items (the hub's own database is the hub's business):

- In memory it holds only open items. Closed ones are dropped as soon as the hub says so; local "done/dismiss" markers expire after 24 h (500 at most), and card snoozes go when they end or their item closes.
- Network requests use one ephemeral `URLSession` with no URL cache and no cookies.
- Panel positions are remembered for the 10 most recently used display layouts; token roles are pruned with the hub list.
- Switching hubs cancels the old poll loop and stream; there's one 15 s UI timer for the app's lifetime.

## Develop

```bash
swift build                                  # debug build of everything
scripts/test.sh                              # unit tests (see below)
NEEDS_YOU_DEMO=1 swift run NeedsYou          # run in demo mode without bundling
NEEDS_YOU_DEMO=1 dist/NeedsYou.app/Contents/MacOS/NeedsYou &   # the bundle, in demo mode
NEEDS_YOU_SUPPORT_DIR=$(mktemp -d) dist/NeedsYou.app/Contents/MacOS/NeedsYou &   # throwaway hub data
```

`open` doesn't pass environment variables, so run the binary inside the bundle directly. Useful variables:

| Variable | Effect |
|---|---|
| `NEEDS_YOU_DEMO=1` | Demo feed, no hub or Keychain access |
| `NEEDS_YOU_DEMO_INJECT_SECONDS=n` | Demo: a new item every n s (default 45, 0 = off) |
| `NEEDS_YOU_DEMO_FIXTURE=file.json` | Demo seed items (the hub's list shape) |
| `NEEDS_YOU_POLL_SECONDS=n` | Poll interval (default 30; 5 in demo) |
| `NEEDS_YOU_EXPAND=1` | Start expanded (still never takes focus) |
| `NEEDS_YOU_SNAPSHOT_DIR=dir` | Write a PNG of each panel state into dir (no Screen Recording permission needed) |
| `NEEDS_YOU_SUPPORT_DIR=dir` | Local hub data (`hub.db`, `owner.token`) here instead of Application Support; the Keychain copy is left alone |
| `NEEDS_YOU_HUB_SCRIPT=path` | Run this `needs_you_hub.py` instead of the bundled one |

`swift run NeedsYou` finds the hub at `../hub/needs_you_hub.py` in the repo. `scripts/bundle.sh` copies `hub/`, `cli/needs-you` and `integrations/claude-code/` into `Contents/Resources/` with the repo layout, so the hub serves the CLI and the Claude Code files to joining machines (`/dl`).

To try a link by hand: `open 'needsyou://connect?hub=http%3A%2F%2F127.0.0.1%3A9&code=bogus'` should show "Couldn't reach the hub" in Settings.

**Tests.** `swift test` needs XCTest, which ships with Xcode but not with the Command Line Tools. `scripts/test.sh` runs `swift test` when XCTest is available. Otherwise it runs the same test files (symlinked into `Sources/NeedsYouSelfTest`) through the tiny `MiniXCTest` shim with `swift run needsyou-selftest`. When you add a test class, register it in `Sources/NeedsYouSelfTest/main.swift` and symlink the file. Network tests use a stubbed `URLProtocol`.

**Layout.**

- `Sources/NeedsYouCore`: model, hub client, failover, demo feed, merge/count rules, link policy, limited markdown, snooze/schedule maths, panel geometry, `FloatingPanel`, connect links and invites (`Connect.swift`), the local hub's command line and network detection (`LocalHub.swift`), bounded prefs (`Prefs.swift`). Unit-tested.
- `Sources/NeedsYou`: the app (AppKit `NSPanel` + SwiftUI). `LocalHubController` runs the hub child; `ConnectController` redeems links and creates invites. `Phase3/` holds the new-item preview, work/personal schedule, 7:30 summary and SSE. It plugs in through `AppModel` hooks and can be removed.
- `Resources/Info.plist`: bundle metadata (`app.needsyou.mac`, display name "Needs You", `LSUIElement`, the `needsyou` URL scheme, ATS exceptions).

**Focus rule.** The panel must never become key or main, and must never activate the app. `FloatingPanel` hard-wires `canBecomeKey`/`canBecomeMain` to false, and `FloatingPanelTests` guards it. The only code that activates the app is `SettingsWindowController.show()` and the About item, which run only from a user click (Settings, the set-up pill, About, or opening a `needsyou://` link). Starting or restarting the hub never activates anything. Don't put text fields or focusable views in the panel.
