"""The agent-facing docs only mention `needs-you` commands and flags the CLI really has.

Agents copy these lines verbatim, so a made-up or renamed flag is an API break (ADR 0005)."""
from __future__ import annotations

import os
import re
import subprocess
import sys
import unittest

from support import CLI, ROOT

DOCS = [
    "integrations/claude-code/skill/needs-you/SKILL.md",
    "docs/AGENT-GUIDE.md",
    "integrations/orca/snippet.md",
    "docs/guides/mcp.md",
    "integrations/agent-instructions/needs-you.md",
]
TOP_LEVEL = {"-q", "--quiet", "--json", "--version"}
# `needs-you` (the CLI, also by path) followed by its arguments; not needs-you-admin, needs-you-hook.sh.
COMMAND_RE = re.compile(r"(?<![\w-])needs-you((?:[ \t]+(?:-q|--json))*)[ \t]+([a-z][a-z-]*)\b([^`\n]*)")
QUOTED_RE = re.compile(r"\"(?:[^\"\\]|\\.)*\"|'[^']*'")
FLAG_RE = re.compile(r"(?<![\w-])(--?[a-z][a-z-]*)")


def commands(text):
    """(subcommand, top-level flags, flags) for every `needs-you <sub> ...` in the code (fenced
    blocks, with shell line continuations joined, and inline spans), quoted values dropped."""
    code = []
    for block in re.findall(r"^```[^\n]*\n(.*?)^```", text, re.M | re.S):
        code.append(block.replace("\\\n", " "))
    prose = re.sub(r"^```[^\n]*\n.*?^```", "", text, flags=re.M | re.S)
    code.extend(re.findall(r"`([^`\n]+)`", prose))
    for m in COMMAND_RE.finditer("\n".join(code)):
        rest = QUOTED_RE.sub(" ", m.group(3))
        rest = rest.split(" -- ", 1)[0]  # `needs-you run ... -- CMD ARGS`: CMD's own flags
        rest = rest.split("#", 1)[0].split("|", 1)[0].split(">", 1)[0]
        yield m.group(2), FLAG_RE.findall(m.group(1)), FLAG_RE.findall(rest)


_HELP = {}


def options(sub):
    if sub not in _HELP:
        r = subprocess.run([sys.executable, CLI, sub, "--help"], capture_output=True, text=True, timeout=30)
        _HELP[sub] = set(re.findall(r"(?<![\w-])(--?[a-z][a-z-]*)", r.stdout)) if r.returncode == 0 else None
    return _HELP[sub]


class AgentDocsMatchTheCli(unittest.TestCase):
    def test_commands_and_flags_exist(self):
        seen = 0
        for rel in DOCS:
            path = os.path.join(ROOT, rel)
            if not os.path.exists(path):
                continue
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            for sub, top, flags in commands(text):
                seen += 1
                with self.subTest(doc=rel, command=sub, flags=flags):
                    self.assertTrue(set(top) <= TOP_LEVEL, top)
                    opts = options(sub)
                    self.assertIsNotNone(opts, "needs-you %s doesn't exist (%s)" % (sub, rel))
                    unknown = [f for f in flags if f not in opts]
                    self.assertEqual(unknown, [], "needs-you %s has no %s (%s)" % (sub, unknown, rel))
        self.assertGreater(seen, 20)

    def test_the_checker_catches_a_made_up_flag(self):
        found = list(commands('Run `needs-you add --key "a b --nope" --frobnicate x`; needs-you is fine.\n'
                              "```bash\nneeds-you run --key k \\\n  -- make --jobs 4\n```\n"))
        self.assertEqual(sorted(found), [("add", [], ["--key", "--frobnicate"]), ("run", [], ["--key"])])
        self.assertNotIn("--frobnicate", options("add"))


if __name__ == "__main__":
    unittest.main()
