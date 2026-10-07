# Keeping up to date

A release that passed its tests reaches the Mac app on its own, and from the Mac's hub every sender machine can follow. The design and its reasons: [docs/roadmap/rollout-updates.md](../roadmap/rollout-updates.md).

```
tag vX.Y.Z → CI tests → draft release (+ release-manifest.json) → you publish it
  → the Mac app sees it (within 6 h), waits 2 h, verifies, installs when you're away
  → its hub now serves the new CLI, hook, skill and Orca snippet (/dl/manifest.json)
  → senders run `needs-you update` (by hand, daily with --auto-update, or scripts/rollout.sh)
  → Settings → Updates: "1 of 4 machines out of date"
```

## The Mac app

**Settings → Updates.** It shows this app's version, the last check and its result, and:

| Setting | Default | What it does |
|---|---|---|
| Check for updates automatically | on | 2 minutes after launch, then every 6 hours. The only request goes to `api.github.com` and carries nothing about your items. |
| Install updates automatically | on | When you've been away 10 minutes (no keyboard or mouse), or when you quit. Never while the panel is open, the pointer is on it, or an item arrived in the last 2 minutes. |
| Channel | Releases | Or releases and pre-releases. Drafts never. |
| Wait after a release | 2 hours | A release pulled within this time never reaches this Mac. |

**Check now** checks at once. When an update passes the checks, **Download and install now** (or **Restart to update** once it's downloaded) installs it straight away, and **Skip X.Y.Z** skips that version.

What it checks before installing anything: the release is published (not a draft); it is newer than this app; it carries `release-manifest.json`, which only the release job writes, after the tests passed; the zip matches the SHA-256 in both the manifest and `SHA256SUMS`, and its size; the release workflow run named in the manifest concluded `success` on the same commit (when the token can read Actions); this Mac meets the manifest's `min_macos`; the unpacked app has the same bundle id (`app.needsyou.mac`), the promised version, a valid seal (`codesign --verify --deep --strict`), the same signing team as this app (when this app has one), no symlink pointing outside the bundle, and a bundled `install.sh`. Downloads come from GitHub's own hosts over https only, redirects included, from the repo fixed in the app. Once a release signing key is pinned in the app, a valid Ed25519 signature over the manifest is required too (owner steps: [release-signing.md](../security/release-signing.md)).

**Installing** runs the app's bundled `install.sh`: it quits the app, swaps `/Applications/NeedsYou.app` (keeping `NeedsYou.app.previous`), relaunches in the background, and puts the previous version back if the new one doesn't stay running. A version that was rolled back is skipped from then on. Settings says "Updated to X.Y.Z" after a successful update. The log is `~/Library/Application Support/NeedsYou/Updates/install.log`. To go back by hand: `/Applications/NeedsYou.app/Contents/Resources/scripts/install.sh --rollback`.

After an update, if the macOS firewall asks whether `python3` may accept incoming connections, choose **Allow**: the ad-hoc signature changes with every build, and until then other machines can't reach this Mac's hub (they queue).

**While the repo is private** the app needs a GitHub credential. It uses, in order: the GitHub CLI's token (`gh auth token`, from `/opt/homebrew/bin/gh` or `/usr/local/bin/gh`, so run `gh auth login` once), then a fine-grained token (Contents: read and Actions: read, on this repo only) in `~/Library/Application Support/NeedsYou/github.token` with mode 600. The token stays in memory, goes only to `api.github.com`, and is never logged or shown; Settings shows only where it came from.

**Testing without a release:** `mac/scripts/make-test-feed.sh --version 0.1.2` builds a feed in `/tmp/needsyou-feed`; `defaults write app.needsyou.mac updateFeedURL file:///tmp/needsyou-feed/` points the app at it (or `NEEDS_YOU_UPDATE_FEED`). Settings then shows a **Test update source** warning, and nothing from it installs automatically. `defaults delete app.needsyou.mac updateFeedURL` goes back to GitHub.

### Upgrade note: the bundle id moved to `app.needsyou.mac`

0.1.x had a different bundle id. From the next release the app is `app.needsyou.mac`, so macOS treats it as a new app:

- **Settings reset once** (they live in the bundle id's defaults domain). To keep them, quit the app and, before the new one's first launch, run `defaults export <old id> - | defaults import app.needsyou.mac -`. After an `install.sh` update the old id is in `/Applications/NeedsYou.app.previous/Contents/Info.plist` (`CFBundleIdentifier`).
- **Hub data, tokens and update state stay put.** `~/Library/Application Support/NeedsYou` is named after the app, not the bundle id.
- **Open at login has to be turned on again** in Settings → General. Remove the stale entry in System Settings → General → Login Items if one is left.
- **The firewall may ask again** whether `python3` may accept incoming connections: choose **Allow**.
- **How to get it:** 0.1.1 has no in-app updater, so install the new zip by hand, or run `mac/scripts/install.sh --app <new NeedsYou.app>`. It finds the running app by its path, quits it, and swaps it at the same `/Applications/NeedsYou.app`; `install.sh --rollback` goes back. A build with the updater but the old id refuses an update with the new id; install that one update the same way, and later ones are automatic again.

## Sender machines

```bash
needs-you update --check     # what would change, and from where
needs-you update             # do it
needs-you update --rollback  # put back the files the last update replaced
```

`needs-you update` updates what's already installed on the machine (it never adds a piece): the CLI, the Claude Code hook and its entries in `~/.claude/settings.json` (re-merged by `install-hooks.sh`, which keeps a `.bak`), a project's own hooks when you run it inside that project, the skill, and the Orca snippet. It:

- asks only the hub this machine was invited by: the first URL in `NEEDS_YOU_URLS`, or `NEEDS_YOU_UPDATE_HUB` if you set one. Never a failover hub, never a URL a hub sends;
- talks to it only over https, loopback or the tailnet (a `100.64.0.0/10` or `fd7a:115c:a1e0::/48` address, or a `*.ts.net` name that resolves into them). Plain http to anything else is refused;
- checks every file against the hub's `/dl/manifest.json` (sha256 and size), and the CLI also compiles;
- talks to exactly the address it checked: the URL is parsed once (no `user@`, trailing dots, punycode, queries), a `*.ts.net` name is resolved once and the connection goes to that address with the name in the `Host` header, and redirects are never followed;
- when `gh` is installed, checks every file against the GitHub release of that version (its server tarball, itself checked against `SHA256SUMS`). A mismatch, or a `gh` that fails (no such release, not logged in, a timeout), refuses the whole update. It also downloads the release's `release-manifest.json`, checks that it lists that tarball, and runs `gh attestation verify` on it, pinned to this repository, the release workflow, the version's tag and GitHub-hosted runners, and checks the attested digest is that file's (build provenance; skipped with a note while the repository is private, see [release-signing.md](../security/release-signing.md)). Any check that errors refuses; nothing fails open. Without `gh`, a manual update goes ahead with a warning; an automatic one is refused unless you set `NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH=0`, and `=1` refuses manual ones too;
- never downgrades unless you pass `--allow-downgrade`;
- keeps the replaced files in `~/.local/state/needs-you/backup/` for `--rollback`.

**Automatic (opt-in).** With `NEEDS_YOU_AUTO_UPDATE=1` in `~/.config/needs-you/env` (the installer's `--auto-update` writes it), the 5-minute `needs-you flush` runs the same update once a day, at a time that differs per machine, quietly and without ever failing the flush. It is off by default: an update is code. It also needs `gh` (logged in, able to read the repo) on the sender for the release cross-check, unless `NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH=0`.

**Asked from the Mac (Request update).** In **Settings → Access** (the machine list), a sender
whose CLI is older than the Mac app, or hasn't reported a version, has a **Request update**
button. It marks that machine's token "update requested" on each of your owner hubs, and the
machine's next post, resolve, flush or token-checked health call gets `"update_requested": true`
back. Then:

- with `NEEDS_YOU_AUTO_UPDATE=1`, the CLI starts its own `needs-you update --auto` in the
  background (detached, output discarded, at most once every 6 hours), the same verified update
  as above, from the same update hub. The command it was running finishes and exits as usual;
- otherwise it prints, at most once a day, `needs-you: <hub> asked this machine to update: run
  `needs-you update``, to stderr. Not with `-q`/`--json`, and not when stderr goes to
  `/dev/null` (the Claude Code hook), which doesn't use up the day's reminder.

The row shows "Update requested 5m ago" with **Cancel** until the machine reports a different
CLI version (or one at least the hub's), when the hub clears the request by itself and the row
says "Up to date". "Up to date" means at least the Mac app's own version: that is what its hub
serves, so it's the newest the machine can get from it. The request is a flag, never a URL or a
command, and is kept per hub, not replicated (the app sends it to every owner hub it has). From
a server hub's shell: `needs-you-admin token request-update <name>` and `token clear-update
<name>`. Why this is safe: [request-update.md](../security/request-update.md).

**Every request** a sender makes carries `X-Needs-You-Client: cli=…; hook=…; skill=…; orca=…`, so **Settings → Updates → Sender machines** on the Mac shows each machine's versions, when it was last seen, and "N of M machines out of date". `needs-you doctor` has an `update` line with the local versions against the hub's.

**Orca prompts** point at `~/.config/needs-you/orca-snippet.md` instead of carrying a copy ([integrations/orca](../../integrations/orca/README.md#prompt-block)), so an update reaches every automation on its next run. Prompts pasted before this change carry the old full text: replace them with the pointer once.

**Many machines at once:** `scripts/rollout.sh devbox ci-runner` (or a list in `~/.config/needs-you/hosts`, one SSH alias per line) runs `needs-you update` and `needs-you doctor` on each over SSH, in parallel, and prints a table. `--check` only reports. A machine without the CLI is listed; set it up with an invite link.

## Server hubs

A server hub serves its own checkout or tarball on `/dl`, so its senders follow it, not the Mac. Update it as in [docs/HUB.md](../HUB.md#upgrading). An automatic updater for server hubs is planned ([rollout-updates.md](../roadmap/rollout-updates.md), item 15).
