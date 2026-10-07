"""scripts/rollout.sh with a fake `ssh` on PATH: each "host" is a directory used as HOME,
with or without a fake needs-you CLI."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest

from support import ROOT

BASH = shutil.which("bash") or "/bin/bash"
SCRIPT = os.path.join(ROOT, "scripts", "rollout.sh")

FAKE_SSH = """#!/bin/sh
# fake ssh: last two args are the host and the remote command
while [ $# -gt 2 ]; do echo "$1" >> "$FAKE_LOG"; shift; done
host=$1; cmd=$2
echo "host=$host" >> "$FAKE_LOG"
if [ "$host" = down ]; then echo "ssh: connect to host down port 22: Connection refused" >&2; exit 255; fi
HOME="$FAKE_HOSTS/$host" PATH=/usr/bin:/bin exec /bin/sh -c "$cmd"
"""

FAKE_CLI = """#!/bin/sh
case "$*" in
  "--json update --check") echo '{"ok": true, "cli": "0.1.1", "changes": [{"file": "SKILL.md", "from": "0.1.0", "to": "0.1.1"}], "applied": [], "errors": []}' ;;
  "--json update") if [ -f "$HOME/broken" ]; then echo '{"ok": false, "errors": ["update refused: SKILL.md does not match"]}'; else echo '{"ok": true, "cli": "0.1.1", "changes": [], "applied": ["SKILL.md"], "errors": []}'; fi ;;
  "doctor --json") echo '{"ok": true, "version": "0.1.1", "checks": [{"check": "update", "status": "OK", "detail": "CLI 0.1.1; hook 0.1.1; skill none; orca none; hub x"}]}' ;;
esac
"""


class Rollout(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ny-rollout-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = os.path.join(self.tmp, "bin")
        self.hosts = os.path.join(self.tmp, "hosts")
        os.makedirs(self.bin)
        self.log = os.path.join(self.tmp, "ssh.log")
        with open(os.path.join(self.bin, "ssh"), "w") as fh:
            fh.write(FAKE_SSH)
        os.chmod(os.path.join(self.bin, "ssh"), 0o755)
        for host, cli in (("devbox", True), ("ci", True), ("bare", False)):
            d = os.path.join(self.hosts, host, ".local", "bin")
            os.makedirs(d)
            if cli:
                with open(os.path.join(d, "needs-you"), "w") as fh:
                    fh.write(FAKE_CLI)
                os.chmod(os.path.join(d, "needs-you"), 0o755)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)

    def run_script(self, *args):
        env = {"PATH": self.bin + ":" + os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "FAKE_LOG": self.log, "FAKE_HOSTS": self.hosts}
        return subprocess.run([BASH, SCRIPT] + list(args), env=env, capture_output=True, text=True, timeout=60)

    def test_updates_hosts_and_prints_a_table(self):
        r = self.run_script("devbox", "ci")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        lines = r.stdout.splitlines()
        self.assertTrue(lines[0].startswith("host"))
        self.assertRegex(r.stdout, r"devbox\s+0\.1\.1\s+0\.1\.1\s+none\s+ok\s+updated SKILL\.md")
        self.assertIn("2 hosts, 0 with problems", r.stdout)
        with open(self.log) as fh:
            log = fh.read()
        self.assertIn("BatchMode=yes", log)
        self.assertIn("ConnectTimeout=10", log)

    def test_check_unreachable_missing_cli_and_refusal(self):
        open(os.path.join(self.hosts, "ci", "broken"), "w").close()
        r = self.run_script("--check", "devbox", "down", "bare")
        self.assertEqual(r.returncode, 1)
        self.assertRegex(r.stdout, r"devbox .* would update SKILL\.md")
        self.assertIn("unreachable: ssh: connect to host down", r.stdout)
        self.assertIn("no needs-you CLI (set it up with an invite link)", r.stdout)
        r = self.run_script("ci")
        self.assertEqual(r.returncode, 1)
        self.assertIn("failed: update refused", r.stdout)

    def test_hosts_file_and_bad_names(self):
        conf = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(conf)
        with open(os.path.join(conf, "hosts"), "w") as fh:
            fh.write("# my machines\ndevbox\n\n  ci  # the runner\n")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("2 hosts", r.stdout)
        r = self.run_script("-oProxyCommand=evil")
        self.assertEqual(r.returncode, 2)
        r = self.run_script("--", "x")
        self.assertEqual(r.returncode, 2)
        r = self.run_script("dev*box")
        self.assertEqual(r.returncode, 2)
        self.assertIn("not a host alias", r.stderr)
        os.remove(os.path.join(conf, "hosts"))
        r = self.run_script()
        self.assertEqual(r.returncode, 2)
        self.assertIn("one SSH alias per line", r.stderr)


if __name__ == "__main__":
    unittest.main()
