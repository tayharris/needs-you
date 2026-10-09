"""scripts/check.sh runs what .github/workflows/ci.yml runs, and CI is safe for forked PRs.

Every `run:` command in ci.yml (except the `--version` prints) must appear in check.sh byte for
byte, so "passes locally" can't drift from "passes CI". Every job must keep forked PRs off
self-hosted runners, and ci.yml must not read secrets (a fork's PR doesn't get them).
"""
from __future__ import annotations

import os
import re
import subprocess
import unittest

from support import ROOT

CI = os.path.join(ROOT, ".github", "workflows", "ci.yml")
CHECK = os.path.join(ROOT, "scripts", "check.sh")
FORK_GUARD = "(github.event_name == 'pull_request' && github.event.pull_request.head.repo.fork) && "


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def ci_runs():
    return [m.group(1).strip() for m in re.finditer(r"^\s*- run: (.+)$", read(CI), re.M)]


class CheckScriptTests(unittest.TestCase):
    def test_every_ci_command_is_in_check_sh(self):
        check = read(CHECK)
        runs = [r for r in ci_runs() if not r.endswith("--version")]
        self.assertTrue(any(r.startswith("shellcheck ") for r in runs), runs)
        self.assertTrue(any("-m unittest discover -s tests" in r for r in runs), runs)
        self.assertTrue(any("scripts/lint_repo.py" in r for r in runs), runs)
        for cmd in runs:
            self.assertIn(cmd, check, "ci.yml runs %r but scripts/check.sh doesn't" % cmd)

    def test_executable_and_valid_bash(self):
        self.assertTrue(os.access(CHECK, os.X_OK))
        subprocess.run(["bash", "-n", CHECK], check=True)

    def test_unknown_option_fails(self):
        out = subprocess.run([CHECK, "--bogus"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(out.returncode, 2)

    def test_documented_in_contributing(self):
        self.assertIn("scripts/check.sh", read(os.path.join(ROOT, "CONTRIBUTING.md")))


class ForkSafetyTests(unittest.TestCase):
    def test_every_job_keeps_forks_off_self_hosted_runners(self):
        runs_on = re.findall(r"^    runs-on: (.+)$", read(CI), re.M)
        jobs = re.findall(r"^  ([a-z0-9-]+):$", read(CI).split("\njobs:\n", 1)[1], re.M)
        self.assertEqual(len(runs_on), len(jobs), jobs)
        for line in runs_on:
            if "vars." in line:
                self.assertIn(FORK_GUARD, line)

    def test_no_secrets(self):
        self.assertNotIn("secrets.", read(CI))


if __name__ == "__main__":
    unittest.main()
