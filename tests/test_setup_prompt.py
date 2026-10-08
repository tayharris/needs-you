"""The "set up needs-you for me" agent prompt: one text in three places (the guide, the README
and the landing page), and every installer flag it names is real.

The guide's ```prompt block is the source; the README and site/index.html carry copies, so
they can't drift. The flags are checked against hub/join-install.sh's option parser, so a
renamed flag fails here before an agent runs a command that doesn't exist."""
from __future__ import annotations

import html
import os
import re
import unittest

from support import ROOT

GUIDE = os.path.join(ROOT, "docs", "guides", "setup-with-an-agent.md")


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as fh:
        return fh.read()


def guide_prompt():
    m = re.search(r"```prompt\n(.*?)\n```", read("docs", "guides", "setup-with-an-agent.md"), re.S)
    assert m, "no ```prompt block in the guide"
    return m.group(1)


class SetupPrompt(unittest.TestCase):
    def test_readme_has_the_same_prompt(self):
        m = re.search(r"<summary>The \"set up needs-you for me\" prompt</summary>\n\n```text\n(.*?)\n```",
                      read("README.md"), re.S)
        self.assertIsNotNone(m)
        self.assertEqual(m.group(1), guide_prompt())

    def test_landing_page_has_the_same_prompt_with_a_copy_button(self):
        m = re.search(r'<div class="code prompt" data-copy><pre><code>(.*?)</code></pre></div>',
                      read("site", "index.html"), re.S)
        self.assertIsNotNone(m)
        self.assertEqual(html.unescape(m.group(1)), guide_prompt())

    def test_built_guide_has_a_copy_button(self):
        self.assertIn('<div class="code prompt" data-copy>', read("site", "guides", "setup-with-an-agent.html"))

    def test_every_flag_is_an_installer_option(self):
        installer = read("hub", "join-install.sh")
        options = set(re.findall(r"^\s+(--[a-z][a-z-]*)(?:\|-[a-z])?\)", installer, re.M))
        self.assertIn("--claude-hooks", options)
        used = set(re.findall(r"(?<![\w-])(--[a-z][a-z-]+)", guide_prompt()))
        # Flags of other commands the prompt runs, not the installer's.
        others = {"--json", "--ignore-missing", "--install", "--app", "--dest", "--key", "--context", "--title"}
        unknown = sorted(f for f in used - others if f not in options)
        self.assertEqual(unknown, [], "the prompt names flags the installer doesn't have")

    def test_ask_points_and_rules(self):
        p = guide_prompt()
        self.assertGreaterEqual(p.count("ASK"), 8)
        for must in ("Never answer for me", "Never print, paste or save a token or an invite code",
                     "no sudo", "Never turn Gatekeeper off", "shasum -a 256 -c SHA256SUMS",
                     "Don't install it or log in for me", "--no-auto-update only if I ask",
                     "needs-you doctor", "needs-you resolve"):
            self.assertIn(must, p)
        self.assertNotIn("spctl --master-disable", p)


if __name__ == "__main__":
    unittest.main()
