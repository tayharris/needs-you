# The Mac app

`NeedsYou.app` is the only thing that shows anything. It's a small floating panel (no Dock icon, no menu-bar item) that polls your hubs and stays out of the way until something needs you.

Build, install and signing details live with the code: **[mac/README.md](../../mac/README.md)**. This page is the short version for users.

## Install

1. Build `NeedsYou.app` per [mac/README.md](../../mac/README.md), or use a build someone gave you.
2. Move it to `/Applications` and open it. If macOS blocks an unsigned build, right-click → **Open** once. On a managed work Mac, endpoint security (e.g. SentinelOne) may flag ad-hoc signed builds; ask IT or use a build signed with a Developer ID.
3. Optional: **System Settings → General → Login Items** → add NeedsYou so it starts at login.

## First-run settings

| Setting | What to enter |
|---|---|
| Hub URLs | Your hubs in failover order, e.g. `http://hub-a.<tailnet>.ts.net:8765, http://hub-b.<tailnet>.ts.net:8765`. The app polls the first that answers. |
| Token | The Mac's **read/patch** token (it can read, resolve and dismiss, but not create items). Stored in the Keychain. |

The Mac must be on the tailnet (Tailscale running) to reach the hubs. When it's asleep or off the tailnet, nothing is lost: senders write to the hubs, and the app catches up when it reconnects.

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
