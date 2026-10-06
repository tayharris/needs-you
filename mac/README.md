# needs-you for macOS

A small floating pill that shows what your machines, projects and agents need from you. It reads from one or more needs-you hubs (see `../docs/PLAN.md`). It sits on every Space and over full-screen apps, and it never takes focus from what you're typing.

- Idle: a faint 28×10 pill. Hover shows `all clear · needs <you> · <hub> · <time>`.
- Waiting: a count pill with a priority-coloured ring. The other context's count shows faintly (`3 · 1`).
- Click: a 360 pt card list (urgent → normal → low, then Recent). Links open only for allowed schemes (`https`, `orca`, `slack`, `vscode`, `cursor`, `figma`, `msteams`, `discord`).
- Right-click the pill, or use the moon button in the header, to snooze for 15 min / 30 min / 1 hr / 3 hr / until tomorrow. **⌃⌥Space** shows or hides it.
- Drag it anywhere: it snaps to the nearest corner, remembered per display layout.

Requires macOS 14 and Swift 5.10 or later. The Command Line Tools are enough; Xcode is not needed.

## Install

```bash
cd mac
scripts/bundle.sh                       # release build → dist/NeedsYou.app (ad-hoc signed)
cp -R dist/NeedsYou.app /Applications/  # or: ditto dist/NeedsYou.app /Applications/NeedsYou.app
open /Applications/NeedsYou.app
```

It's an agent app (`LSUIElement`): no Dock icon and no menu bar. Look for the pill in the top-right corner.

**Open at login:** in Settings, turn on **Open at login**. This registers the app with `SMAppService.mainApp`, so run it from `/Applications` first. If macOS asks, approve it in System Settings → General → Login Items. To remove it, turn the toggle off, or remove it from that list.

**Gatekeeper / security tools:** the build is ad-hoc signed (`codesign -s -`). A copy you built yourself runs without a prompt. A copy someone sends you may need right-click → Open the first time. Endpoint security tools (SentinelOne and similar) may flag ad-hoc signed apps; sign with a Developer ID if that happens.

## Connect to a hub

1. Click the pill. With no hub configured it shows a slightly brighter "set up" state, and clicking it opens Settings. (Settings is also in the pill's right-click menu and behind the gear in the expanded view.)
2. Under **You**, enter your name. The panel then reads "needs Sam" (blank = "needs you").
3. Under **Hubs**, enter the hub URL, e.g. `http://hub.example.ts.net:8765`, and the read/patch token you were given. Press **Test**, then **Save & Connect**.
4. Add more hubs for redundancy. They're polled in order: the first reachable one is used, and the next takes over on errors or timeouts. A failed hub is retried after 2 minutes. Hubs replicate to each other, so it doesn't matter which one answers. The hover line shows which one is in use.

Tokens are stored in your login Keychain (service `app.needsyou.mac`, one item per hub URL). Hub URLs and other settings are in `defaults read app.needsyou.mac`.

Plain `http://` is allowed for `*.ts.net` (Tailscale MagicDNS) and local network names; Tailscale encrypts the traffic. Any other host needs `https://`.

**No hub yet?** Click **Try demo mode** in Settings to see fixture items, with a new one arriving every 45 s.

## Develop

```bash
swift build                                  # debug build of everything
scripts/test.sh                              # unit tests (see below)
NEEDS_YOU_DEMO=1 swift run NeedsYou          # run in demo mode without bundling
NEEDS_YOU_DEMO=1 dist/NeedsYou.app/Contents/MacOS/NeedsYou &   # the bundle, in demo mode
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

**Tests.** `swift test` needs XCTest, which ships with Xcode but not with the Command Line Tools. `scripts/test.sh` runs `swift test` when XCTest is available. Otherwise it runs the same test files (symlinked into `Sources/NeedsYouSelfTest`) through the tiny `MiniXCTest` shim with `swift run needsyou-selftest`. When you add a test class, register it in `Sources/NeedsYouSelfTest/main.swift` and symlink the file.

**Layout.**

- `Sources/NeedsYouCore`: model, hub client, failover, demo feed, merge/count rules, link policy, limited markdown, snooze/schedule maths, panel geometry, `FloatingPanel`. Unit-tested.
- `Sources/NeedsYou`: the app (AppKit `NSPanel` + SwiftUI). `Phase3/` holds the new-item preview, work/personal schedule, 7:30 summary and SSE. It plugs in through `AppModel` hooks and can be removed.
- `Resources/Info.plist`: bundle metadata (`app.needsyou.mac`, `LSUIElement`, ATS exceptions).

**Focus rule.** The panel must never become key or main, and must never activate the app. `FloatingPanel` hard-wires `canBecomeKey`/`canBecomeMain` to false, and `FloatingPanelTests` guards it. The only code that activates the app is `SettingsWindowController.show()`, which runs only from a user click. Don't put text fields or focusable views in the panel.
