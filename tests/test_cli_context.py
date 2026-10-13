"""`needs-you context`: work or personal per poller, team, project, owner or repo, written to
the env file (the Mac's Settings → Integrations pickers hand the person these commands).
Only the one variable changes; every other line, the token's included, stays as it was."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

from support import CLI


class ContextCommand(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-ctx-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.env = os.path.join(self.home, "env")

    def write(self, text):
        with open(self.env, "w") as fh:
            fh.write(text)

    def read(self):
        with open(self.env) as fh:
            return fh.read()

    def run_cli(self, *args, env=None):
        e = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_CONFIG": self.env}
        e.update(env or {})
        return subprocess.run([sys.executable, CLI] + list(args), env=e, capture_output=True, text=True, timeout=30)

    def test_sets_one_entry_and_keeps_the_rest(self):
        self.write("# mine\nNEEDS_YOU_TOKEN=nyt_keepme\nNEEDS_YOU_GITHUB_CONTEXTS=acme=work\n")
        r = self.run_cli("context", "github", "acme/side", "personal")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("nyt_keepme", r.stdout + r.stderr)
        r = self.run_cli("context", "github", "Example-User", "personal")
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.run_cli("context", "github", "ACME", "personal")   # owners compare case-insensitively
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read(), "# mine\nNEEDS_YOU_TOKEN=nyt_keepme\n"
                         "NEEDS_YOU_GITHUB_CONTEXTS=acme/side=personal,example-user=personal,acme=personal\n")
        self.assertEqual(os.stat(self.env).st_mode & 0o777, 0o600)

    def test_team_keys_star_and_default(self):
        self.write("NEEDS_YOU_TOKEN=t\n")
        for args in (("linear", "acme", "personal"), ("linear", "*", "work"), ("jira", "OPS", "personal"),
                     ("linear", "ACME", "default"), ("expiry", "*", "personal")):
            r = self.run_cli("context", *args)
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read(), "NEEDS_YOU_TOKEN=t\nNEEDS_YOU_LINEAR_CONTEXTS=*=work\n"
                         "NEEDS_YOU_JIRA_CONTEXTS=OPS=personal\nNEEDS_YOU_EXPIRY_CONTEXT=personal\n")
        r = self.run_cli("context")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("NEEDS_YOU_LINEAR_CONTEXTS=*=work", r.stdout)
        self.assertNotIn("NEEDS_YOU_TOKEN", r.stdout)

    def test_bad_names_and_values_are_refused(self):
        self.write("NEEDS_YOU_TOKEN=t\n")
        for args in (("expiry", "acme", "work"), ("jira", "ACME-1", "work"), ("linear", "a,b", "work"),
                     ("github", "acme=work", "work"), ("linear", "ACME")):
            r = self.run_cli("context", *args)
            self.assertEqual(r.returncode, 2, args)
        r = self.run_cli("context", "linear", "ACME", "home")
        self.assertEqual(r.returncode, 2)
        r = self.run_cli("context", "slack", "x", "work")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.read(), "NEEDS_YOU_TOKEN=t\n")

    def test_environment_override_is_named(self):
        r = self.run_cli("context", "jira", "ACME", "work", env={"NEEDS_YOU_JIRA_CONTEXTS": "ACME=personal"})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("overrides the file", r.stderr)


if __name__ == "__main__":
    unittest.main()
