"""The Claude usage-limit helper (integrations/claude-code/needs-you-usage) as the invite
installer sets it up: `--usage` puts it next to the CLI as ~/.local/bin/needs-you-usage,
`--uninstall` removes it, `needs-you update` keeps an installed copy current and never adds
one. The hub serves it on /dl with its checksum and version stamp.

Temporary HOME and stub crontab/launchctl/uname/claude only: the real ~/.claude and crontab
are never touched. Nothing here changes a status line setting: wiring it in is the user's.
"""
from __future__ import annotations

import json
import os
import hashlib

import test_install
import test_mcp_install
from support import OPENER, ROOT, HubTestCase, request
from test_cli_update import FakeHub, current_files, read

USAGE = os.path.join(ROOT, "integrations", "claude-code", "needs-you-usage")


class Served(HubTestCase):
    # The MCP installer tests' temp HOME, stubs and test hub, without their tests.
    env = test_install.InstallScript.env
    invite = test_install.InstallScript.invite
    install = test_install.InstallScript.install
    p = test_mcp_install.Installer.p

    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        self.stubs = os.path.join(self.tmp, "stubs")
        os.makedirs(self.home)
        os.makedirs(self.stubs)
        for name in ("crontab", "launchctl", "uname"):
            path = os.path.join(self.stubs, name)
            with open(path, "w") as fh:
                fh.write(test_install.STUB)
            os.chmod(path, 0o755)
        self.log = os.path.join(self.tmp, "stub.log")
        self.cron = os.path.join(self.tmp, "crontab")
        self.hub = self.make_hub("hub-a", peers=[])
        self.hub.store.ensure_token("this-mac", "owner", test_install.OWNER)
        self.assertNotEqual(self.home, test_mcp_install.REAL_HOME)

    def test_hub_serves_it_with_checksum_and_stamp(self):
        _, manifest = request("GET", self.hub.url + "/dl/manifest.json")
        entry = manifest["files"]["needs-you-usage"]
        self.assertEqual(entry["sha256"], hashlib.sha256(read(USAGE)).hexdigest())
        self.assertEqual(entry["version"], manifest["version"])
        inv = self.invite()
        with OPENER.open(inv["join_url"] + "/install.sh", timeout=10) as resp:
            self.assertIn("needs-you-usage=" + entry["sha256"], resp.read().decode())

    def test_usage_flag_installs_and_uninstall_removes(self):
        inv = self.invite()
        r = self.install(inv, "--yes", "--usage")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        helper = self.p(".local", "bin", "needs-you-usage")
        self.assertTrue(os.access(helper, os.X_OK))
        self.assertEqual(read(helper), read(USAGE))
        self.assertIn("usage   -> ", r.stdout)
        self.assertIn("statusLine", r.stdout)  # says how to wire it in; changes no setting
        self.assertFalse(os.path.exists(self.p(".claude", "settings.json")))
        r = self.install(inv, "--uninstall")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(os.path.exists(helper))

    def test_not_installed_without_the_flag(self):
        inv = self.invite()
        r = self.install(inv, "--yes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(os.path.exists(self.p(".local", "bin", "needs-you-usage")))


class Update(test_mcp_install.CliCase):
    def env(self, h):
        return {"NEEDS_YOU_URLS": h.url, "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_GH": "none", "NEEDS_YOU_TIMEOUT": "2"}

    def test_update_refreshes_an_installed_copy(self):
        files = current_files()
        files["needs-you-usage"] = read(USAGE)
        h = FakeHub(files)
        self.addCleanup(h.stop)
        helper = os.path.join(self.bin, "needs-you-usage")
        with open(helper, "wb") as fh:
            fh.write(read(USAGE).replace(b"needs-you-version: ", b"needs-you-version: 0.0.1 was ", 1))
        os.chmod(helper, 0o755)
        r = self.run_cli("--json", "update", "--check", **self.env(h))
        self.assertIn("needs-you-usage", [c["file"] for c in json.loads(r.stdout)["changes"]])
        r = self.run_cli("update", **self.env(h))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(read(helper), read(USAGE))
        self.assertEqual(os.stat(helper).st_mode & 0o777, 0o755)

    def test_update_never_adds_it(self):
        files = current_files()
        files["needs-you-usage"] = read(USAGE)
        h = FakeHub(files)
        self.addCleanup(h.stop)
        r = self.run_cli("update", **self.env(h))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.bin, "needs-you-usage")))

