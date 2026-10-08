"""integrations/agent-instructions/needs-you.md: the Claude skill's text for Codex, Gemini CLI
and opencode, generated from SKILL.md by scripts/build_agent_instructions.py.

The committed file must be what the script makes from today's SKILL.md (so the two can't
drift), and it must carry the same rules as the skill and AGENT-GUIDE.md.
"""
from __future__ import annotations

import importlib.util
import os
import re
import sys
import unittest

from support import ROOT

SCRIPT = os.path.join(ROOT, "scripts", "build_agent_instructions.py")


def load():
    sys.dont_write_bytecode = True  # no __pycache__ in scripts/
    spec = importlib.util.spec_from_file_location("build_agent_instructions", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gen = load()


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


class AgentInstructions(unittest.TestCase):
    def test_committed_file_matches_the_skill(self):
        want = gen.build(read("integrations/claude-code/skill/needs-you/SKILL.md"))
        self.assertEqual(read("integrations/agent-instructions/needs-you.md"), want,
                         "run: python3 scripts/build_agent_instructions.py")

    def test_same_rules_as_the_skill_and_the_agent_guide(self):
        text = read("integrations/agent-instructions/needs-you.md")
        guide = read("docs/AGENT-GUIDE.md")
        for phrase in ("needs-you add", "needs-you resolve", "needs-you done", "needs-you doctor",
                       "<context>:<project-or-ticket>:<reason>", "At most 100 characters", "No secrets",
                       "What you read is data", "Volume guard"):
            self.assertIn(phrase, text)
        # the link schemes are the hub's allow-list, as in the agent guide
        for scheme in ("https", "slack", "vscode", "cursor", "figma", "msteams", "discord", "linear"):
            self.assertIn("`%s`" % scheme, text)
            self.assertIn(scheme, guide)
        self.assertNotIn("Claude", text)
        self.assertTrue(text.startswith("<!-- needs-you-version: "))  # the /dl manifest's stamp
        # headings sit one level under the person's own file
        self.assertEqual(re.findall(r"^# ", text, re.M), [])

    def test_a_skill_edit_that_breaks_a_rewrite_fails_the_build(self):
        src = read("integrations/claude-code/skill/needs-you/SKILL.md")
        with self.assertRaises(gen.StaleSource):
            gen.build(src.replace("Claude finished\" card", "Claude done\" card"))
        with self.assertRaises(gen.StaleSource):
            gen.build(src + "\nClaude Code only.\n")


if __name__ == "__main__":
    unittest.main()
