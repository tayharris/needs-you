# AGENTS.md

## Working on this repo

Read [CLAUDE.md](CLAUDE.md). It applies to every coding agent, not just Claude: the repo map, how to build and test each part, the hard rules (stdlib-only Python 3.9, the panel never takes focus, tokens never logged or committed, hubs bind loopback/tailnet only, API changes touch every client), and the branch and commit conventions.

Task recipes live in [.claude/skills/](.claude/skills/) as plain Markdown (`test-all`, `smoke-e2e`, `api-change`, `add-integration`, `release`). Any agent can follow them.

---

## Using needs-you from an agent

This section is for agents that want to **send** alerts, in any repo, not for agents changing this one.

needs-you lets you tell a person "I need you for X" when you're blocked on a decision, approval or access, when a long job they're waiting on finished, or when something broke that they need to know about today. It's not for progress updates.

- **The contract:** [docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md): when to post, stable keys, titles that state the action, links to where the person acts, resolving what you posted, never sending secrets.
- **Claude Code skill:** [integrations/claude-code/skill/needs-you/SKILL.md](integrations/claude-code/skill/needs-you/SKILL.md). Install with `cp -R integrations/claude-code/skill/needs-you ~/.claude/skills/`.
- **Hooks** for "agent is waiting" cards: [docs/guides/claude-code.md](docs/guides/claude-code.md).
- **Setting a machine up:** the person clicks **Invite a machine** in the Mac app and hands you a prompt or a one-line command; or see [docs/guides/add-a-sender.md](docs/guides/add-a-sender.md).
- **HTTP API**, if you can't use the CLI: [docs/API.md](docs/API.md).
