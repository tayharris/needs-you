# Launch prep: the site, an installable repo, and the Mac UI pass

Status (2026-10-08): almost all built and shipped (0.1.2 to 0.1.5). Built: the site (live at needsyou.app), the DMG, the README's new-user section, the [Claude Code everywhere](../guides/claude-code-everywhere.md) guide, and the Mac UI pass (Settings in sidebar sections, panel and pill size, how loud urgent and other items are, a recordable global shortcut, the age badge and **Dismiss All from &lt;host&gt;**; see the [Mac app guide](../guides/mac-app.md)). The hotkey's "open the top card's link" option was built and later removed; keyboard navigation in the open panel is an idea in [future.md](future.md).

Still open:

- **Donate link** ("Support the project"): needs a URL decision (GitHub Sponsors, Open Collective, Ko-fi). Not on the site or README yet.
- **GitHub**: repository topics and a social preview image; the site's `og:image` (a 1200×630 PNG) is a TODO in `site/index.html`.

The plan as written on 2026-10-06 follows, for the record.

What's already there, so nobody rebuilds it:

- `site/` is a static landing page (no build), checked by `tests/test_site.py`; deploy plan in [site-deploy.md](site-deploy.md).
- Releases: a `v*.*.*` tag drafts a GitHub Release with `NeedsYou-<v>-macos.zip`, the server tarball, the CLI and `SHA256SUMS` (`.github/workflows/release.yml`, `scripts/build-release.sh`).
- License: Apache-2.0 (`LICENSE`). The repo itself is still private; going public waits on [sharing-checklist.md](sharing-checklist.md) (history, bundle id).
- The app has a global hotkey, ⌃⌥Space (`mac/Sources/NeedsYou/HotKey.swift`, Carbon, no Accessibility prompt). It shows the panel and never activates the app (hard rule 2). Not configurable yet.
- Settings (`SettingsWindow.swift`, `AppSettings.swift`): hubs, name, context, menu bar icon and count, snap to corners, urgent-breaks-snooze, local hub, Access. No size or brightness settings.

## 1. Site (Linux, no Mac needed)

Minimal, in the style of the owner's other sites (ask for the reference URL; match its type scale, spacing, restraint and dark palette, not its content). Keep `site/` static: no build step, no new dependencies, no trackers.

- One screen of copy: what it is, a screenshot or a CSS mock of the pill, three lines on how it works (agents post → the pill shows → it disappears when handled).
- **Install**: a Download button to the latest GitHub Release asset, the Gatekeeper note (right-click → Open, ad-hoc signed), and the sender one-liner shape (`curl -fsSL <join_url>/install.sh | bash -s -- --yes`).
- **Open source**: a GitHub link and an "Apache-2.0" line. While the repo is private, the link 404s for visitors, so put it behind one constant in `site.js` or the HTML and say in the PR that it goes live with the public repo.
- **Donate**: a "Support the project" link for the planned non-profit. Needs a URL decision (GitHub Sponsors, Open Collective, Ko-fi, Buy Me a Coffee). Until then, keep it as one placeholder that `tests/test_site.py` refuses to ship (for example, the test fails if the href is `#donate-tbd` once a release flag is set), or leave it out.
- Update `tests/test_site.py` for every new link and section; keep the no-personal-hostnames check.

## 2. Repo ready for people to install (mostly Linux)

- **DMG**: add `NeedsYou-<v>.dmg` next to the zip in `scripts/build-release.sh` (`hdiutil create -volname NeedsYou -srcfolder <dir with the .app and an /Applications symlink> -format UDZO`), plus `SHA256SUMS` and the release notes. It only runs on the macOS runner, so test it with a throwaway tag on a fork or a `workflow_dispatch` dry run, never by pushing a real tag without the owner's OK. Keep the zip: `mac/scripts/install.sh --app` and the fresh-user plan use it.
- **README**: a short top section for a new user: what it is, Download (DMG), first launch (Gatekeeper), "invite a machine", and links to `docs/guides/quickstart.md`, `docs/AGENT-GUIDE.md`, the Orca and Claude Code integrations. An "Open source, Apache-2.0" line and the donate link once it exists.
- **Guides**: walk `docs/guides/quickstart.md` as a stranger would (the [fresh-user-test-plan.md](fresh-user-test-plan.md) list), fix what's stale, and add a page for "alerts from Claude Code everywhere": local, SSH, tmux, VS Code Remote-SSH (`NEEDS_YOU_AGENT_ALERTS=1` and the `NEEDS_YOU_AGENT_LINK='VS Code=vscode://vscode-remote/ssh-remote+<host>{cwd}'` button).
- **GitHub**: repo description, topics, a social preview image, issue templates already exist; check `CONTRIBUTING.md` and `SECURITY.md` read well for outsiders.

## 3. Mac UI pass (write on Linux, CI builds and tests it, a person checks it on a Mac)

Every change here keeps hard rule 2: the panel never takes focus or activates the app; only a click on Settings may. `FloatingPanelTests` guards it. Put any pure logic (sizes, opacity curves, hotkey parsing) in `NeedsYouCore` with tests registered in `mac/Sources/NeedsYouSelfTest/main.swift` and symlinked (see `mac/README.md`); keep the view code thin.

- **Settings tune-up**: group into clear sections (Hubs and access, Panel, Alerts, Integrations, Advanced), consistent spacing and labels, explain each toggle in one line, show the hotkey and whether it registered.
- **Panel size**: a size setting (compact, regular, large) that scales the pill, the cards' type and the expanded panel's width. Store it in `AppSettings` with a prefs migration if the shape changes (`PrefsMigrationTests`).
- **Alert brightness**: how loud a new or urgent item is: the pill's glow or fill intensity and the pulse (off, subtle, normal, bright). Urgent keeps a floor so it can't be made invisible.
- **Panel design**: review the collapsed pill, the expanded list and the card layout (title, body, links row, Done/Dismiss/Snooze, the Terminal and VS Code buttons) for spacing and hierarchy at each size.
- **Hotkey**: let the user record a different shortcut in Settings (the recorder lives in the Settings window, never the panel). Open question for the owner: should the hotkey only show and expand the panel (today), or also "go to the top card" (run its first link: the Orca Terminal jump or the VS Code window)? The second is the "focus the window" wish; it doesn't need the panel to take focus.
- **Stale cards (option D in [stale-items.md](stale-items.md))**: show the age on old cards ("2 d") and add **Dismiss all from this host** to a card's menu.

## After this

The rest of [README.md](README.md): always-on hub (ADR 0004), phone widget, the local-terminal jump (phase 2 in [future.md](future.md)), team mode.
