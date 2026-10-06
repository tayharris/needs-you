# The Mac app

`NeedsYou.app` is the only thing that shows anything. It's a small floating panel (no Dock icon, no menu-bar item) that polls your hubs and stays out of the way until something needs you.

Build, install and signing details live with the code: **[mac/README.md](../../mac/README.md)**. This page is the short version for users.

## Install

1. Build `NeedsYou.app` per [mac/README.md](../../mac/README.md), or use a build someone gave you.
2. Move it to `/Applications` and open it. If macOS blocks an unsigned build, right-click → **Open** once. On a managed work Mac, endpoint security (e.g. SentinelOne) may flag ad-hoc signed builds; ask IT or use a build signed with a Developer ID.
3. Optional: **System Settings → General → Login Items** → add NeedsYou so it starts at login.

## Its own hub

The app runs a hub itself (`hub/needs_you_hub.py` with the Mac's `/usr/bin/python3`, as a child process that exits with the app). It listens on `127.0.0.1:8765`, and on the Mac's tailnet address whenever Tailscale is up (there's no separate switch; **Settings… → This Mac** shows the URL servers use). It provisions its own `owner` token, so there's nothing to configure. The first time a server connects, macOS may ask whether `python3` may accept incoming connections: allow it.

- **Invite a machine** (right-click the pill → **Settings…**) makes an invite link plus a prompt to paste into an agent ([add-a-sender.md](add-a-sender.md)). There's no revoke button yet; see [Removing a sender](add-a-sender.md#removing-a-sender).
- **Server hubs (optional):** open a `needsyou://connect?hub=...&code=...` link from a server hub's owner invite, and the app adds that hub (its token goes in the Keychain) and fails over between hubs.

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
- **⌃⌥Space** shows or hides the panel (the default shortcut; check Settings).
- Drag the pill anywhere; it snaps to the nearest corner and remembers the spot per display setup.

## Other settings

- **Display:** main display, the display with the cursor, or a specific one.
- **Work hours:** defaults to weekdays 7:00–18:00 = work, everything else = personal. Items with the other context don't vanish; they show as the faint second number.
- **Start of day:** at 7:30 on weekdays the panel opens once with open work items, oldest first (or on first wake after 7:30).
- **Live updates:** uses the hub's event stream when available, otherwise polls every 30 s.

The exact settings list can change; [mac/README.md](../../mac/README.md) is authoritative.
