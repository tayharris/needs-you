# 0005. AI-first repo and product

- Status: Accepted
- Date: 2026-10-06

## Context

needs-you exists because agents get blocked on people and have no good way to say so ([PLAN.md, "Why"](../PLAN.md#why)). Its senders are mostly AI agents and automations, and much of its setup will be done by agents too: a person clicks "Invite a machine" and pastes a prompt into Claude Code, which installs the CLI and configures itself. The code itself is also largely written by coding agents working in parallel worktrees.

If agents are the main users and contributors, the parts they read are product surface, not documentation afterthoughts.

## Decision

The product goal is: **give AI agents the tools to set themselves up and to alert people when they actually need them, routed to where they need to act.**

Concretely:

1. **Agent-facing entry points are first-class** and versioned like the API: the invite prompt and `/join` page, `docs/AGENT-GUIDE.md`, the Claude skill, the Claude Code hooks, and (planned) an MCP server and `needs-you doctor`. Changing their behaviour gets the same review as an API change.
2. **The repo is built for agents to work in:** `CLAUDE.md` (and `AGENTS.md` for other agents) give the map, the build/test commands and the hard rules; `.claude/skills/` hold repeatable procedures (`test-all`, `smoke-e2e`, `api-change`, `add-integration`, `release`); ADRs record why things are the way they are.
3. **Machine-readable over prose where it matters:** a JSON API spec and a conformance suite in `protocol/`, JSON output modes (`--json`) on every CLI command, and diagnostics with actionable `fix` strings.
4. **Quiet by default.** Agents should post rarely and precisely; the tools enforce it (stable keys, dedupe, volume guard, opt-in hooks). An AI-first alerting tool that cries wolf fails its purpose.

The plan for getting there is [roadmap/ai-first.md](../roadmap/ai-first.md).

## Consequences

- Repo layout should be predictable for agents; [ai-first.md](../roadmap/ai-first.md) lists proposed moves (a `protocol/` dir, one place per integration, one place for agent-facing material). They're deferred until in-flight branches merge.
- Every new feature asks: how does an agent discover it, set it up, and verify it worked?
- Prompts and skills need tests too (at least a check that the commands they mention exist with those flags).
- Human UX still matters: the person on the receiving end decides whether the alerts are worth keeping. Routing to "where they need to act" (the right device, the right app via links) is part of the goal, not an add-on.
