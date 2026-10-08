# Set it up with an agent

Paste one prompt into Claude Code (or Codex, Gemini CLI, opencode, or any agent that can run shell commands) and it sets up needs-you on that machine: the Mac app, the agents it finds, and a test card. It stops and asks you at every choice: which agents to connect, whether other machines should reach this Mac, whether to replace an app you already have. It never installs Tailscale, logs in to anything or edits an agent's config itself; the needs-you installer does those edits, the same one an invite link runs.

Run it on your Mac first. On a server or devbox, paste the same prompt into its agent: it skips the app and connects that machine to your Mac.

## The prompt

```prompt
Set up needs-you for me on this machine. needs-you is a small inbox for "a person has to do something": agents and jobs post an alert when they're blocked on me, and the Needs You app on my Mac shows it. Guide: https://needsyou.app/guides/setup-with-an-agent.html. Source: https://github.com/tayharris/needs-you.

Rules for you, the whole way through:
- Where a step says ASK, stop, ask me, and wait. Never answer for me or pick a default I didn't choose.
- Look before you change anything, and only read: no installing system-wide, no sudo, no logging in to anything, no editing any agent's config yourself. The needs-you installer makes the config changes.
- Never print, paste or save a token or an invite code. Only the installer writes them (to ~/.config/needs-you/env). Don't repeat my invite link back to me. Never open credential files (auth.json, .credentials.json, hosts.yml, anything in the Keychain).

1. Look around (read-only), then show me a short list:
   - The OS: uname -s, and sw_vers -productVersion on a Mac.
   - needs-you already here? If ~/.local/bin/needs-you exists, run ~/.local/bin/needs-you doctor.
   - On a Mac, Needs You: /Applications/NeedsYou.app or ~/Applications/NeedsYou.app (or mdfind "kMDItemCFBundleIdentifier == 'app.needsyou.mac'"), its version (CFBundleShortVersionString in Contents/Info.plist), and whether it's running (pgrep -f NeedsYou.app/Contents/MacOS/NeedsYou). The latest release: curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/tayharris/needs-you/releases/latest
   - Tailscale: tailscale status --json (on a Mac the command may be /Applications/Tailscale.app/Contents/MacOS/Tailscale). Report only BackendState, Self.DNSName and how many peers.
   - Agents and tools: which of these are on PATH, or have their folder: claude (~/.claude), codex (~/.codex), gemini (~/.gemini), opencode (~/.config/opencode), copilot (~/.copilot), kimi (~/.kimi-code), grok (~/.grok), cursor or cursor-agent (~/.cursor), cline (~/Documents/Cline), aider (~/.aider.conf.yml), orca, gh. For accounts, run only status commands that print no secrets (gh auth status, codex login status); otherwise say only whether the folder exists.

2. Explain, in a few sentences and these words: the app runs on my Mac and shows alerts in a small pill at the top of the screen. A hub stores the alerts; the app has one built in, so there's nothing else to run. Senders are the machines and agents that post alerts with the needs-you command; they join with an invite link from the app. A server hub is optional: the same hub, always on, on a Linux server, so alerts land while the Mac sleeps. Tailscale is only needed so other machines can reach this Mac's hub.

3. The app (Mac only; on any other OS skip to step 5, because the app runs on my Mac and this machine becomes a sender).
   - Installed and the latest: say so, and open it if it isn't running (open -g -a <its path>).
   - Missing or older: ASK "Install Needs You <version> to /Applications?", or "Replace Needs You <old> at <path> with <new>? The old copy is kept as NeedsYou.app.previous". On yes: in a new empty temp folder, download NeedsYou-<version>-macos.zip and SHA256SUMS from https://github.com/tayharris/needs-you/releases/download/v<version>/ with curl -fL. Run shasum -a 256 -c SHA256SUMS --ignore-missing and stop if the zip isn't OK. Unpack with ditto -x -k <zip> <folder>/app. Install with the app's own installer: <folder>/app/NeedsYou.app/Contents/Resources/scripts/install.sh --app <folder>/app/NeedsYou.app. Add --dest ~/Applications if /Applications isn't writable without sudo. It quits a running copy, swaps the new one in, keeps the previous one and opens the new one.
   - A curl download carries no quarantine flag, so macOS shouldn't block it. If xattr -p com.apple.quarantine <app> shows one, ASK, then remove it from that app only: xattr -dr com.apple.quarantine <app>. Never turn Gatekeeper off or change security settings.
   - Tell me: a faint pill appears at the top right of the screen. If macOS asks whether python3 may accept incoming connections, choose Allow (that's the built-in hub). If the app says Python 3 isn't available, ASK before running xcode-select --install (it opens Apple's installer).

4. Other machines (Mac only). ASK: "Should other machines (servers, a devbox, CI) send alerts to this Mac?" If yes and Tailscale isn't installed or logged in, tell me to install it from https://tailscale.com/download and log in myself, then check again. Don't install it or log in for me. Then ASK: "Do you want an always-on server hub too? Most people don't." If yes, point me to https://needsyou.app/guides/hub.html: it's set up on the server, not from here.

5. Senders. Show me the agents and tools you found in step 1, and what each gets, then ASK which ones to connect (none is fine):
   - Claude Code: --claude-hooks user --skill
   - Codex: --codex-hooks user
   - Gemini CLI: --gemini-hooks user
   - opencode: --opencode-plugin
   - GitHub Copilot CLI: --copilot-hooks user
   - Kimi Code: --kimi-hooks user
   - Grok Build: --grok-hooks user
   - Cursor: --cursor-hooks user
   - Cline: --cline-hooks user
   - Aider: --aider
   - Orca: --orca
   Add --alerts when I pick any agent (cards from every session, not only Orca's). Then ASK about each extra, and add it only on a yes: --usage (a card when Claude Code's 5-hour or weekly limit runs high, for Pro and Max plans), --mcp <agents> (the MCP server, for agents that should post through a tool call), --agent-instructions codex,gemini,opencode (the posting rules in their instruction files). Daily automatic updates are on by default; tell me that, and add --no-auto-update only if I ask. If gh is installed, offer the GitHub poller as a later step (https://needsyou.app/guides/github.html); don't set it up now.
   Then ASK me for an invite: in the app, click the pill, then Settings… > Connect a machine > Create invite > Agent prompt (on a new install, the pill's "Connect your first agent or machine" card has Copy agent prompt), and paste it here. On a machine other than the Mac, the invite comes from the Mac's app, and this machine must reach the Mac (step 4). Read the join page the link points to (curl -fsSL <link>; it's Markdown for agents). Then run its one-line installer with exactly the flags I picked: curl -fsSL <link>/install.sh | bash -s -- --yes <flags>. If it says the link is unknown, expired or used up, ASK me for a new one.

6. Check.
   - Run ~/.local/bin/needs-you doctor. For each WARN or FAIL line, run the next step printed under it if it's a command for this machine; otherwise tell me what it needs.
   - Post a test card: ~/.local/bin/needs-you add --key "personal:test:hello" --context personal --title "needs-you works on $(hostname -s)". Tell me what to look for: a card springs out of the pill on my Mac, and clicking the pill opens the panel with it. ASK whether I see it; if not, follow https://needsyou.app/guides/troubleshooting.html.
   - Clear it: ~/.local/bin/needs-you resolve --key "personal:test:hello". It leaves the panel within a few seconds.
   - Finish with a summary: what was installed and where, which agents need a restart to pick up their hooks (and for Codex, that I trust the needs-you hooks once in /hooks), that daily updates are on (or off), and that needs-you doctor checks everything again any time.
```

## What it does, and doesn't

| Step | What the agent does | Where it stops to ask |
|---|---|---|
| 1. Look around | Reads: the OS, an existing `needs-you`, the app and its version, `tailscale status --json`, which agents are on `PATH` or have a config folder. Account status only from commands that print no secrets. | — |
| 2. Explain | App, hub, senders, server hub and Tailscale, in the words of the [glossary](concepts.md). | — |
| 3. The app (Mac) | Downloads the release zip, checks it against `SHA256SUMS`, installs it with the app's own `install.sh` (keeps the previous copy), opens it. | Before installing or replacing, before removing a quarantine flag, before `xcode-select --install` |
| 4. Other machines | Checks Tailscale; never installs it or logs in. | Whether other machines should connect; whether you want a [server hub](../HUB.md) |
| 5. Senders | Runs the invite's one-line installer with the flags you picked. | Which agents, each extra (`--usage`, `--mcp`, `--agent-instructions`), and the invite link itself |
| 6. Check | `needs-you doctor`, a test card, then resolves it. | Whether the card showed up |

The installer is the same one the **Shell one-liner** runs ([Add a sender](add-a-sender.md#options)): it installs the CLI in `~/.local/bin`, writes `~/.config/needs-you/env` (mode 600), schedules the 5-minute flush, turns on daily updates ([Keeping up to date](updates.md)) and posts a test card. Your agent never sees the token: the installer redeems the invite and writes it straight to that file.

Things it won't do: run `sudo`, turn Gatekeeper off, install or log in to Tailscale, read credential files, or change an agent's settings outside the installer. If you'd rather click through it yourself, the [Quickstart](quickstart.md) has the same steps.

## Other agents

The prompt is plain text with shell commands, so any agent that runs commands can follow it. Paste it as your first message:

- **Claude Code, Codex, Gemini CLI, opencode, Copilot CLI, Kimi Code, Grok Build:** as is. Each asks before running commands unless you've allowed them.
- **Cursor and Cline:** in an agent chat with terminal access.
- **Aider:** it can't run a setup like this one. Use the [Quickstart](quickstart.md), then add `--aider` to the one-liner.

## Already set up?

Paste it anyway: step 1 runs `needs-you doctor` and the agent only offers what's missing. Re-running the installer keeps the machine's token and the settings you don't change. A machine set up before daily updates were the default gets them turned on when the installer runs again; `needs-you update --enable-auto` does the same without an invite.
