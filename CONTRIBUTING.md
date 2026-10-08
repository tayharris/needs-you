# Contributing

Thanks for helping. needs-you is small on purpose: a standard-library-only Python hub and CLI, a Swift Mac app, and shell installers. Read [README.md](README.md) for what it does, then [CLAUDE.md](CLAUDE.md), the contributor guide for people and agents alike (repo map, build and test commands, hard rules).

## Before you start

- **Bugs:** open an issue with the bug template (component, version, steps). `needs-you doctor` output helps; it never prints the token.
- **Anything bigger than a fix:** open an issue first so we can agree on the shape. Changes to the wire contract, a new dependency or a new integration usually need a short design note; architecture decisions go in [docs/adr/](docs/adr/).
- **Security problems:** never in a public issue; see [SECURITY.md](SECURITY.md).
- Fork the repository and open a pull request from a branch.

## License

needs-you is licensed under [Apache-2.0](LICENSE). By opening a pull request you agree that your contribution is licensed under the same terms (section 5 of the license). There's no separate CLA.

## Setup

Nothing to install beyond what macOS and Ubuntu ship (plus Xcode or the Command Line Tools for the Mac app). No pip, no brew, no build step for the Python parts.

```bash
/usr/bin/python3 -m unittest discover -s tests    # hub, CLI, installers, site (python3 3.9+ on Linux)
mac/scripts/test.sh                                # Mac app core, macOS only (XCTest, or MiniXCTest without Xcode)
mac/scripts/bundle.sh                              # build mac/dist/NeedsYou.app, ad-hoc signed
NEEDS_YOU_DEMO=1 mac/dist/NeedsYou.app/Contents/MacOS/NeedsYou &   # run it with fixture items, no hub
```

Run a throwaway hub and token to try the CLI:

```bash
python3 hub/needs_you_hub.py --bind 127.0.0.1 --port 8765 --db /tmp/ny.db
python3 hub/needs_you_admin.py --db /tmp/ny.db token add me      # prints the token once
```

Shell scripts are checked with `shellcheck -S warning` in CI. New Swift test classes must be registered in `mac/Sources/NeedsYouSelfTest/main.swift` (see [mac/README.md](mac/README.md)).

## Rules that reviews check

1. Python is standard library only and runs on `/usr/bin/python3` 3.9 (macOS): `from __future__ import annotations`, no `match`, no runtime `X | Y` unions, no `tomllib`. No new dependencies anywhere, Swift packages included, without an ADR.
2. The floating panel never takes focus or activates the app, and has no text fields or other focusable views.
3. Tokens, peer secrets and invite codes are never logged, printed (except once at mint), committed, or put in item text, tests, screenshots or issues.
4. Hubs bind loopback or the tailnet only, never `0.0.0.0` or `::` by default.
5. No real hostnames, tailnet names or company names: use `hub-a.example.ts.net`, `<tailnet>`, `devbox`, `acme`, `ACME-123`.
6. A wire change updates `docs/API.md`, the hub, the CLI, the Mac client and tests in one change. Unknown fields stay ignored both ways.
7. The link scheme allow-list is enforced in both the hub and the Mac app (`LinkPolicy.swift`): change both or neither.
8. Senders never fail the caller's job: the CLI exits 0 when it queues; hooks always exit 0.
9. Never kill processes by name or pattern (no `pkill`, no `killall`, in scripts, tests or by hand on a shared machine): kill only PIDs your own job saved (`$!` or a pidfile it wrote). To find an app's process, match its exact path with every regex metacharacter escaped, and refuse an empty path. macOS `pkill` stops reading options at the first pattern, so `pkill -f pat -U user` signals every process matching `user` too. `tests/test_no_broad_kills.py` checks the repo.

The agent-facing entry points ([docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md), the Claude Code skill and hooks, the invite page) are product surface: treat changes to them like API changes.

## Pull requests

- Small, reviewable commits with plain messages. Fill in the PR template's checklist.
- User-visible changes get a line in [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]`.
- Docs change with the code: a new flag, setting or behavior is in the guide that a user would read.
- CI runs the Python tests on Ubuntu and on macOS's Python 3.9, the Mac tests and build, and shellcheck. It must be green.

## Releases

Maintainers bump `VERSION` (and the `VERSION` constants in `hub/needs_you_hub.py` and `cli/needs-you`, which `tests/test_release.py` checks), move `[Unreleased]` to the new version in `CHANGELOG.md`, and tag `vX.Y.Z`; `.github/workflows/release.yml` drafts the GitHub Release with the Mac app, the server tarball, the CLI and `SHA256SUMS`. See [docs/roadmap/ci-cd.md](docs/roadmap/ci-cd.md).
