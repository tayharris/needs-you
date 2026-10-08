"""scripts/setup-sender.sh, non-interactive, against a real hub: the env file, the hook
settings flags, the flush schedule and the PATH line, and that re-running changes nothing.

A temporary HOME and stub `crontab`, `launchctl` and `uname` first on PATH keep the real
~/.config, shell profile, crontab and launchd untouched.
"""
from __future__ import annotations

import os
import stat
import subprocess

from support import ROOT, HubTestCase
from test_install import BASH, STUB

SCRIPT = os.path.join(ROOT, "scripts", "setup-sender.sh")


class SetupSender(HubTestCase):
    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        self.stubs = os.path.join(self.tmp, "stubs")
        os.makedirs(self.home)
        os.makedirs(self.stubs)
        for name in ("crontab", "launchctl", "uname"):
            p = os.path.join(self.stubs, name)
            with open(p, "w") as fh:
                fh.write(STUB)
            os.chmod(p, 0o755)
        self.log = os.path.join(self.tmp, "stub.log")
        self.cron = os.path.join(self.tmp, "crontab")
        self.hub = self.make_hub("hub-a", peers=[])
        self.token, _ = self.tokens(self.hub)

    def run_setup(self, *flags, **extra):
        env = {"HOME": self.home, "PATH": self.stubs + ":/usr/bin:/bin:/usr/sbin:/sbin",
               "STUB_LOG": self.log, "STUB_CRON": self.cron, "STUB_UNAME": "Linux", "NO_PROXY": "*",
               "LANG": "C", "SHELL": "/bin/bash"}
        env.update(extra)
        r = subprocess.run([BASH, SCRIPT, "--non-interactive", "--url", self.hub.url, "--token-stdin",
                            "--install-cli", "--no-test"] + list(flags),
                           input=self.token + "\n", env=env, capture_output=True, text=True, timeout=120,
                           stdin=None)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn(self.token, r.stdout + r.stderr)
        return r

    def env_text(self):
        with open(os.path.join(self.home, ".config", "needs-you", "env")) as fh:
            return fh.read()

    def test_env_file_goes_where_the_cli_and_hooks_look(self):
        xdg = os.path.join(self.tmp, "xdg")
        self.run_setup("--alerts", "--no-schedule", "--no-path", XDG_CONFIG_HOME=xdg)
        with open(os.path.join(xdg, "needs-you", "env")) as fh:
            self.assertIn("NEEDS_YOU_AGENT_ALERTS=1\n", fh.read())
        self.assertFalse(os.path.exists(os.path.join(self.home, ".config", "needs-you", "env")))

    def test_schedule_passes_xdg_dirs_on(self):
        # cron runs without the shell's XDG_CONFIG_HOME: the flush found no config
        xdg = os.path.join(self.tmp, "xdg")
        self.run_setup("--no-path", XDG_CONFIG_HOME=xdg)
        cli = os.path.join(self.home, ".local", "bin", "needs-you")
        with open(self.cron) as fh:
            self.assertIn("*/5 * * * * XDG_CONFIG_HOME='%s' \"%s\" -q flush" % (xdg, cli), fh.read())

    def test_schedule_keeps_the_rest_of_the_crontab_as_it_was(self):
        mine = "MAILTO=me\n\n# backups\n0 3 * * * /usr/local/bin/backup\n\n# end\n"
        with open(self.cron, "w") as fh:
            fh.write(mine)
        self.run_setup("--no-path")
        with open(self.cron) as fh:
            cron = fh.read()
        self.assertTrue(cron.startswith(mine), cron)  # blank lines and all
        self.assertEqual(cron.count("needs-you-flush"), 1)

    def test_relative_bin_dir_is_made_absolute(self):
        # cron and the shell profile don't run from the directory setup-sender ran in
        cwd = os.path.join(self.tmp, "work")
        os.makedirs(cwd)
        cwd = os.path.realpath(cwd)  # what the shell's $PWD says (macOS: /private/var/...)
        env = {"HOME": self.home, "PATH": self.stubs + ":/usr/bin:/bin:/usr/sbin:/sbin", "STUB_LOG": self.log,
               "STUB_CRON": self.cron, "STUB_UNAME": "Linux", "NO_PROXY": "*", "LANG": "C", "SHELL": "/bin/bash"}
        r = subprocess.run([BASH, SCRIPT, "--non-interactive", "--url", self.hub.url, "--token-stdin",
                            "--install-cli", "--no-test", "--bin-dir", "relbin"], input=self.token + "\n",
                           env=env, capture_output=True, text=True, timeout=120, cwd=cwd)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        cli = os.path.join(cwd, "relbin", "needs-you")
        self.assertTrue(os.access(cli, os.X_OK))
        with open(self.cron) as fh:
            self.assertIn('"%s" -q flush' % cli, fh.read())
        with open(os.path.join(self.home, ".bashrc")) as fh:
            self.assertIn('export PATH="%s:$PATH"' % os.path.dirname(cli), fh.read())

    def test_settings_schedule_path_and_rerun(self):
        bashrc = os.path.join(self.home, ".bashrc")
        with open(bashrc, "w") as fh:
            fh.write("# my bashrc\n")
        self.run_setup("--alerts", "--context-alert", "75", "--ssh-alias", "devbox",
                       "--agent-link", "VS Code=vscode://file{cwd}", "--orca-environment", "My Devbox")
        env_path = os.path.join(self.home, ".config", "needs-you", "env")
        self.assertEqual(stat.S_IMODE(os.stat(env_path).st_mode), 0o600)
        text = self.env_text()
        for line in ("NEEDS_YOU_URLS=%s" % self.hub.url, "NEEDS_YOU_AGENT_ALERTS=1",
                     "NEEDS_YOU_CONTEXT_ALERT_PCT=75", "NEEDS_YOU_SSH_ALIAS=devbox",
                     "NEEDS_YOU_AGENT_LINK='VS Code=vscode://file{cwd}'",
                     "NEEDS_YOU_ORCA_ENVIRONMENT='My Devbox'"):
            self.assertIn(line + "\n", text)
        cli = os.path.join(self.home, ".local", "bin", "needs-you")
        with open(self.cron) as fh:
            cron = fh.read()
        self.assertIn('*/5 * * * * "%s" -q flush' % cli, cron)
        with open(bashrc) as fh:
            rc = fh.read()
        self.assertEqual(rc.count('export PATH="$HOME/.local/bin:$PATH"  # added by needs-you'), 1)

        # re-run with fewer flags: settings kept, nothing duplicated
        with open(env_path, "a") as fh:
            fh.write("NEEDS_YOU_AGENT_PRIORITY=low\n")
        r = self.run_setup("--context-alert", "90")
        text2 = self.env_text()
        self.assertIn("NEEDS_YOU_CONTEXT_ALERT_PCT=90\n", text2)
        self.assertEqual(text2.count("NEEDS_YOU_CONTEXT_ALERT_PCT="), 1)
        for keep in ("NEEDS_YOU_AGENT_ALERTS=1", "NEEDS_YOU_SSH_ALIAS=devbox", "NEEDS_YOU_AGENT_PRIORITY=low"):
            self.assertIn(keep + "\n", text2)
        self.assertEqual(text2.count("NEEDS_YOU_TOKEN="), 1)
        with open(self.cron) as fh:
            self.assertEqual(fh.read(), cron)
        with open(bashrc) as fh:
            self.assertEqual(fh.read(), rc)
        self.assertIn("crontab entry already present", r.stdout)
        self.assertIn("already adds", r.stdout)

    def test_macos_launch_agent_and_no_path(self):
        r = self.run_setup("--no-path", STUB_UNAME="Darwin", SHELL="/bin/zsh")
        plist = os.path.join(self.home, "Library", "LaunchAgents", "io.needs-you.flush.plist")
        with open(plist) as fh:
            self.assertIn("<integer>300</integer>", fh.read())
        self.assertFalse(os.path.exists(os.path.join(self.home, ".zshrc")))
        self.assertIn('export PATH="$HOME/.local/bin:$PATH"', r.stderr)
        r = self.run_setup("--no-path", STUB_UNAME="Darwin", SHELL="/bin/zsh")
        self.assertIn("already set up", r.stdout)

    def test_no_schedule_and_bad_values(self):
        self.run_setup("--no-schedule")
        self.assertFalse(os.path.exists(self.cron))
        env = {"HOME": self.home, "PATH": self.stubs + ":/usr/bin:/bin", "STUB_LOG": self.log,
               "STUB_CRON": self.cron, "LANG": "C"}
        for bad in (["--context-alert", "500"], ["--ssh-alias", "a;b"], ["--agent-link", "x"]):
            r = subprocess.run([BASH, SCRIPT, "--non-interactive"] + bad, env=env, capture_output=True,
                               text=True, timeout=60, stdin=subprocess.DEVNULL)
            self.assertEqual(r.returncode, 2, bad)


if __name__ == "__main__":
    import unittest
    unittest.main()
