# The Mac app

`NeedsYou.app` is the only thing that shows anything. It's a small floating panel (no Dock icon; an optional menu bar icon) that polls your hubs and stays out of the way until something needs you.

Build, install and signing details live with the code: **[mac/README.md](../../mac/README.md)**. This page is the short version for users.

## Install

1. Download `NeedsYou-X.Y.Z.dmg` (or `NeedsYou-X.Y.Z-macos.zip`) from the repository's **Releases** page, plus `SHA256SUMS` if you want to check it (`shasum -a 256 -c SHA256SUMS`). Or build it per [mac/README.md](../../mac/README.md).
2. Drag `NeedsYou.app` to `/Applications` and open it. It's ad-hoc signed, not notarized, so macOS blocks the first launch once: on macOS 14 and earlier, right-click → **Open** → **Open**; on macOS 15 and later, double-click, then **System Settings → Privacy & Security → Open Anyway**. Or: `xattr -dr com.apple.quarantine /Applications/NeedsYou.app`. On a managed work Mac, endpoint security (e.g. SentinelOne) may flag ad-hoc signed builds; ask IT.
3. The built-in hub needs `/usr/bin/python3` (Apple's Command Line Tools). If **Settings…** says *Python 3 isn't available on this Mac*, run `xcode-select --install`, then quit and reopen the app.
4. Optional: **Settings… → Behaviour → Open at login**.

## Its own hub

The app runs a hub itself (`hub/needs_you_hub.py` with the Mac's `/usr/bin/python3`, as a child process that exits with the app). It listens on `127.0.0.1:8765`, and on the Mac's tailnet address whenever Tailscale is up (there's no separate switch; **Settings… → This Mac** shows the URL servers use). It provisions its own `owner` token, so there's nothing to configure. The first time a server connects, macOS may ask whether `python3` may accept incoming connections: allow it.

- **Invite a machine** (right-click the pill → **Settings…**) makes an invite link plus a prompt to paste into an agent ([add-a-sender.md](add-a-sender.md)). **Access** (just below) lists open invites and every machine's token, with a **Revoke** button for each ([Removing a sender](add-a-sender.md#removing-a-sender)).
- **Server hubs (optional):** open a `needsyou://connect?hub=...&code=...` link from a server hub's owner invite, and the app adds that hub (its token goes in `~/Library/Application Support/NeedsYou/tokens.json`, mode 600; nothing is kept in the Keychain) and fails over between hubs.

While the Mac sleeps its hub is offline: senders queue items and deliver them within about 5 minutes of it waking. Always-on [server hubs](../HUB.md) avoid the wait.

The exact settings and how the app passes options to its hub are in [mac/README.md](../../mac/README.md).

## Using it

| You see | It means |
|---|---|
| A barely visible pill | Nothing needs you. Hover for "all clear" and the last check time. |
| A pill with a number and a colored ring | Open `needs` items in the current context. Red = urgent, amber = normal, slate = low. |
| `3 · 1` | 3 in the current context, 1 waiting in the other (work vs personal). |
| The pill springs out with a title | A new item just arrived. |

- **Click** the pill to expand the cards; **Escape** or click outside to collapse.
- On a card: **Done** (resolve), **Dismiss**, or snooze just that card. Links open in the browser or in their app (`orca:`, `slack:`, `vscode:`, ...).
- **Right-click** the pill (or the button in the expanded header) to snooze everything: 15 min, 30 min, 1 hr, 3 hr, until tomorrow. Urgent items still pulse once through a snooze.
- **⌃⌥Space** shows or hides the panel, without taking focus from what you're typing.
- Drag the pill anywhere; it stays where you drop it, remembered per display setup. **Snap to corners** (Settings, off by default) snaps it to the nearest corner instead; **Reset Position** in the right-click menu puts it back top right.

## Settings

Right-click the pill (or the menu bar icon) → **Settings…**:

- **You:** your name, shown as "needs &lt;name&gt;".
- **This Mac:** **Run hub on this Mac** (on by default) and the URL agents and servers post to.
- **Connect with link:** paste a `needsyou://connect?...` or `/join/...` link from another hub.
- **Invite a machine** and **Access:** see above.
- **Hubs:** server hubs added by hand (URL and token), polled in order.
- **Menu bar and panel:** the menu bar icon and count, hide the floating panel, urgent items show a hidden panel, snap to corners.
- **Behaviour:** demo mode, urgent items break through a snooze, open at login, and the show/hide shortcut (⌃⌥Space, not configurable yet).

Built in, not settings yet:

- **Work hours:** weekdays 7:00–18:00 = work, everything else = personal. Items with the other context don't vanish; they show as the faint second number.
- **Start of day:** at 7:30 on weekdays the panel opens once with open work items (or on the first check after 7:30 if the Mac was asleep).
- **Live updates:** uses the hub's event stream when available, otherwise polls every 30 s.

[mac/README.md](../../mac/README.md) is authoritative for the details.
