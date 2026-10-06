---
name: test-all
description: Run every needs-you test suite (Python hub/CLI tests on the system python3.9, the Mac NeedsYouCore tests, shell syntax checks) and report pass/fail per suite. Use before committing, before a PR, or when asked to "run the tests".
---

# test-all

Run each suite from the repo root, keep going if one fails, then report a table: suite, command, result, and the first failure's name and message.

## 1. Python (hub + CLI)

```bash
/usr/bin/python3 --version                          # must be 3.9.x on macOS; that's the floor we support
/usr/bin/python3 -m unittest discover -s tests
```

If `python3` on `PATH` is a different version, run the suite with it too (`python3 -m unittest discover -s tests`); both must pass. The suite starts real hubs on `127.0.0.1` with free ports and temp DBs, and takes ~30 s. No network beyond loopback.

Run one module or test while iterating: `/usr/bin/python3 -m unittest tests.test_api -v` or `... tests.test_replication.Conflicts.test_three_way_race`.

## 2. Mac (NeedsYouCore)

Only on macOS with Swift (`command -v swift`):

```bash
mac/scripts/test.sh
```

It runs `swift test` when XCTest is available (Xcode), otherwise the same files through `swift run needsyou-selftest` (MiniXCTest). Force one with `NEEDS_YOU_TEST_RUNNER=xctest|selftest`. First build can take a few minutes. `FloatingPanelTests` guards the never-take-focus rule: a failure there is a blocker.

Optionally confirm the app still bundles: `mac/scripts/bundle.sh` (ad-hoc signs `mac/dist/NeedsYou.app`).

## 3. Shell scripts

```bash
for f in scripts/*.sh mac/scripts/*.sh deploy/*.sh integrations/*/*.sh; do bash -n "$f" || echo "FAIL $f"; done
command -v shellcheck >/dev/null && shellcheck scripts/*.sh mac/scripts/*.sh deploy/*.sh integrations/*/*.sh
```

shellcheck is not required locally (don't install it); report "skipped" if it's absent. CI will run it (docs/roadmap/ci-cd.md).

## 4. Site (only if `site/` changed)

```bash
python3 -m http.server -d site 8000 --bind 127.0.0.1 &
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/
kill %1
```

## Report

```
suite            result   notes
python 3.9       PASS     61 tests
mac core         PASS     selftest runner
shell syntax     PASS     shellcheck skipped (not installed)
```

Don't "fix" a failing test by weakening it. If a failure is in code another branch is changing, say so instead of editing it.
