# Help us test

needs-you supports a dozen AI coding tools, but we haven't used most of them with a real model on a real project. If you use one of them, half an hour of normal work with needs-you running, and a short report of what you saw, is one of the most useful things you can do for the project. So is telling us about a tool we don't support yet.

## Where help matters most

Each agent's cards come from its hooks: an approval prompt or a question should post a card, and answering it should clear the card. We've checked each one as far as we could without your logins and projects:

- **In use:** run on real work by the maintainer.
- **Run against a stub:** the real tool, installed in a throwaway home directory and driven against a fake local model server. The hooks fired and the cards came and went, but no real model or account was involved, and some prompts never appeared.
- **Built from docs:** written from the tool's hook documentation and tested by replaying its documented payloads. Never run.

| Agent | How far we've checked it | Not seen yet: please try |
|---|---|---|
| [Claude Code](claude-code.md) | In use (hooks, skill), on the Mac, over SSH and in tmux | Question cards (AskUserQuestion) on more setups; [VS Code Remote-SSH and other places](claude-code-everywhere.md) |
| [Orca](orca.md) | In use with Orca 1.4 | Agents on more than one server |
| [Codex CLI](codex.md) | Run against a stub | A real approval card clearing when you approve; `/clear` in one session leaving another session's card alone; question cards (`request_user_input`) |
| [Gemini CLI](gemini.md) | Run against a stub | A waiting card in a trusted folder; question cards (`ask_user`) |
| [opencode](opencode.md) | Run against a stub (opencode 1.18.35) | Waiting cards in the TUI; **answering a question from the card** (built from opencode's source, never run live) |
| [Copilot CLI](copilot.md) | Run against a stub (Copilot CLI 1.0.93) | An edit or MCP-tool permission prompt (never captured); a shell-command prompt |
| [Kimi Code](kimi.md) | Run against a stub (Kimi Code 2.1.1), the full round trip in its TUI | A real approval; the waiting card clearing on your next prompt |
| [Grok Build](grok.md) | Run against a stub (grok 1.0.46) | A real permission prompt (never seen); the idle card arriving once, about a minute after a turn |
| [Aider](aider.md) | Run against a stub (Aider 0.86.2) | A real session: the waiting card, and typing in Aider staying unaffected |
| [Cline](cline.md) | CLI run against a stub (Cline CLI 3.0.69) | **The VS Code extension** (never run); a finished task's card clearing on a new task |
| [Cursor](cursor.md) | Built from docs (payloads replayed; it needs a login) | **Anything**: the "finished" card, and your next prompt going through and clearing it |
| [MCP server](mcp.md) | Tested with a scripted MCP client | Registering it in real clients (`--mcp claude,codex,...`) and an agent calling its tools |

Every integration's README under [integrations/](../../integrations/) says exactly what was run and how.

## How to test

1. Install the Mac app and connect the machine your agent runs on: the [install guide for testers](testers.md) takes about 15 minutes.
2. Set up your agent with its guide (the links in the table above). Most agents need a restart after their hooks are installed.
3. Turn on the hook log so a report can show what the hook saw: add `NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` to `~/.config/needs-you/env` (or export it before starting the agent).
4. Work as you normally would, and watch the pill. Things worth trying:
   - [ ] Make the agent ask for approval (a shell command it won't run on its own). A card appears; approving in the agent clears it.
   - [ ] Let the agent finish its turn and wait. A "waiting for you" card appears (for most agents); your next prompt clears it.
   - [ ] Ask the agent to ask you a question with choices. The card shows the question.
   - [ ] Run two sessions at once. Each gets its own card, and answering one doesn't clear the other.
   - [ ] Quit the agent while a card is up. The card goes away within about five minutes.
   - [ ] Keep typing in another app while cards arrive. The pill must never take keyboard focus.
5. Run `needs-you doctor` on the agent's machine; every `WARN` or `FAIL` line has a next step under it.

## Report back

Open a [Help us test an AI tool](https://github.com/tayharris/needs-you/issues/new?template=agent_test.yml) report: the tool and its version, your OS, which cards appeared and which didn't, and the parts of the hook log and `needs-you doctor` output that matter. A report that says "everything worked with version X" is welcome too: it moves a row in the table above.

Other ways to help:

- **A tool we don't support yet:** an [integration request](https://github.com/tayharris/needs-you/issues/new?template=integration_request.yml). Say where its hooks or notifications are documented, if you know.
- **An idea or something that annoyed you:** a [suggestion](https://github.com/tayharris/needs-you/issues/new?template=feature_request.yml).
- **Something broken outside an agent** (the app, the hub, the CLI, installing): a [bug report](https://github.com/tayharris/needs-you/issues/new?template=bug_report.yml).
- **Code:** see [CONTRIBUTING.md](../../CONTRIBUTING.md).

**Never paste a token (`ny_…`), an invite link or code (`nyi_…`, `/join/…`), or the contents of `~/.config/needs-you/env`.** The hook log holds item keys (which include the machine's name) and what each hook did, never tokens; skim it before you attach it, and replace host and tailnet names you'd rather not share with `devbox` and `<tailnet>`. Security problems go through [SECURITY.md](../../SECURITY.md), never an issue.
