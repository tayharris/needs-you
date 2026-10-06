# 0002. Python 3 standard library only for the hub and CLI

- Status: Accepted
- Date: 2026-10-06

## Context

Senders run on whatever machines people already have: stock Ubuntu VMs, macOS laptops, CI runners, small boxes nobody wants to provision. Every install step (pip, a virtualenv, brew, a compiled binary per architecture) is a reason an agent's setup fails halfway, and a dependency tree is a supply-chain surface on machines that hold real credentials.

Stock Ubuntu 22.04+ and Debian 12+ ship Python 3.10+; macOS ships `/usr/bin/python3` 3.9 with the Command Line Tools. Both include `sqlite3`, `http.server`, `urllib`, `json`, `hashlib`, `secrets` and `threading`, which is all a small HTTP + SQLite service needs.

## Decision

The hub (`hub/needs_you_hub.py`, `hub/needs_you_admin.py`) and the CLI (`cli/needs-you`) use the Python 3 standard library only, and stay compatible with Python 3.9:

- `from __future__ import annotations`; no `match`, no runtime `X | Y` unions, no `tomllib`, no 3.10+ stdlib APIs.
- The CLI is one executable file that works when copied anywhere.
- Shell scripts use bash 3.2-compatible syntax, `curl` and `python3`; no `jq`.
- Tests use `unittest`. CI runs them on macOS `/usr/bin/python3` 3.9 ([ci-cd.md](../roadmap/ci-cd.md)).

Adding any third-party runtime dependency requires a new ADR.

## Consequences

- Install is "copy a file". The invite one-liner and `setup-sender.sh` can't fail on a package manager.
- We write a little more code ourselves (ULIDs, timestamp parsing, a threaded HTTP server, SSE) and maintain it.
- `http.server` is not a hardened internet-facing server. That's acceptable because hubs bind loopback or the tailnet only. A public-facing hub would be a different implementation ([0004](0004-always-on-hub.md) option (c)).
- Some conveniences are off-limits (YAML, `tomllib`, `match`). A machine-readable spec should therefore be JSON ([ai-first.md](../roadmap/ai-first.md)).
- The Mac app (Swift) and any future implementations are not bound by this rule, but they follow the same spirit: no dependencies without an ADR.
