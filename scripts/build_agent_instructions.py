#!/usr/bin/env python3
"""Build integrations/agent-instructions/needs-you.md from the Claude Code skill.

    python3 scripts/build_agent_instructions.py           # write the file
    python3 scripts/build_agent_instructions.py --check   # exit 1 if it is stale

The invite installer's `--agent-instructions codex,gemini,opencode` puts this text, as a
marked block, into the agents' user-level instruction files (~/.codex/AGENTS.md,
~/.gemini/GEMINI.md, ~/.config/opencode/AGENTS.md): what the skill is for Claude Code. It
is generated from integrations/claude-code/skill/needs-you/SKILL.md, the one source, so the
two can't say different things. The output is committed (the hub serves it as
/dl/agent-instructions.md) and tests/test_agent_instructions.py fails when it is stale.

The changes from SKILL.md: no front matter; headings one level down (the block sits inside
the person's own file); an intro line that says where the block came from; nothing that only
holds for Claude Code. Each rewrite must match exactly once, so a SKILL.md edit that breaks
one fails the build instead of leaking Claude-only text. Stdlib only, Python 3.9.
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "integrations", "claude-code", "skill", "needs-you", "SKILL.md")
OUTPUT = os.path.join(ROOT, "integrations", "agent-instructions", "needs-you.md")

INTRO = ("This block was added by the needs-you installer (`--agent-instructions`), generated from the "
         "needs-you skill (SKILL.md); `needs-you update` keeps it current and `needs-you uninstall-hooks "
         "--instructions` removes it.")

# (old, new): exact text in SKILL.md, each replaced once.
REWRITES = [
    ("--agent claude-code --project app", "--agent my-agent --project app"),
    ("--agent claude-code --project billing", "--agent my-agent --project billing"),
    ("(key `agent:<host>:<session>`); don't duplicate those.",
     "(key `agent:<host>:<session>`); don't duplicate those. Pass your own name as `--agent` "
     "(`codex`, `gemini`, `opencode`)."),
    ('"source":{"agent":"claude-code",', '"source":{"agent":"my-agent",'),
    ("the hooks skip their generic \"Claude is waiting for you\" card",
     "the hooks skip their generic \"waiting for you\" card"),
    # Answering from the card through the hooks is Claude Code's (opencode's plugin answers
    # its own question tool without the agent's doing).
    (" A question you ask with your own question tool (`AskUserQuestion`) can be answered from the card "
     "in Claude Code, so prefer it over asking in plain text when there are a few clear choices.", ""),
]


class StaleSource(Exception):
    pass


def build(source: str) -> str:
    text = source
    m = re.match(r"^---\n.*?\n---\n", text, re.S)
    if not m:
        raise StaleSource("SKILL.md has no front matter")
    text = text[m.end():]
    for old, new in REWRITES:
        n = text.count(old)
        if n != 1:
            raise StaleSource("SKILL.md has %d copies of %r (expected 1): update REWRITES in %s"
                              % (n, old, os.path.basename(__file__)))
        text = text.replace(old, new)
    out, fenced = [], False
    for line in text.splitlines():
        if line.startswith("```"):
            fenced = not fenced
        elif not fenced and line.startswith("#"):
            line = "#" + line
        out.append(line)
        if not fenced and line.startswith("## needs-you"):
            out.extend(["", INTRO])
    text = "\n".join(out).strip("\n") + "\n"
    if "claude-code" in text.replace("anthropic.claude-code", "") or "Claude" in text:
        raise StaleSource("the generated text still mentions Claude Code: add a rewrite")
    return text


def main(argv: list) -> int:
    with open(SOURCE, encoding="utf-8") as fh:
        want = build(fh.read())
    if "--check" in argv:
        try:
            with open(OUTPUT, encoding="utf-8") as fh:
                have = fh.read()
        except OSError:
            have = ""
        if have != want:
            print("%s is stale: run python3 scripts/build_agent_instructions.py" % os.path.relpath(OUTPUT, ROOT))
            return 1
        return 0
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", encoding="utf-8") as fh:
        fh.write(want)
    print("wrote %s" % os.path.relpath(OUTPUT, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
