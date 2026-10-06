"""The Orca automation prompt block and the Claude Code hook's Orca card body.

Orca has no terminal or worktree deep link, so both name the worktree and the
`orca terminal switch` command in the item body. Everything runs with a
temporary HOME and a fake `needs-you` CLI that records its argv.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

from support import ROOT

BASH = shutil.which("bash") or "/bin/bash"
INSTALLER = os.path.join(ROOT, "hub", "join-install.sh")
README = os.path.join(ROOT, "integrations", "orca", "README.md")
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")

FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
"""


def installer_snippet():
    with open(INSTALLER) as fh:
        s = fh.read()
    m = re.search(r"cat >\"\$CONF_DIR/orca-snippet\.md\" <<'EOF'\n(.*?)\nEOF\n", s, re.S)
    assert m, "orca snippet heredoc not found in join-install.sh"
    return m.group(1) + "\n"


def readme_snippet():
    with open(README) as fh:
        s = fh.read()
    m = re.search(r"<!-- orca-snippet:start -->\n```markdown\n(.*?)```\n<!-- orca-snippet:end -->", s, re.S)
    assert m, "orca-snippet markers not found in integrations/orca/README.md"
    return m.group(1)


class OrcaSnippetTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-orca-")
        self.addCleanup(shutil.rmtree, self.home, True)

    def test_readme_and_installer_carry_the_same_block(self):
        self.assertEqual(readme_snippet(), installer_snippet())

    def test_block_has_links_resolve_and_no_orca_deep_link(self):
        s = installer_snippet()
        self.assertNotIn("orca://", s)
        for want in ('--link "Jira=', '--link "PR=', '--link "Branch=',
                     "orca terminal switch", "needs-you resolve --key \"work:<TICKET>:<reason>\"",
                     "$ORCA_TERMINAL_HANDLE", "ORCA_WORKTREE_ID", "--expires-in"):
            self.assertIn(want, s)

    def body_from_block(self, orca_env=None):
        lines = re.search(r"^    (orca_env=.*?\"\$jump\"\))$", installer_snippet(), re.M | re.S).group(1)
        script = "\n".join(l[4:] if l.startswith("    ") else l for l in lines.split("\n"))
        conf = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(conf, exist_ok=True)
        with open(os.path.join(conf, "env"), "w") as fh:
            fh.write("NEEDS_YOU_TOKEN=x\n")
            if orca_env:
                fh.write("NEEDS_YOU_ORCA_ENVIRONMENT='%s'\n" % orca_env)
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "ORCA_WORKTREE_ID": "repo1::/home/me/wt/ACME-1", "ORCA_TERMINAL_HANDLE": "term_abc"}
        r = subprocess.run([BASH, "-c", script + '\nprintf "%s" "$body"'], env=env,
                           capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def test_block_body_names_worktree_and_switch_command(self):
        body = self.body_from_block()
        self.assertIn("Orca worktree: `/home/me/wt/ACME-1`", body)
        self.assertIn("`orca terminal switch --terminal term_abc`", body)
        self.assertNotIn("$", body)

    def test_block_adds_environment_from_env_file(self):
        body = self.body_from_block("My Devbox")
        self.assertIn('`orca terminal switch --environment "My Devbox" --terminal term_abc`', body)
        self.assertNotIn("NEEDS_YOU_TOKEN", body)


class HookOrcaBodyTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-hook-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.cli = os.path.join(self.home, "fake-needs-you")
        with open(self.cli, "w") as fh:
            fh.write(FAKE_CLI)
        os.chmod(self.cli, 0o755)
        self.log = os.path.join(self.home, "calls.log")

    def notify(self, **extra):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_BIN": self.cli, "FAKE_CLI_LOG": self.log,
               "ORCA_TERMINAL_HANDLE": "term_abc", "ORCA_WORKTREE_ID": "repo1::/home/me/wt/ACME-1"}
        cwd = extra.pop("_cwd", "/home/me/wt/ACME-1/api")
        env.update(extra)
        data = json.dumps({"session_id": "s1", "cwd": cwd,
                           "message": "Claude needs your permission to use Bash",
                           "notification_type": "permission_prompt"})
        r = subprocess.run([BASH, HOOK, "notify"], input=data, env=env,
                           capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        with open(self.log) as fh:
            return json.loads(fh.read().splitlines()[-1])

    def body(self, argv):
        return argv[argv.index("--body") + 1]

    def test_orca_card_names_worktree_and_switch_command(self):
        argv = self.notify()
        body = self.body(argv)
        self.assertIn("Orca worktree `/home/me/wt/ACME-1`", body)
        self.assertIn("`orca terminal switch --terminal term_abc`", body)
        self.assertNotIn("--link", argv)

    def test_worktree_not_repeated_when_it_is_the_cwd(self):
        body = self.body(self.notify(_cwd="/home/me/wt/ACME-1"))
        self.assertNotIn("Orca worktree", body)
        self.assertIn("orca terminal switch --terminal term_abc", body)

    def test_orca_environment_from_env_file(self):
        conf = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(conf)
        with open(os.path.join(conf, "env"), "w") as fh:
            fh.write("NEEDS_YOU_ORCA_ENVIRONMENT='My Devbox'\n")
        body = self.body(self.notify())
        self.assertIn("`orca terminal switch --environment 'My Devbox' --terminal term_abc`", body)

    def test_outside_orca_no_switch_command(self):
        argv = self.notify(ORCA_TERMINAL_HANDLE="", ORCA_WORKTREE_ID="", NEEDS_YOU_AGENT_ALERTS="1")
        body = self.body(argv)
        self.assertNotIn("orca terminal switch", body)
        self.assertIn("Session `s1`", body)


if __name__ == "__main__":
    unittest.main()
