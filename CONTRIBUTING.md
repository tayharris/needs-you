# Contributing

Thanks for helping. needs-you is small on purpose: a standard-library-only Python hub and CLI, a Swift Mac app, and shell installers. Read [README.md](README.md) for what it does, then [CLAUDE.md](CLAUDE.md), the contributor guide for people and agents alike (repo map, build and test commands, hard rules). This page is the human version: what to install, the one command that runs every check, and what a pull request needs.

Not writing code? Testing needs-you with an AI tool we haven't run for real helps as much: see [Help us test](docs/guides/help-us-test.md).

## Before you start

- **Bugs:** open an issue with the [bug report](https://github.com/tayharris/needs-you/issues/new?template=bug_report.yml) template. `needs-you doctor` output helps; it never prints the token.
- **A tool we don't support yet:** the [integration request](https://github.com/tayharris/needs-you/issues/new?template=integration_request.yml) template.
- **Anything bigger than a fix:** open an issue first so we can agree on the shape. Changes to the wire contract, a new dependency or a new integration usually need a short design note; architecture decisions go in [docs/adr/](docs/adr/).
- **Security problems:** never in a public issue; see [SECURITY.md](SECURITY.md).
- Fork the repository and open a pull request from a branch of your fork.

## License

needs-you is licensed under [Apache-2.0](LICENSE). By opening a pull request you agree that your contribution is licensed under the same terms (section 5 of the license). There's no separate CLA.

## Dev setup

No pip, no brew packages, no build step for the Python parts. You need:

| Tool | Why | Get it |
|---|---|---|
| **Python 3.9** | The hub and CLI must run on macOS's `/usr/bin/python3`, which is 3.9. CI runs the suite on it | **macOS:** comes with the Command Line Tools (`xcode-select --install`). **Linux:** your `python3` (3.10+) runs the suite; for a 3.9 as well, `uv python install 3.9` ([uv](https://docs.astral.sh/uv/)), `pyenv install 3.9`, or `apt install python3.9` from the deadsnakes PPA on Ubuntu |
| **git, bash, curl** | Tests drive the installers and hooks through them | Already there on macOS and Ubuntu |
| **shellcheck** | Every `*.sh` is linted in CI | `apt install shellcheck` or `brew install shellcheck` |
| **Swift 5.9+** (macOS 14+) | Only for `mac/`: Xcode, or just the Command Line Tools (then the tests run on the bundled MiniXCTest runner) | `xcode-select --install` |
| **node** (optional) | The opencode plugin tests; they're skipped without it | Any current LTS |

## Run every check: `scripts/check.sh`

```bash
scripts/check.sh            # what CI runs, on this machine
scripts/check.sh --no-mac   # macOS: skip the Mac app tests and build
NEEDS_YOU_PYTHON39="$(uv python find 3.9)" scripts/check.sh   # Linux: also run the suite on a 3.9
```

It runs the same commands as [`.github/workflows/ci.yml`](.github/workflows/ci.yml), byte for byte (`tests/test_check_script.py` fails if they drift), runs every step even when one fails, and exits non-zero if any did. "Passes check.sh" should mean "passes CI"; the one gap is the OS: on Linux it can't run the Mac jobs, and CI's Python 3.9 job runs on macOS.

The checks a pull request must pass (the CI job names):

| CI job | What it runs | Locally |
|---|---|---|
| `python-ubuntu` | The Python suite on Ubuntu 22.04 and the latest Ubuntu's `/usr/bin/python3` | `/usr/bin/python3 -m unittest discover -s tests` |
| `python-macos-39` | The same suite on macOS's Python 3.9, the compatibility floor | Same, on a Mac, or with `NEEDS_YOU_PYTHON39` |
| `mac` | `mac/scripts/test.sh` (the NeedsYouCore tests) and `mac/scripts/bundle.sh` (the release build) | macOS with Swift |
| `shellcheck` | `shellcheck -S warning` on every tracked `*.sh` | needs `shellcheck` |
| `lint` | [`scripts/lint_repo.py`](scripts/lint_repo.py): no real tailnet names or addresses (hard rule 5) in any file or commit message, and no `Co-Authored-By` or "Generated with" lines in the PR's commits | `python3 scripts/lint_repo.py` (compares against `origin/main`) |

Inside the Python suite, a few tests guard rules rather than features; when one fails, its message says what to do:

- `tests/test_site_guides.py`: the site's guide pages match `docs/`. After editing anything in `docs/`, run `python3 scripts/build_site_guides.py` and commit `site/guides/`.
- `tests/test_link_mirror.py`: the hub's link rules and the Mac app's are byte-identical, and both pass `tests/fixtures/link_cases.json`.
- `tests/test_no_broad_kills.py`: no `pkill`/`killall` by name or pattern anywhere.
- `tests/test_check_script.py`: `scripts/check.sh` runs what CI runs, and CI never gives a fork's PR a self-hosted runner or a secret.

While you iterate, run one file: `cd tests && python3 -m unittest test_cli`. The whole suite takes several minutes.

**Your own names.** The lint only knows made-up names (a list of real ones would itself be the leak). To also catch your own hostnames, tailnet name or employer, put one regex per line in `.git/info/leak-patterns` (never committed); `scripts/lint_repo.py` and `check.sh` apply it.

**Forks and CI.** Pull requests from forks run on GitHub-hosted runners only and get no secrets; nothing in `ci.yml` needs one. The site deploy workflow never runs for pull requests.

## Run it locally

A throwaway hub and token to try the CLI:

```bash
python3 hub/needs_you_hub.py --bind 127.0.0.1 --port 8765 --db /tmp/ny.db
python3 hub/needs_you_admin.py --db /tmp/ny.db token add me      # prints the token once
NEEDS_YOU_URL=http://127.0.0.1:8765 NEEDS_YOU_TOKEN=<that token> cli/needs-you add --key test:hello --title "Hello"
```

The Mac app (macOS 14+):

```bash
mac/scripts/test.sh                                # NeedsYouCore tests (XCTest, or MiniXCTest without Xcode)
mac/scripts/bundle.sh                              # build mac/dist/NeedsYou.app, ad-hoc signed
NEEDS_YOU_DEMO=1 mac/dist/NeedsYou.app/Contents/MacOS/NeedsYou &   # fixture items, no hub
```

Quit an installed NeedsYou.app first: its built-in hub holds port 8765. New Swift test classes must be registered in `mac/Sources/NeedsYouSelfTest/main.swift` and symlinked there (see [mac/README.md](mac/README.md)).

The site: `python3 -m http.server -d site 8000`, then open http://127.0.0.1:8000.

## Rules that reviews check

1. **No new dependencies.** Python is standard library only and runs on `/usr/bin/python3` 3.9 (macOS): `from __future__ import annotations`, no `match`, no runtime `X | Y` unions, no `tomllib`. No pip packages, no Swift packages, nothing new to install, without an [ADR](docs/adr/).
2. **The floating panel never takes focus** or activates the app, and has no text fields or other focusable views. You should be able to keep typing in another app while cards arrive. `FloatingPanelTests` guards it.
3. **No secrets anywhere.** Tokens, peer secrets and invite codes are never logged, printed (except once at mint), committed, or put in item text, tests, screenshots or issues.
4. **Hubs bind loopback or the tailnet only**, never `0.0.0.0` or `::` by default.
5. **No real hostnames, tailnet names or company names**: use `hub-a.example.ts.net`, `<tailnet>`, `devbox`, `acme`, `ACME-123`. The `lint` job checks tailnet names and addresses.
6. **API changes land together.** A wire change updates `docs/API.md`, the hub, the CLI, the Mac client (`HubClient.swift`, `Models.swift`) and tests in one pull request. Unknown fields stay ignored both ways. The checklist is in [.claude/skills/api-change/SKILL.md](.claude/skills/api-change/SKILL.md).
7. **The link allow-list is mirrored.** The schemes a card may link to are enforced in both the hub and the Mac app (`LinkPolicy.swift`) with byte-identical regexes: change both or neither, and add a case to `tests/fixtures/link_cases.json`.
8. **Senders never fail the caller's job**: the CLI exits 0 when it queues; hooks always exit 0.
9. **Never kill processes by name or pattern** (no `pkill`, no `killall`, in scripts, tests or by hand on a shared machine): kill only PIDs your own job saved (`$!` or a pidfile it wrote). To find an app's process, match its exact path with every regex metacharacter escaped, and refuse an empty path. macOS `pkill` stops reading options at the first pattern, so `pkill -f pat -U user` signals every process matching `user` too.

The agent-facing entry points ([docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md), the Claude Code skill and hooks, the invite page) are product surface: treat changes to them like API changes.

## Branches and commits

- Any branch name in your fork is fine; maintainers use `<name>/<slug>`.
- Small, reviewable commits. The subject says what changed, prefixed with the area when that helps (`hub: …`, `cli: …`, `mac: …`, `docs: …`); the body says why.
- No `Co-Authored-By` trailers or "Generated with" lines: the `lint` job refuses them. You're welcome to use AI tools; the commit is yours.
- Don't bump versions or edit release sections of the changelog; maintainers do that.

## Pull requests

1. Run `scripts/check.sh`.
2. Open the pull request against `main` and fill in the template: what changed, how you tested it (which suites, on which OS, what you clicked), and the checklist.
3. User-visible changes get a line in [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]`. Docs change with the code: a new flag, setting or behavior is in the guide a user would read, and `site/guides/` is rebuilt.
4. CI must be green. A maintainer ([CODEOWNERS](.github/CODEOWNERS)) reviews against the rules above, reads the docs you changed as a new user would, and for `mac/` changes runs the app.

## Adding an integration

An integration teaches a tool (an agent, a CI system, a scheduler) to post items. It's a thin layer over the `needs-you` CLI and adds no hub features. Look at `integrations/ci/` (scripts) and `integrations/claude-code/` (installer, hook, skill) first. The full checklist is [.claude/skills/add-integration/SKILL.md](.claude/skills/add-integration/SKILL.md); in short:

- **Never fail the caller**: exit 0 when the hub is down and let the CLI queue. Hooks always exit 0 and never print to stdout.
- **Stable keys** (`<prefix>:<thing>:<reason>`, never a timestamp), and **resolve what you post** when the person answers or the tool moves on.
- **No secrets or raw output in items**: link to logs instead.
- **Off unless asked for** if it could be noisy; config through `~/.config/needs-you/env` and `NEEDS_YOU_<INTEGRATION>_*` variables.
- bash 3.2-compatible scripts with no `jq`; Python stdlib 3.9.
- Files: `integrations/<name>/README.md` (reference: what it does, keys, how it was tested), the script, a user guide `docs/guides/<name>.md` (then rebuild the site guides), a row in README's guide table, and `tests/test_<name>.py` that runs it against a real local hub (`tests/support.py`): it posts, resolves, exits 0 with the hub down, and posts nothing when not opted in.
- Say in the README how you tested it: against the real tool and which version, a local model stub, or only the tool's docs. [Help us test](docs/guides/help-us-test.md) lists that for every agent.

## Releases

Maintainers bump `VERSION` (and the `VERSION` constants in `hub/needs_you_hub.py` and `cli/needs-you`, which `tests/test_release.py` checks), move `[Unreleased]` to the new version in `CHANGELOG.md`, and tag `vX.Y.Z`; `.github/workflows/release.yml` drafts the GitHub Release with the Mac app, the server tarball, the CLI and `SHA256SUMS`. See [docs/roadmap/ci-cd.md](docs/roadmap/ci-cd.md).
