---
name: add-integration
description: Add a new needs-you sender integration (a tool, CI system, scheduler or agent framework that posts items) with its script, README, user guide, tests and links. Use when asked to "integrate needs-you with X" or add a new folder under integrations/.
---

# add-integration

An integration is a thin layer that calls the `needs-you` CLI (preferred: outbox + failover) or `POST /v1/items` with curl. It adds no hub features. Look at `integrations/ci/` (scripts + examples) and `integrations/claude-code/` (installer + hook + skill) as models.

## Rules for the integration itself

- **Never fail the caller.** Exit 0 on hub errors; hooks always exit 0. Let the CLI queue.
- **Stable keys:** `<context-prefix>:<project-or-thing>:<reason>`. Never a timestamp or run id.
- **Resolve what you post** (on success, on the next run, or on a "moved on" event).
- **No secrets or raw output in items.** Link to logs instead of pasting them (see `run-or-alert.sh`).
- **Opt-in when noisy.** Default off, like `NEEDS_YOU_AGENT_ALERTS` for the Claude hooks.
- **Config via the existing env file** `~/.config/needs-you/env` and `NEEDS_YOU_*` variables. Prefix new ones `NEEDS_YOU_<INTEGRATION>_`.
- bash scripts: `set -euo pipefail` where it can't break the caller, macOS bash 3.2 compatible, no jq, no package installs. Python: stdlib, 3.9.
- Only allowed link schemes: `https orca slack vscode cursor figma msteams discord`.

## Files

| File | Content |
|---|---|
| `integrations/<name>/README.md` | Reference: what it does, files, config, keys it uses, how to test it |
| `integrations/<name>/<script or config>` | The integration. Executable bit set for scripts |
| `docs/guides/<name>.md` | Task-oriented guide: prerequisites (a sender machine), install, opt-in, "check it works", link to troubleshooting |
| `docs/guides/troubleshooting.md` | A section if it has failure modes of its own |
| `README.md` | A row in the "Get started" guide table |
| `site/index.html` | Optional: a card in the integrations grid |
| `docs/AGENT-GUIDE.md` | Only if agents need new rules |
| `tests/test_<name>.py` | Run the script against a real local hub (use `tests/support.py`: `HubTestCase`, a temp `HOME`, `NEEDS_YOU_URL`/`NEEDS_YOU_TOKEN` in the env). Cover: post on failure, resolve on success, exit 0 when the hub is down, nothing posted when not opted in |

There are no integration tests in `tests/` yet; a new integration should add the first one rather than skip it.

## Check

1. `test-all` skill.
2. Run it by hand against the `smoke-e2e` hub and watch the item appear and resolve (or run the Mac app in demo mode to see the card shape).
3. `bash -n` and, if available, `shellcheck` on new scripts.
4. Grep your docs for personal hostnames and tokens before committing.
