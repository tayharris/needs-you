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
- A card with **steps** shows them as a numbered checklist at your card text size, each step's link as a button. Tick steps off as you go (the ticks stay on this Mac; steps the agent already marked done are ticked for you); once every step is ticked the card offers **All steps done: mark Done**. With **Card text** set to First lines or Title only, the card shows "3 steps" until you click it.
- A card waiting 4 hours or more shows its age next to the title (`5 h`, `2 d`; amber after 2 days). Its **…** menu has **Dismiss All from <host>**, which clears every card and Recent row from that machine in this context, for when a machine went away without resolving its cards.
- **Right-click** the pill (or the button in the expanded header) to snooze everything: 15 min, 30 min, 1 hr, 3 hr, until tomorrow. Urgent items still pulse once through a snooze.
- **⌃⌥Space** shows or hides the panel. Change it in **Settings → Panel → Keyboard**.
- Drag the pill anywhere; it stays where you drop it (or snaps to a corner with **Snap to corners**) and remembers the spot per display setup. **Reset Position** in the right-click menu puts it back top right.

## Make it yours

Everything is in **Settings** (right-click the pill → **Settings…**). The defaults are the original look.

| Setting | Where | Choices (default first) |
|---|---|---|
| Size of the pill, the cards' type and the open panel | Panel → Look → **Size** | Regular, Compact, Large |
| Card body text (agents' step-by-step instructions) | Panel → Look → **Card text size** | Default, Small, Large, Extra large |
| How much of each card's text shows | Panel → Look → **Card text** | Full, First lines (3), Title only (click **Show details**) |
| Links on one short row | Panel → Look → **Compact links** | Off, On (3 links, `+N` shows the rest) |
| Cards before the list scrolls | Panel → Look → **Cards before scrolling** | As many as fit, 2, 3, 5, 8 |
| See-through when the pointer isn't over it | Panel → Look → **Opacity** | 100%, 90%, 80%, 70%, 60% |
| The global shortcut | Panel → Keyboard | ⌃⌥Space, or record your own (it must use ⌃, ⌥ or ⌘) |
| How loud urgent items are | Alerts → **Urgent items** | Normal, Off, Subtle, Bright (urgent never goes below Subtle) |
| How loud normal and low items are | Alerts → **Normal and low items** | Normal, Off, Subtle, Bright |
| The shortcut opens the top card's Terminal / VS Code link | Integrations | Off, On |

The Panel tab shows a sample card as you change things, and the Alerts tab plays each alert. **Advanced → Reset to defaults** puts the look and alerts back.

## Settings

Right-click the pill (or the menu bar icon) → **Settings…**. The look, alerts and shortcut are under **Make it yours** above; the rest:

- **You:** your name, shown as "needs &lt;name&gt;".
- **This Mac:** **Run hub on this Mac** (on by default) and the URL agents and servers post to.
- **Connect with link:** paste a `needsyou://connect?...` or `/join/...` link from another hub.
- **Invite a machine** and **Access:** see above.
- **Hubs:** server hubs added by hand (URL and token), polled in order.
- **Menu bar and panel:** the menu bar icon and count, hide the floating panel, urgent items show a hidden panel, snap to corners.
- **Behaviour:** demo mode, urgent items break through a snooze, open at login.

Built in, not settings yet:

- **Work hours:** weekdays 7:00–18:00 = work, everything else = personal. Items with the other context don't vanish; they show as the faint second number.
- **Start of day:** at 7:30 on weekdays the panel opens once with open work items (or on the first check after 7:30 if the Mac was asleep).
- **Live updates:** uses the hub's event stream when available, otherwise polls every 30 s.

[mac/README.md](../../mac/README.md) is authoritative for the details.
