# Contributing

Thanks for helping. needs-you is small on purpose: a stdlib-only Python hub and CLI, a Swift Mac app, and shell installers. Start with [README.md](README.md), then [CLAUDE.md](CLAUDE.md), which is the contributor guide for people and agents alike (repo map, build and test commands, hard rules).

## Before you start

- Open an issue first for anything bigger than a fix, so we can agree on the shape.
- The project is licensed under [Apache-2.0](LICENSE); contributions are accepted under the same license. For now, contributions come from invited collaborators.

## Setup

No installs beyond what macOS and Ubuntu ship (plus Xcode or the Command Line Tools for the Mac app):

```bash
/usr/bin/python3 -m unittest discover -s tests    # hub, CLI, installers, site
mac/scripts/test.sh                                # Mac app core (XCTest, or MiniXCTest without Xcode)
mac/scripts/bundle.sh                              # build mac/dist/NeedsYou.app, ad-hoc signed
```

`needs-you doctor` checks a sender's setup when something doesn't post.

## Rules that reviews check

1. Python is standard library only and runs on `/usr/bin/python3` 3.9: no new dependencies anywhere without an ADR in `docs/adr/`.
2. The floating panel never takes focus or activates the app.
3. Tokens, peer secrets and invite codes are never logged, printed (except once at mint), committed, or put in item text, tests, screenshots or issues.
4. Hubs bind loopback or the tailnet only.
5. No real hostnames, tailnet names or company names: use `hub-a.example.ts.net`, `<tailnet>`, `devbox`, `acme`, `ACME-123`.
6. A wire change updates `docs/API.md`, the hub, the CLI, the Mac client and tests together.
7. Senders never fail the caller's job: the CLI exits 0 when it queues; hooks always exit 0.

## Pull requests

- Small, reviewable commits. Fill in the PR template's checklist.
- User-visible changes get a line in `CHANGELOG.md` under `[Unreleased]`.
- CI runs the same suites as above on Ubuntu and macOS; it must be green.

## Releases

Maintainers tag `vX.Y.Z`; `.github/workflows/release.yml` drafts the GitHub Release. See `docs/roadmap/ci-cd.md`.
