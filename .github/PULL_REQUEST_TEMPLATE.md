## What changed and why

<!-- One or two sentences. Link the issue if there is one ("Fixes #123"). -->

## How it was tested

<!-- Which suites, on which OS, and what you ran or clicked by hand. For example:
     scripts/check.sh on macOS 15 (all passed); posted a card from Codex 0.50 and approved it. -->

- [ ] `scripts/check.sh` passes (OS: )
- [ ] Tried by hand: <!-- what, or "n/a" -->

## Checklist

Tick what applies; delete lines that don't.

- [ ] Tests added or changed for the behavior (a fix comes with a test that failed before it)
- [ ] Docs: the guide a user would read says what changed (`docs/guides/`, an integration's README)
- [ ] `site/guides/` rebuilt after editing `docs/` (`python3 scripts/build_site_guides.py`)
- [ ] `CHANGELOG.md`: a line under `[Unreleased]` for a user-visible change
- [ ] Wire change: `docs/API.md`, the hub, the CLI, the Mac client and tests all in this PR
- [ ] Link rules: the hub and `LinkPolicy.swift` changed together, with a case in `tests/fixtures/link_cases.json`

## Hard rules

- [ ] Python stays standard-library only and 3.9-compatible; no new dependencies anywhere
- [ ] The panel still never takes focus or activates the app
- [ ] No tokens, invite codes, secrets, personal hostnames, tailnet names or company names in code, docs, tests, screenshots or commit messages
- [ ] Hubs still bind loopback or the tailnet only; senders and hooks still never fail the caller
- [ ] No `Co-Authored-By` or "Generated with" lines in the commits
