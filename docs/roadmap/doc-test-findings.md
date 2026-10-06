# Doc test findings (2026-10-06)

A new-user walk through README → quickstart → add-a-sender → claude-code → orca → troubleshooting, plus `AGENT-GUIDE.md` and the `/join/<code>` page, run against the installed `NeedsYou.app` and its own hub. Every installer step ran with a throwaway `HOME`, a clean environment, and stubbed `launchctl`/`crontab` (and a stubbed `uname` returning `Linux` to exercise the cron branch). Nothing was written to the real home directory.

Invites used: `doctest-mac` and `doctest-srv` (1 use, 1 h each; both spent by the test). Items posted: `doctest:test:hello`, the installers' `setup:doctest-*:test` cards and one hook card, all resolved afterwards.

## Steps tried

| # | Doc step | Result | Fixed |
|---|---|---|---|
| 1 | README / quickstart §2: "click **Invite a machine**" | No such button. It's a section in Settings (right-click the pill → **Settings…**), with name, role, uses, expiry, **Create invite**, then **Agent prompt** / **Shell one-liner** copy buttons. | README, quickstart, add-a-sender, orca, mac-app, AGENTS.md say where it is |
| 2 | quickstart §2: the prompt reads `http://127.0.0.1:8765/join/...` | The hub returns its public URL: the Mac's MagicDNS name while Tailscale is up. 127.0.0.1 only without Tailscale. | quickstart shows the MagicDNS form and explains both |
| 3 | `GET /join/<code>` from 127.0.0.1 | 200, Markdown, correct invite name/uses/expiry. Install line uses the MagicDNS URL. | Page text: `--hub` row, PATH, hook opt-in, 404 handling, re-run rule |
| 4 | quickstart §2 one-liner, `--yes --claude-hooks user --skill` (macOS branch) | Works: CLI, env (mode 600), LaunchAgent plist + `launchctl bootstrap`, hooks in `~/.claude/settings.json`, skill, health OK, test card. | — |
| 5 | quickstart "Try a real item": `needs-you add ...` right after | `~/.local/bin` isn't on PATH on a stock Mac, so `needs-you` is "command not found". The installer prints a note; the guide didn't. | quickstart adds the PATH step; skill and agent guide say to use the full path |
| 6 | Mac's own sender config | `NEEDS_YOU_URLS` holds only the MagicDNS name, even on the Mac. Local agents queue instead of posting whenever Tailscale is down. Docs said "on the Mac itself that's 127.0.0.1". | Docs give the workaround (put 127.0.0.1 first). Code bug B1 |
| 7 | claude-code.md "Check it works" (notify, then resolve) | Works: `notify agent:<host>:<session> -> 0`, then resolve `-> 0`. Card is `work` unless `NEEDS_YOU_AGENT_CONTEXT` is set. | Noted in the guide; README/guide defaults corrected (`NEEDS_YOU_DEFAULT_CONTEXT`, else work) |
| 8 | quickstart §3: "turn on tailnet access in the app" | No such setting. The hub binds the tailnet address on its own when Tailscale is up. | quickstart, mac-app, troubleshooting |
| 9 | orca.md one-liner `--claude-hooks user --skill --orca` over the tailnet URL (Linux branch) | Works: crontab line tagged `# needs-you-flush`, Orca snippet printed and saved, token `doctest-srv-doctest-srv1`. | — |
| 10 | Re-run the same one-liner ("re-running is safe, keeps the token") | `curl: (22) ... 404` and exit 0, because the 1-use link is spent. Re-runs and `--uninstall` need a live link even though they don't spend a use. | add-a-sender, orca, troubleshooting, join page. Code gap B2 |
| 11 | add-a-sender "Removing a sender" manual commands | `rm -r` fails on paths that don't exist (`~/.local/state/needs-you` often doesn't); `orca-snippet.md` left behind; `integrations/claude-code/install-hooks.sh --uninstall` needs a checkout; `install-hooks.sh` alone from `/dl/` fails with `missing needs-you-hook.sh`. | `rm -rf`, whole config dir, a tested recipe that fetches all three hook files from the hub |
| 12 | "Revoke its token: in the Mac app" (add-a-sender, orca, quickstart, installer message) | The app has no revoke UI, and the hub has no HTTP revoke for tokens or invites. | Docs give the bundled admin tool command (checked on a copy of the DB). Code gap B3 |
| 13 | `install.sh --uninstall` (the repo template rendered for the local hub, so no new invite was needed) | Works: hooks removed with a backup, LaunchAgent booted out, files removed. | — |
| 14 | `curl ... \| bash -s -- --help` | Prints nothing, exit 0. | troubleshooting row. Code bug B4 |
| 15 | troubleshooting "Quick checks" in zsh and bash | Loop works in both. `tailscale` isn't on PATH with the macOS Tailscale app. | Adds the app's CLI path |
| 16 | troubleshooting "HTTP 422 / 400" | The hub returns 400 `invalid` for validation; it never sends 422. | Row says 400 |
| 17 | AGENT-GUIDE / join page `needs-you add/resolve/done` flags | Match `needs-you --help`. curl JSON body parses. | — |
| 18 | orca.md `orca worktree set --worktree active --workspace-status in-review --comment ...` | Flags match `orca worktree set --help`. | — |
| 19 | claude-code README: "The one-line hooks in `docs/AGENT-GUIDE.md` work too" | AGENT-GUIDE has no one-line hooks any more. | Removed |
| 20 | SKILL.md "a sender with more than 60 open items is refused" | Refused at 60 (`n >= max_open`). | Wording |
| 21 | ci README cron line runs `run-or-alert.sh` from a checkout | The invite installer doesn't install it, and `/dl/` doesn't serve it. | Says to copy it from a checkout |

## Code bugs

All fixed on `tay/doc-test-fixes` (2026-10-06):

| Bug | Fix |
|---|---|
| B1 | A redeem from the hub's own machine (loopback, or one of the hub's bind addresses) gets `http://127.0.0.1:<port>` first in `hub_urls`. `--hub URL` is saved first in `NEEDS_YOU_URLS`. |
| B2 | Used-up invites are kept until they expire; their join page and installer are still served. Re-runs and `--uninstall` work; a new machine (or `--force`) stops with exit 1 before installing anything. |
| B3 | `GET /v1/tokens`, `DELETE /v1/tokens/<id>`, `DELETE /v1/invites/<id>` (owner), and **Settings → Access** in the Mac app. |
| B4 | The help is a heredoc in `usage()`. |
| B5 | A dead link's `install.sh` is a `200` script that prints the reason and exits 1 (a `4xx` would still run an empty script under `curl -f`). |
| B6 | `install-hooks.sh --uninstall` needs no hook files; the test card uses `--host`; no `setup-sender.sh` hint from the invite installer; `--uninstall` removes `~/.local/state/needs-you`. |

As found:


- **B1. The Mac's own sender config depends on Tailscale.** `Hub.hub_urls()` (`hub/needs_you_hub.py`) returns only `public_url` plus peers, so an invite redeemed on the Mac writes `NEEDS_YOU_URLS=http://<mac>.<tailnet>.ts.net:8765`. Repro: run the one-liner on the Mac, then `cat ~/.config/needs-you/env`; turn Tailscale off and `needs-you add ...` queues. Also, the installer's `--hub URL` is used only for the download and redeem and never reaches the env file. Suggested: when the redeem comes from loopback, put `http://127.0.0.1:<port>` first.
- **B2. Re-run and `--uninstall` need a live link.** `/join/<code>/install.sh` 404s once the last use is spent (`invite_by_code` requires `invite_live`), so a 1-use link can't be re-run or used to uninstall, even though neither spends a use. Repro: create a 1-use invite, run the one-liner, run it again: `curl: (22) 404`, exit 0. Options: serve the script for used-up (not revoked or expired) links, or serve a generic uninstaller at `/dl/`.
- **B3. No way to revoke on the Mac's own hub from the app or over HTTP.** There's no `DELETE /v1/invites/<id>`, no token revoke endpoint, and no revoke UI in `mac/Sources/NeedsYou/SettingsWindow.swift`. The installer's closing line in `hub/join-install.sh` ("Revoke its token on the hub or in the Mac app") points at something that doesn't exist. The only route is `needs_you_admin.py --db ~/Library/Application\ Support/NeedsYou/hub.db token revoke <name>`.
- **B4. Installer `--help` is empty when piped.** `usage()` in `hub/join-install.sh` runs `sed -n '2,21p' "$0"`; under `curl ... | bash -s`, `$0` is `bash`, so it prints nothing and exits 0. Repro: `curl -fsSL <join_url>/install.sh | bash -s -- --help`.
- **B5. A used-up link fails silently with exit 0.** `curl -fsSL ... | bash` gives bash an empty script. This is documented, but agents read exit 0 as success. A non-empty 404 body served as a script (`echo ...; exit 1`) would fail loudly. Depends on B2.
- **B6. Minor.**
  - `install-hooks.sh --uninstall` refuses to run without `needs-you-hook.sh` and `hooks.json` next to it, though uninstall doesn't need them.
  - The installer's test card carries the real hostname in `source.host`, not `--host`, because the installer doesn't pass `--host` to the CLI.
  - `install-hooks.sh`'s "Next:" text points at `scripts/setup-sender.sh` even when run by the invite installer, which has just installed the CLI.
  - `--uninstall` leaves `~/.local/state/needs-you/claude-hooks/` behind.

## Manual steps not tested

- Anything in the Mac app's UI: opening Settings, creating an invite with the buttons, the copy buttons, the panel showing the cards. Checked against the Swift source only.
- macOS firewall prompt for `python3` on the first tailnet connection.
- `launchctl bootstrap` of the flush LaunchAgent and a real crontab (both stubbed), so the 5-minute flush never ran for real.
- `needs-you self-update`, `--force` re-redeem, the `project` hooks scope, and an owner/reader invite's `needsyou://` link.
- Claude Code actually firing the hooks in a live session, and Orca sessions (`$ORCA_TERMINAL_HANDLE`), including the unverified `orca://terminal/{handle}` link. (Later checked: Orca 1.4.220 has no terminal or worktree link; cards now carry an `orca terminal switch` command instead.)
- Server hubs (HUB.md, `needs-you-admin` wrapper), GitHub Actions, systemd units, and `scripts/setup-sender.sh`.
- Revoking a real token: the admin command was run only on a copy of the app's database. The two test tokens (`doctest-mac-doctest-mac1`, `doctest-srv-doctest-srv1`) are still active on the Mac's hub. Their machines' configs were deleted, and they have no open items.
