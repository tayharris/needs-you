# Distribution plan

Status: plan only. Today people build the app themselves (`mac/scripts/bundle.sh`) and clone the repo for hubs and senders.

## Install paths

| Who | Path | Depends on |
|---|---|---|
| Mac users | Download `NeedsYou-X.Y.Z-macos.zip` from GitHub Releases, unzip, drag to `/Applications` | [ci-cd.md](ci-cd.md) phase 2 |
| Mac users, later | `brew install --cask tayharris/tap/needs-you` | A signed + notarized build (phase 3); a tap repo |
| Sender machines | **Invite link** from the Mac app (agent prompt or `curl` one-liner). Installs the CLI to `~/.local/bin` and writes `~/.config/needs-you/env` | Invites (in progress) |
| Server hubs | `curl -fsSL https://github.com/tayharris/needs-you/releases/download/vX.Y.Z/install-hub.sh \| sudo bash -s -- --peer ...` which downloads the server tarball, verifies its SHA256 against `SHA256SUMS`, and runs `scripts/install-hub.sh` | Release assets |
| CLI only | Download `needs-you-cli-X.Y.Z`, `chmod +x`, put it on `PATH` | Release assets |

### Homebrew tap (later)

- Repo `tayharris/homebrew-tap` with `Casks/needs-you.rb` (app) and optionally `Formula/needs-you.rb` (the CLI; it runs on the system python3, so no Python dependency).
- The release workflow opens a PR to the tap bumping `version` and `sha256`.
- Homebrew requires notarized apps for casks to install cleanly, so this waits for signing.

### `curl | bash` for the server

A small `scripts/get-hub.sh` published as a release asset:

1. Refuses to run unless `tailscale` is present and logged in.
2. Downloads `needs-you-server-$V.tar.gz` and `SHA256SUMS` from the same release, verifies with `sha256sum -c`, aborts on mismatch.
3. Extracts to `/opt/needs-you/src-$V` and runs `install-hub.sh "$@"`.
4. Prints the health URL and the `needs-you-admin token add` next step.

Users who don't want to pipe to a shell: the same steps are in [HUB.md](../HUB.md).

## Gatekeeper and SentinelOne (ad-hoc signed builds)

Until there's a Developer ID build, the app is ad-hoc signed (`codesign -s -`):

- **Built locally:** runs without a prompt (no quarantine attribute).
- **Downloaded:** macOS quarantines it. First launch: right-click → **Open** → **Open**, or `xattr -dr com.apple.quarantine /Applications/NeedsYou.app`. On macOS 15+, the right-click route may be replaced by **System Settings → Privacy & Security → Open Anyway**.
- **Endpoint security** (SentinelOne, CrowdStrike, Jamf Protect) on managed Macs may flag or kill ad-hoc signed binaries, especially ones that listen on a port (the embedded hub). Options: ask IT to allow-list the bundle id `app.needsyou.mac` / the binary hash, build it locally from source, or wait for a Developer ID build. Document this in the release notes.
- **Login item:** `SMAppService.mainApp` works for ad-hoc builds, but users must approve it in System Settings → General → Login Items.
- **Local network / firewall:** the embedded hub listens on loopback and the tailnet interface. The macOS firewall may prompt to allow incoming connections on first run; an ad-hoc signature changes on every build, so the prompt can come back after each update. A stable Developer ID fixes that.

With a Developer ID and notarization (CI phase 3) the zip opens with the normal "downloaded from the internet" dialog, and most EDR tools trust it.

## Updates

- Phase 1: the app checks the GitHub Releases API at most daily and shows "update available" in Settings (no auto-install). Opt-out setting. This is the only outbound non-tailnet request the app would make, so it must be off by default or clearly disclosed (privacy promise on the site).
- Later: Sparkle with an EdDSA-signed appcast hosted on the site.

## License

Open-source license TBD at public launch (the project is planned as an open-source non-profit). No LICENSE file until then, and no public release assets before it exists.

## Open decisions

1. Personal Developer ID now, or wait for an organization account?
2. Update checks: off by default, or on with disclosure?
3. Publish the CLI on PyPI too? (It's one file with no deps; `pipx install needs-you` would be convenient but adds a channel to maintain.)
