# Fresh-user test plan

Status: plan. Run it on the first release draft (`.github/workflows/release.yml`), before anyone outside the repo gets a link.

Goal: someone who isn't the author can install needs-you from a GitHub Release, connect an agent and a server, and get an item, using only the release notes and the guides. Record every place they had to guess in a findings table like [doc-test-findings.md](doc-test-findings.md).

## Setup

Use one of these, in order of preference:

1. **A second Mac** that has never had needs-you, Xcode or the Command Line Tools. Check: `xcode-select -p` fails, and `/Applications/NeedsYou.app`, `~/Library/Application Support/NeedsYou` and `~/.config/needs-you` don't exist.
2. **A new standard (non-admin) user account** on your Mac. The Command Line Tools are machine-wide, so this account can't test the "no Command Line Tools" path; do that part on (1) or skip it. Quit the main account's NeedsYou first (it holds port 8765), or expect and record the "port in use" behavior.

The tester gets: the draft release's URL and nothing else. No repo checkout, no Swift, no brew. A collaborator account can see a draft release on a private repo; otherwise download the assets and hand them over with `SHA256SUMS`.

Write down: macOS version, Apple silicon or Intel, managed (MDM or EDR) or not, Tailscale installed or not.

## A. Download and first launch

| # | Step | Expect | Record |
|---|---|---|---|
| A1 | Download `NeedsYou-X.Y.Z-macos.zip` and `SHA256SUMS`; run `shasum -a 256 -c SHA256SUMS` in Downloads | The zip line says `OK` (the other assets show as missing; that's fine) | Wording that confused them |
| A2 | Unzip, drag `NeedsYou.app` to `/Applications`, double-click | macOS refuses: it can't verify the developer | The exact dialog text and buttons, per macOS version |
| A3 | Follow the release notes: **Privacy & Security → Open Anyway** (macOS 15+), or right-click → **Open** (14 and earlier) | The app opens; a pill appears; Settings opens with "Welcome to Needs You" | Whether the notes' steps matched the screens |
| A4 | Alternative: `xattr -dr com.apple.quarantine /Applications/NeedsYou.app` | Opens without the dialog | — |
| A5 | Managed Mac only: watch for an EDR alert or the app being killed | Nothing, or an alert to write down | Product name and the alert text |

## B. No Command Line Tools (second Mac only)

| # | Step | Expect | Record |
|---|---|---|---|
| B1 | Turn on **Run hub on this Mac** | No "install command line tools" dialog pops on its own. Settings shows *Python 3 isn't available on this Mac. Install Apple's command line tools (`xcode-select --install`) or connect to a remote hub.* | Whether any system dialog appeared |
| B2 | Run `xcode-select --install`, finish the install | — | How long it took |
| B3 | Quit and reopen NeedsYou | The hub starts: "Running. Agents and servers post to …" | Whether it needed a reopen, or a toggle off/on |

## C. Firewall prompt

| # | Step | Expect | Record |
|---|---|---|---|
| C1 | Turn on the macOS firewall (**System Settings → Network → Firewall**), with Tailscale up | When the hub binds the tailnet address, macOS asks whether `python3` may accept incoming connections | The exact text and which binary it names |
| C2 | Click **Allow**; from another tailnet machine: `curl -s http://<mac>.<tailnet>.ts.net:8765/v1/health` | JSON health | — |
| C3 | Click **Deny** instead (reset with the firewall's app list): repeat C2 | Times out from the other machine; the Mac's own agents still work over `127.0.0.1` | Whether the app says anything about it |
| C4 | Install the next release over this one, reopen | The prompt may come back (ad-hoc signature changes every build) | Whether it did |

## D. Settings: Invite a machine

| # | Step | Expect | Record |
|---|---|---|---|
| D1 | Right-click the pill → **Settings…** → **Invite a machine**: name `laptop-agent`, role **Sender (a server or agent)**, 1 use, then **Create invite** | An invite row appears with **Agent prompt** and **Shell one-liner** buttons; "Copied …" after clicking one | Whether they found the section without help |
| D2 | Paste **Agent prompt** into Claude Code on the same Mac | The agent reads the link, installs the CLI to `~/.local/bin`, writes `~/.config/needs-you/env`, a test card appears, then it's resolved | Every question the agent asked; anything it got wrong |
| D3 | `cat ~/.config/needs-you/env` (token redacted when sharing) | `NEEDS_YOU_URLS` starts with `http://127.0.0.1:8765` | — |
| D4 | Second invite, 2 uses, for a Linux server on the tailnet: run **Shell one-liner** there with `--claude-hooks user --skill` | Installed; a test card from that host; a cron line `# needs-you-flush` | — |
| D5 | Run the same one-liner again on that server | Keeps its token, spends no use | — |
| D6 | Post one `work` and one `personal` item from each machine (`needs-you add --key "test:<host>:<ctx>" --context <ctx> --title ...`) | Four cards, each under the right context, with the right host | — |
| D7 | Type in another app while cards arrive | Keystrokes never go to the panel; the panel never takes focus | Any focus steal |

## E. Settings: Access

| # | Step | Expect | Record |
|---|---|---|---|
| E1 | **Access** → **Refresh** | **Invites** lists the open invites; **Machines** lists the tokens from D2 and D4 (names, roles, never the token values) | — |
| E2 | **Revoke** the server's token | It disappears from the list; on the server, `needs-you add ...` is refused (and isn't queued) | The CLI's message on the server |
| E3 | **Revoke** a still-open invite; open its `/join/<code>` link | The join page says the link is no longer valid; its installer exits 1 | — |
| E4 | Resolve everything from D6 (`needs-you resolve --key ...`) | The pill goes back to "Nothing needs you" | — |

## F. CLI and server assets

| # | Step | Expect |
|---|---|---|
| F1 | On a Linux box without needs-you: download `needs-you-cli-X.Y.Z`, `chmod +x`, `./needs-you-cli-X.Y.Z --version` | Prints `X.Y.Z` |
| F2 | Unpack `needs-you-server-X.Y.Z.tar.gz`, follow `docs/HUB.md` as far as `python3 hub/needs_you_hub.py --help` | Works with the system python3 |

## Pass criteria

- A, D, E pass on at least one macOS 15+ Mac with no help beyond the release notes and guides.
- No system dialog appears that the notes don't mention.
- Every finding has a doc fix or an issue.

## Blocked on decisions

These stay open until you decide. Everything above works without them.

| Decision | Blocks | Options | Where |
|---|---|---|---|
| **License** | Any public release or public repo. Release assets exist only as drafts for collaborators until then. | An OSI license (the project is planned as an open-source non-profit) | [distribution.md](distribution.md#license) |
| **Public repo vs collaborators** | Who can download a release; whether `install-hub.sh` can curl from GitHub without a token; a Homebrew tap | Stay private and add testers as collaborators (read access sees releases), or go public after the license | [distribution.md](distribution.md) |
| **Apple Developer ID** (personal or organization) | Notarization (no Gatekeeper workaround), EDR trust, a firewall rule that survives updates, Homebrew cask, CI phase 3 secrets | Personal account now; or wait for the non-profit's org account | [distribution.md](distribution.md#open-decisions), [ci-cd.md](ci-cd.md#phase-3-signing-and-notarization) |
| **Draft vs auto-publish releases** | Nothing yet: the workflow makes drafts | Keep drafts, or publish when tests pass | [ci-cd.md](ci-cd.md#open-decisions) |
| **Checksum signing** | Verifying downloads beyond `SHA256SUMS` from the same page | None, minisign, or Sigstore keyless | [ci-cd.md](ci-cd.md#open-decisions) |
| **Update checks** | An "update available" notice in the app | Off by default, or on with disclosure | [distribution.md](distribution.md#open-decisions) |
| **First version number** | Tagging the first release | decided: `0.1.1` | `VERSION`, `CHANGELOG.md` |
