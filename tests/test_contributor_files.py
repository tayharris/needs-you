"""The contributor entry points hang together: every issue template a link names exists,
security reports go to SECURITY.md, and the PR template asks for check.sh.
"""
from __future__ import annotations

import os
import re
import subprocess
import unittest

from support import ROOT

TEMPLATES = os.path.join(ROOT, ".github", "ISSUE_TEMPLATE")


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as fh:
        return fh.read()


class ContributorFilesTests(unittest.TestCase):
    def test_linked_templates_exist(self):
        files = subprocess.run(["git", "-C", ROOT, "ls-files", "*.md", "*.html", "*.yml"],
                               stdout=subprocess.PIPE, universal_newlines=True, check=True).stdout.split()
        linked = set()
        for path in files:
            for name in re.findall(r"issues/new\?template=([A-Za-z0-9_.-]+)", read(path)):
                linked.add(name)
                self.assertTrue(os.path.isfile(os.path.join(TEMPLATES, name)), "%s links %s" % (path, name))
        for name in ("bug_report.yml", "feature_request.yml", "agent_test.yml", "integration_request.yml"):
            self.assertIn(name, linked)

    def test_templates_have_the_fields_forms_need(self):
        for name in os.listdir(TEMPLATES):
            if name == "config.yml":
                continue
            text = read(".github", "ISSUE_TEMPLATE", name)
            for key in ("name:", "description:", "body:"):
                self.assertRegex(text, r"(?m)^" + key, name)

    def test_security_reports_go_to_security_md(self):
        config = read(".github", "ISSUE_TEMPLATE", "config.yml")
        self.assertIn("blank_issues_enabled: false", config)
        self.assertIn("/blob/main/SECURITY.md", config)

    def test_pr_template_asks_for_check_sh(self):
        self.assertIn("scripts/check.sh", read(".github", "PULL_REQUEST_TEMPLATE.md"))


if __name__ == "__main__":
    unittest.main()
