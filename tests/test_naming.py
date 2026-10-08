"""The part names stay consistent: the Needs You app, a hub (built in, or a server hub), senders.

docs/guides/concepts.md defines them. These names were retired because they blurred the app and
the hub ("your Mac is the hub", a Settings page called "Your inbox"); this keeps them from
creeping back into the docs, the site, the READMEs or the app's strings. History (CHANGELOG,
docs/roadmap, docs/adr) and concepts.md's one "Older builds called these pages ..." line may
still use them.
"""
from __future__ import annotations

import os
import re
import unittest

from support import ROOT

RETIRED = [
    re.compile(r"Your inbox"),             # the Settings page, now "Built-in hub"
    re.compile(r"Inbox and machines"),     # the sidebar group, now "Hubs and machines"
    re.compile(r"Mac is the hub", re.I),   # the app shows alerts; its built-in hub stores them
    re.compile(r"as my inbox"),            # the welcome button
    re.compile(r"\[Words\]\((?!#)"),       # the concepts guide's old title (not quickstart's own #words)
]

# Files and folders that describe the product today. History is left alone.
SCAN = ["README.md", "docs", "site", "mac/README.md", "mac/Sources", "integrations", "scripts"]
# NeedsYouSelfTest links the Swift tests, which check the old names are gone.
SKIP_DIRS = {os.path.join("docs", "roadmap"), os.path.join("docs", "adr"),
             os.path.join("mac", "Sources", "NeedsYouSelfTest"), "__pycache__"}
EXTS = (".md", ".html", ".swift", ".sh", ".py", ".js", ".json")
ALLOWED_LINE = "Older builds called these pages"


def files():
    for top in SCAN:
        path = os.path.join(ROOT, top)
        if os.path.isfile(path):
            yield top
            continue
        for dirpath, dirnames, filenames in os.walk(path):
            rel = os.path.relpath(dirpath, ROOT)
            dirnames[:] = [d for d in dirnames if os.path.join(rel, d) not in SKIP_DIRS and d not in SKIP_DIRS]
            for name in filenames:
                if name.endswith(EXTS):
                    yield os.path.join(rel, name)


class RetiredNamesTest(unittest.TestCase):
    def test_no_retired_part_names(self):
        hits = []
        scanned = 0
        for rel in files():
            scanned += 1
            with open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace") as fh:
                for n, line in enumerate(fh, 1):
                    if ALLOWED_LINE in line:
                        continue
                    for pattern in RETIRED:
                        if pattern.search(line):
                            hits.append("%s:%d: %s" % (rel, n, pattern.pattern))
        self.assertGreater(scanned, 50)
        self.assertEqual(hits, [], "retired names (see docs/guides/concepts.md):\n" + "\n".join(hits))

    def test_concepts_defines_the_three_parts(self):
        with open(os.path.join(ROOT, "docs", "guides", "concepts.md"), encoding="utf-8") as fh:
            text = fh.read()
        for name in ("The Needs You app", "A hub", "Senders", "built-in hub", "server hub",
                     "Owner", "Reader", "Sender", "Peer", "Invite link"):
            self.assertIn(name, text)


if __name__ == "__main__":
    unittest.main()
