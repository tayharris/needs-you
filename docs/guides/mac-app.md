# The Mac app

`NeedsYou.app` is the only thing that shows anything. It's a small floating panel (no Dock icon; an optional menu bar icon) that polls your hubs and stays out of the way until something needs you.

Build, install and signing details live with the code: **[mac/README.md](../../mac/README.md)**. This page is the short version for users.

## Install

1. Download `NeedsYou-X.Y.Z.dmg` (or `NeedsYou-X.Y.Z-macos.zip`) from the repository's **Releases** page, plus `SHA256SUMS` if you want to check it (`shasum -a 256 -c SHA256SUMS`), and check its build provenance with `gh attestation verify NeedsYou-X.Y.Z.dmg --repo tayharris/needs-you` ([release-signing.md](../security/release-signing.md)). Or build it per [mac/README.md](../../mac/README.md).
2. Drag `NeedsYou.app` to `/Applications` and open it. It's ad-hoc signed, not notarized, so macOS blocks the first launch once: on macOS 14 and earlier, right-click → **Open** → **Open**; on macOS 15 and later, double-click, then **System Settings → Privacy & Security → Open Anyway**. Or: `xattr -dr com.apple.quarantine /Applications/NeedsYou.app`. On a managed work Mac, endpoint security (e.g. SentinelOne) may flag ad-hoc signed builds; ask IT.
3. The built-in hub needs `/usr/bin/python3` (Apple's Command Line Tools). If **Settings…** says *Python 3 isn't available on this Mac*, run `xcode-select --install`, then quit and reopen the app.
4. Optional: **Settings… → General → Open at login**.

## Its own hub

The app runs a hub itself (`hub/needs_you_hub.py` with the Mac's `/usr/bin/python3`, as a child process that exits with the app). It listens on `127.0.0.1:8765`, and on the Mac's tailnet address whenever Tailscale is up (there's no separate switch; **Settings… → This Mac** shows the URL servers use, next to the `127.0.0.1` one). It provisions its own `owner` token, so there's nothing to configure. The first time a server connects, macOS may ask whether `python3` may accept incoming connections: allow it.

- **Invite a machine** (right-click the pill → **Settings…**) makes an invite link plus a prompt to paste into an agent ([add-a-sender.md](add-a-sender.md)). **Access** (the next page in the sidebar) lists open invites and every machine's token, with a **Revoke** button for each ([Removing a sender](add-a-sender.md#removing-a-sender)).
- **Server hubs (optional):** open a `needsyou://connect?hub=...&code=...` link from a server hub's owner invite, and the app adds that hub (its token goes in `~/Library/Application Support/NeedsYou/tokens.json`, mode 600; nothing is kept in the Keychain) and fails over between hubs.

While the Mac sleeps its hub is offline: senders queue items and deliver them within about 5 minutes of it waking. Always-on [server hubs](../HUB.md) avoid the wait.

The exact settings and how the app passes options to its hub are in [mac/README.md](../../mac/README.md).

## Using it

| You see | It means |
|---|---|
| A barely visible pill | Nothing needs you. Hover for "all clear" and the last check time. |
| A pill with a number and a colored ring | Open `needs` items in the current context. Red = urgent, amber = normal, slate = low. |
| `3 · 1` | 3 in the current context, 1 waiting in the other (work vs personal). Settings → Panel → **Collapsed pill** can show them as `W 3 \| P 1` instead, or split by priority. |
| `3 +2`, a moon | 2 more are waiting under Later; a focus is on (see [Focus](#focus-heads-down-except-what-you-choose)). |
| `3` `2 new` | 2 of the 3 arrived (or changed, or turned into `needs`) since you last opened the panel. Opening it clears the badge. |
| The pill springs out with a title | A new item just arrived. It stays out 14 s; point at it to keep it there, click it to open the panel. |

- **Click** the pill to expand the cards. It stays open when you click in another app or open a card's link, so you can keep reading the card next to what it opened. **Escape**, the chevron in the header or the shortcut closes it. (Escape goes to the app you clicked into until you point at the panel again.) To have a click elsewhere close it, turn on **Settings → Panel → Open panel → Collapse when clicking elsewhere**.
- Drag the open panel's free edge (the bottom, or the top when the panel sits in a bottom corner) to make the card list taller or shorter. It remembers the height; double-click the edge, or **Settings → Panel → Open panel → Automatic**, to go back to fitting the cards.
- On a card: **Done** (resolve), **Dismiss**, or snooze just that card. Links open in the browser or in their app (`orca:`, `slack:`, `vscode:`, `linear:`, ...). A **Terminal** button on an agent's card brings forward the terminal it runs in and marks the card done ([Terminal button](#terminal-button)).
- A card with **steps** shows them as a numbered checklist at your card text size, each step's link as a button. Tick steps off as you go (the ticks stay on this Mac; steps the agent already marked done are ticked for you); once every step is ticked the card offers **All steps done: mark Done**. With **Card text** set to First lines or Title only, the card shows "3 steps" until you click it.
- A card waiting 4 hours or more shows its age next to the title (`5 h`, `2 d`; amber after 2 days). Its **…** menu has **Dismiss All from <host>**, which clears every card and Recent row from that machine in this context, for when a machine went away without resolving its cards.
- **Right-click** the pill (or the button in the expanded header) to snooze everything: 15 min, 30 min, 1 hr, 3 hr, until tomorrow. Urgent items still pulse once through a snooze. What else arrives while snoozed waits under **Later** (below).
- **⌃⌥Space** opens the card list, or collapses it when it's open (a hidden panel comes back open). Double-clicking the open panel's header bar also collapses it. Change it in **Settings → Panel → Keyboard**.
- Drag the pill anywhere; it stays where you drop it (or snaps to a corner with **Snap to corners**) and remembers the spot per display setup. **Reset Position** in the right-click menu puts it back top right.

### Setup tips

While something isn't set up yet, the open panel shows a **setup tip**: a card like any other, from **Needs You setup**, with a button and a link to the guide. The idle pill says so (`Nothing needs you · 1 setup tip`).

| Tip | Shows when | Button |
|---|---|---|
| **Turn on the hub on this Mac** | **Run hub on this Mac** is off and no other hub is set up | **Open Settings** (This Mac) |
| **Connect your first agent or machine** | The hub answers, but nothing has ever posted to it and it lists no token besides this Mac's | **Copy agent prompt**: makes a one-use sender invite (24 hours) and copies the prompt to paste into Claude Code |
| **Reach this Mac from your other machines** | The hub on this Mac listens on `127.0.0.1` only (no Tailscale) and you have server hubs or cards from other machines | **Open Settings**, and the [Tailscale guide](tailscale.md) |
| **Install the Claude Code hooks on this Mac** | `~/.claude` exists but `~/.claude/settings.json` doesn't use the needs-you hook, after the first sender connected | **Copy agent prompt**, and the [Claude Code guide](claude-code.md) |

Setup tips stay on this Mac: they're never sent to a hub, never count in the pill or the menu bar, never spring out or pulse, and aren't in the menu bar menu or the shortcut's "top card". A tip goes for good once its condition is met (turning the hub off later doesn't bring the first one back), or when you click **Dismiss**. **Settings → Panel → Setup tips** turns them off and has **Show Again** for dismissed ones. The card only says the prompt was copied; the invite link is only on the clipboard (and in **Settings → Invite a machine**, which shows the invite it made). While no hub is set up at all, clicking the **Set up Needs You** pill opens the panel with the first tip (with tips off, it opens Settings as before).

## Focus: heads-down, except what you choose

Every new item arrives one of three ways:

| Tier | What you see | In the count |
|---|---|---|
| **Interrupt** | The pill springs out with the title and a glow (urgent pulses twice) | Yes |
| **Ambient** | The count and ring change, with one soft glow | Yes |
| **Later** | Nothing. It waits in a **Later** section at the bottom of the open panel (a faint `+3` on the pill) | No |

With no focus: urgent and normal interrupt, low and done/info are ambient, the other context's items are the faint second number. **Right-click the pill** or open the **menu bar menu** → **Focus**:

| Focus | Interrupts | Waits under Later |
|---|---|---|
| **Agents and urgent only** | Urgent items, and agent cards (keys starting `agent:`, which every Claude Code session uses) | Everything else |
| **Urgent only** | Urgent items | Everything else |
| **Everything later** | Nothing (only an "Always interrupt" rule) | Everything, urgent too |

Each for **30 min**, **1 hr**, **2 hr** or **until tomorrow** (7:00). A moon on the pill shows a focus is on; **Focus → Off** ends it. When a focus or a snooze ends (and when the work day starts), whatever waited comes back in one quiet peek, "3 waited while you were focused", and joins the count. **Show now** in the Later section brings them back early.

Two guards: an urgent item breaks through a focus unless you turn off **Settings → Alerts → Urgent items break through Focus** (for a presentation), and a sender that would interrupt more than 6 times in an hour is held to ambient for the rest of it (the open panel says so).

**Settings → Alerts → Delivery** sets the tier for normal, low, done/info and other-context items, and shows a table of what each focus does. **Bypass rules** (same tab) override everything, top to bottom, first match wins: match a **key prefix** (`agent:`, `work:gh:deploy:`), a sender **agent** prefix (`orca:`, `claude-code`) or a **host** (`devbox`), and choose **Always interrupt**, **Never interrupt** (ambient at most) or **Always later**. A hidden panel stays hidden; bypass never means taking focus.

### Drive it from Shortcuts or a script

The app handles `needsyou://focus?level=<level>[&minutes=<n> | &until=tomorrow]`, with `level` one of `off`, `agents` (agents and urgent only), `urgent`, `later` (everything later). Anything else in the link is refused and does nothing.

Any app or web page can open a `needsyou://` link, so a focus link is fenced in:

- **It asks first.** Until you turn on **Settings → Alerts → Allow focus links from other apps (Shortcuts, scripts)** (off by default), the app asks "Turn on Focus … ?" before applying one. `level=off` never asks: it only makes alerts louder.
- **It always ends.** `minutes` is capped at 720 (12 h; larger numbers are cut to 12 h), `until=tomorrow` ends at 7:00, and a link with neither lasts 12 h.
- **Urgent always gets through.** A focus a link set never holds back urgent items, whatever the level or the "Urgent items break through Focus" setting.
- **You can see it.** The pill shows a small link badge next to the moon, and **Focus** in the menus has **Set by a link · Turn off**.

From a script or Terminal, use `open -g` so nothing comes forward:

```bash
open -g 'needsyou://focus?level=urgent&minutes=60'
open -g 'needsyou://focus?level=off'
```

To follow a macOS Focus, first turn on **Allow focus links from other apps** (otherwise each automation run asks), then make two personal automations in the **Shortcuts** app → **Automation** → **+**:

1. **When "Work" Focus turns on** (any Focus you like) → **Run Immediately** → action **Run Shell Script**: `open -g 'needsyou://focus?level=agents'`.
2. **When "Work" Focus turns off** → **Run Shell Script**: `open -g 'needsyou://focus?level=off'`.

(The **Open URLs** action works too, but it may bring Needs You forward for a moment; the app hands focus straight back. `Run Shell Script` with `open -g` doesn't.)

## Make it yours

Everything is in **Settings** (right-click the pill → **Settings…**). The defaults are the original look, except that new items stay out 14 s (was 4 s) and the open panel no longer collapses when you click elsewhere.

| Setting | Where | Choices (default first) |
|---|---|---|
| Size of the pill, the cards' type and the open panel | Panel → Look → **Size** | Regular, Compact, Large |
| Card body text (agents' step-by-step instructions) | Panel → Look → **Card text size** | Default, Small, Large, Extra large |
| How much of each card's text shows | Panel → Look → **Card text** | Full, First lines (3), Title only (click **Show details**) |
| Links on one short row | Panel → Look → **Compact links** | Off, On (3 links, `+N` shows the rest) |
| Cards before the list scrolls | Panel → Look → **Cards before scrolling** | As many as fit, 2, 3, 5, 8 |
| Close the open panel when you click in another app or open a link | Panel → Open panel → **Collapse when clicking elsewhere** | Off, On |
| The open panel's list height | Panel → Open panel → **List height** (drag the panel's edge) | Automatic, or the height you dragged |
| How see-through the collapsed pill and the open panel are | Panel → **Opacity**: Collapsed pill, Collapsed pill pointer over it, Open panel (also previews), Open panel pointer over it | 100% to 30% (defaults 85%, 100%, 100%, 100%) |
| Size of the collapsed pill only | Panel → Collapsed pill → **Pill size** | Medium, Small, Large |
| What the collapsed pill says | Panel → Collapsed pill → **Shows** | Count only; Count and top item (the top card's title, truncated); Minimal dot (a dot in the top priority's colour, the count on hover) |
| How the count is split | Panel → Collapsed pill → **Split** | None (`3 · 1`); Work \| Personal (`W 3 \| P 1`, the current side brighter); By priority (urgent, normal and low counts in their colours, empty ones hidden) |
| The `2 new` badge | Panel → Collapsed pill → **New since last opened** | On, Off |
| Cards about what isn't set up yet ([Setup tips](#setup-tips)) | Panel → Setup tips → **Show setup tips** | On, Off |
| The global shortcut | Panel → Keyboard | ⌃⌥Space, or record your own (it must use ⌃, ⌥ or ⌘) |
| How loud urgent items are | Alerts → **Urgent items** | Normal, Off, Subtle, Bright (urgent never goes below Subtle) |
| How loud normal and low items are | Alerts → **Normal and low items** | Normal, Off, Subtle, Bright |
| How long a new item's preview stays out (also the "3 waited" Later peek) | Alerts → Arrivals → **Show new items for** | 14 s, 5 s, 10 s, 20 s, 30 s, Until I click or point at it (pointing at it always holds it) |
| How normal / low / done and info / other-context items arrive | Alerts → **Delivery** | Interrupt, Ambient, Ambient, Later (see [Focus](#focus-heads-down-except-what-you-choose)) |
| Urgent items break through Focus | Alerts → Delivery | On, Off |
| Focus links from other apps apply without asking | Alerts → Delivery | Off (ask), On |
| Bypass rules | Alerts → **Bypass rules** | None; up to 50 |
| Where new items spring out | Alerts → On the work screen | The pill's display (default), The display you're working on |
| Edge glow | Alerts → On the work screen | Off, Urgent arrivals |

The Panel tab shows a sample card as you change things, and the Alerts tab plays each alert. **Advanced → Reset to defaults** puts the look and alerts back.

## Terminal button

Agent cards from the Claude Code hook (and Orca) carry a **Terminal** button: an app action, not a web link. Clicking it shows you the terminal the session runs in and marks the card done.

| Link | What the app does |
|---|---|
| `needsyou://orca/terminal?handle=term_…` | `orca terminal switch`, then Orca comes forward |
| `needsyou://terminal/focus?app=wezterm&pane=<n>` | `wezterm cli activate-pane --pane-id <n>`, then WezTerm comes forward |
| `needsyou://terminal/focus?app=tmux&pane=<n>[&host=<terminal>]` (or `target=<session>:<window>.<pane>`) | `tmux select-window` and `select-pane`, then the terminal tmux runs in comes forward |
| `needsyou://terminal/focus?app=iterm&session=<UUID>` (or `tty=/dev/ttys<n>`) | Selects that iTerm2 session with AppleScript (opt-in, below), else brings iTerm2 forward |
| `needsyou://terminal/focus?app=terminal&tty=/dev/ttys<n>` | Selects the Terminal tab on that tty with AppleScript (opt-in), else brings Terminal forward |
| `needsyou://terminal/focus?app=ghostty` | Brings Ghostty forward |

**iTerm2 and Terminal** need **Settings → Integrations → Jump to iTerm2 and Terminal tabs** (off by default). Turning it on asks macOS for the Automation permission for each app that's running (System Settings → Privacy & Security → Automation lists it); **Check again** asks again after you open the other one. The panel itself never asks.

What keeps a card from doing more than switching tabs:

- Every link is parsed into a fixed shape: exactly the parameters above, each at most once, each value matching its pattern (digits, a UUID, `/dev/ttys` and digits, a tmux session name), none starting with `-`. Anything else does nothing.
- The CLIs run from fixed paths (`/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, the WezTerm app), never from `PATH`, with an argument list and a 5 s timeout. No shell.
- The AppleScript is fixed text compiled once; the session id or tty is passed to a handler as a typed parameter, never pasted into the script.
- The jump activates the terminal, never Needs You.
- A terminal link opened from **outside** the app (a web page, a chat message, `open 'needsyou://terminal/…'`) asks first: **Switch to a terminal?** The card's own button doesn't ask.

If a CLI switch fails (the pane is gone), the command goes on the clipboard. Logs: Console, subsystem `app.needsyou.mac`, category `terminal-jump`. Setting the hook up, including SSH sessions: [Claude Code alerts everywhere → Terminal button](claude-code-everywhere.md#terminal-button).

## Settings

Right-click the pill (or the menu bar icon) → **Settings…**. Settings is a sidebar of short pages, like System Settings. The look, alerts and shortcut are under **Make it yours** above; the pages:

- **General:** your name (shown as "needs &lt;name&gt;"), open at login, demo mode. A first-run welcome shows here when no hub is set up.
- **Hubs → This Mac:** **Run hub on this Mac** (on by default) and its two addresses, each with **Copy**: **On this Mac** (`http://127.0.0.1:8765`, for agents on the Mac) and **From your other machines (Tailscale)** (`http://<name>.<tailnet>.ts.net:8765`). Without Tailscale it says other machines can't reach the hub and links to the [Tailscale guide](tailscale.md).
- **Hubs → Join a hub:** the receiving side. Paste a `needsyou://connect?...` or `/join/...` link that someone made for this Mac, and it joins their hub. The link comes from another Mac's **Settings → Invite a machine** (role **Another Mac**) or from a server hub's admin (`needs-you-admin invite create my-mac --role owner`). If the clipboard already holds such a link when the page opens, it's filled in for you; **Paste** does the same by hand. Opening a `needsyou://connect` link does all of this by itself, after asking.
- **Hubs → Invite a machine** and **Access:** see above. Access shows only when you have an owner token.
- **Hubs → Hubs (manual):** server hubs added by hand (URL and token), tried in order. The This Mac row shows its Tailscale URL too.
- **Panel:** look, the floating panel and menu bar icon, snap to corners, the keyboard shortcut.
- **Alerts:** how loud new items are, delivery and focus, snooze and hidden-panel rules, bypass rules, the work screen.
- **Integrations:** **Jump to iTerm2 and Terminal tabs** ([Terminal button](#terminal-button)).
- **Updates** ([guide](updates.md)) and **Advanced** (reset the look and alerts).

Built in, not settings yet:

- **Work hours:** weekdays 7:00–18:00 = work, everything else = personal. Items with the other context don't vanish; they show as the faint second number.
- **Start of day:** at 7:30 on weekdays the panel opens once with open work items (or on the first check after 7:30 if the Mac was asleep).
- **Live updates:** uses the hub's event stream when available, otherwise polls every 30 s.

[mac/README.md](../../mac/README.md) is authoritative for the details.
