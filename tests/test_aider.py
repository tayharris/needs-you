"""Aider integration (integrations/aider/): the shared hook in `aider` mode.

Aider runs its --notifications-command once each time it waits for the person after an LLM
reply (the next prompt or a yes/no question), through `sh -c`, with no arguments, no payload,
and the terminal as stdin (checked live with aider 0.86.2: a command that reads stdin eats
what the person types). It waits for the command to exit. So in this mode the hook never
reads stdin, returns at once, and names the session after the Aider process.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from hook_case import BASH, HOOK, REAL_HOME, HookCase, opt
from support import CLI, ROOT, free_port
from test_cli_update import UpdateCase, current_files, read


class AiderHook(HookCase):
    AGENT = "aider"

    def run_like_aider(self, *args, **extra):
        """`sh -c '<hook> notify aider'`, with a stdin pipe that is never closed: a hook that
        read it would hang (and in Aider, swallow the person's typing)."""
        started = time.time()
        rfd, wfd = os.pipe()
        try:
            p = subprocess.Popen(["sh", "-c", '"%s" "%s" notify aider' % (BASH, HOOK)] + list(args),
                                 stdin=rfd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env=self.env(**extra), cwd=self.cwd)
            os.close(rfd)
            try:
                out, err = p.communicate(timeout=3)
            finally:
                if p.poll() is None:
                    p.kill()
                    p.communicate()
        finally:
            os.close(wfd)
        self.assertEqual((p.returncode, out, err), (0, b"", b""))
        self.assertLess(time.time() - started, 2)

    def test_waiting_card(self):
        self.run_like_aider()
        argv = self.wait_calls(1)[-1]
        sid = "aider-%d" % os.getpid()
        self.assertEqual(opt(argv, "--title"), "Aider finished: my-repo")
        self.assertEqual(opt(argv, "--agent"), "aider")
        self.assertEqual(opt(argv, "--project"), "my-repo")
        self.assertEqual(opt(argv, "--key").split(":")[-1], sid)
        # No event tells us the person answered: a short expiry, and the lease on Aider's pid.
        self.assertEqual(opt(argv, "--expires-in"), "1")
        self.assertIn("Aider process `%d`" % os.getpid(), opt(argv, "--body"))
        self.wait_marker(sid)
        self.assertEqual(self.read_marker(sid)["pid"], str(os.getpid()))
        # The next wait updates the same card.
        self.run_like_aider()
        self.assertEqual(opt(self.wait_calls(2)[-1], "--key"), opt(argv, "--key"))

    def test_expiry_setting(self):
        self.run_like_aider(NEEDS_YOU_AIDER_EXPIRY_HOURS="0.25")
        self.assertEqual(opt(self.wait_calls(1)[-1], "--expires-in"), "0.25")

    def test_quiet_cases(self):
        self.run_like_aider(NEEDS_YOU_AGENT_ALERTS="")
        self.run_like_aider(NEEDS_YOU_AGENT_TURN_CARDS="0")
        self.run_like_aider(NY_HOOK_PPID=self.gone_pid())
        time.sleep(0.8)
        self.assertEqual(self.calls(), [])


INSTALLER = os.path.join(ROOT, "integrations", "aider", "install-aider-notifications.sh")
BLOCK = ("# needs-you (managed by install-aider-notifications.sh; do not edit between these markers)\n"
         "notifications: true\n"
         "notifications-command: '\"$HOME/.config/needs-you/aider/hooks/needs-you-hook.sh\" notify aider'\n"
         "# end needs-you\n")
NO_EOL = "# (the file had no newline at its end)"


class Installer(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-aider-inst-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.assertNotEqual(self.home, REAL_HOME)
        self.conf = os.path.join(self.home, ".aider.conf.yml")
        self.hook = os.path.join(self.home, ".config", "needs-you", "aider", "hooks", "needs-you-hook.sh")

    def run_installer(self, *args):
        return subprocess.run([BASH, INSTALLER] + list(args), env={"HOME": self.home, "PATH": os.environ["PATH"]},
                              capture_output=True, text=True, timeout=60)

    def conf_text(self):
        with open(self.conf) as fh:
            return fh.read()

    def test_new_file_rerun_uninstall(self):
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.conf_text(), BLOCK)
        self.assertEqual(read(self.hook), read(HOOK))
        self.assertTrue(os.access(self.hook, os.X_OK))
        self.assertIn("already up to date", self.run_installer().stdout)
        self.assertEqual(self.conf_text(), BLOCK)
        r = self.run_installer("--uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(self.conf))
        self.assertFalse(os.path.exists(self.hook))

    def test_existing_settings_are_kept(self):
        mine = "# my settings\nmodel: gpt-4o\nauto-commits: false"  # no final newline
        with open(self.conf, "w") as fh:
            fh.write(mine)
        flagged = BLOCK.replace("\n", "\n" + NO_EOL + "\n", 1)
        for uninstall in ([BASH, INSTALLER, "--uninstall"], [sys.executable, CLI, "uninstall-hooks", "--aider"]):
            with self.subTest(uninstall[1]):
                with open(self.conf, "w") as fh:
                    fh.write(mine)
                r = self.run_installer()
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self.conf_text(), mine + "\n" + flagged)
                self.assertIn("already up to date", self.run_installer().stdout)
                self.assertEqual(self.conf_text(), mine + "\n" + flagged)
                r = subprocess.run(uninstall, env={"HOME": self.home, "PATH": os.environ["PATH"]},
                                   capture_output=True, text=True, timeout=60, cwd=self.home)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertEqual(self.conf_text(), mine)  # no newline added for good
        # something added after the block: its line break stays
        self.run_installer()
        with open(self.conf, "a") as fh:
            fh.write("dark-mode: true\n")
        self.run_installer("--uninstall")
        self.assertEqual(self.conf_text(), mine + "\ndark-mode: true\n")

    def test_an_empty_config_keeps_its_mode(self):
        open(self.conf, "w").close()
        os.chmod(self.conf, 0o600)
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.stat(self.conf).st_mode & 0o777, 0o600)

    def test_crlf_file_comes_back_byte_for_byte(self):
        mine = b"model: gpt-4o\r\nread: [CONVENTIONS.md]\r\n"
        for uninstall in ([BASH, INSTALLER, "--uninstall"], [sys.executable, CLI, "uninstall-hooks", "--aider"]):
            with self.subTest(uninstall[1]):
                with open(self.conf, "wb") as fh:
                    fh.write(mine)
                r = self.run_installer()
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("notifications-command", self.conf_text())
                r = subprocess.run(uninstall, env={"HOME": self.home, "PATH": os.environ["PATH"]},
                                   capture_output=True, text=True, timeout=60, cwd=self.home)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                with open(self.conf, "rb") as fh:
                    self.assertEqual(fh.read(), mine)
                baks = []
                for n in os.listdir(self.home):
                    if n.startswith(".aider.conf.yml.bak-"):
                        with open(os.path.join(self.home, n), "rb") as fh:
                            baks.append(fh.read())
                        os.remove(os.path.join(self.home, n))
                self.assertIn(mine, baks)

    def test_not_safe_to_change(self):
        for mine in ("notifications: false\n", "notifications-command: say hi\n", "- a list\n",
                     "{model: x}\n", "model: x\n---\nother: y\n"):
            with open(self.conf, "w") as fh:
                fh.write(mine)
            r = self.run_installer()
            self.assertEqual(r.returncode, 4, mine)
            self.assertIn("Add these two lines to it yourself", r.stdout)
            self.assertIn("notify aider'", r.stdout)
            self.assertEqual(self.conf_text(), mine)
            self.assertTrue(os.path.exists(self.hook))  # the hook is there for the lines printed
        os.remove(self.conf)
        target = os.path.join(self.home, "dotfiles.yml")
        with open(target, "w") as fh:
            fh.write("model: x\n")
        os.symlink(target, self.conf)
        r = self.run_installer()
        self.assertEqual(r.returncode, 4)
        self.assertIn("symlink", r.stdout)
        with open(target) as fh:
            self.assertEqual(fh.read(), "model: x\n")

    def test_aider_reads_the_block(self):
        # The YAML Aider reads (it uses PyYAML; parse the block the same way when available).
        self.run_installer()
        try:
            import yaml  # noqa: F401 (not stdlib; only where it happens to be installed)
        except ImportError:
            self.skipTest("PyYAML not installed")
        import yaml
        doc = yaml.safe_load(self.conf_text())
        self.assertEqual(doc, {"notifications": True,
                               "notifications-command": '"$HOME/.config/needs-you/aider/hooks/needs-you-hook.sh"'
                                                        ' notify aider'})


class Doctor(unittest.TestCase):
    def test_states(self):
        home = tempfile.mkdtemp(prefix="ny-aider-doc-")
        self.addCleanup(shutil.rmtree, home, True)

        def check(**env):
            e = {"HOME": home, "PATH": "/usr/bin:/bin", "NEEDS_YOU_URLS": "http://127.0.0.1:%d" % free_port(),
                 "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_TIMEOUT": "1", "NEEDS_YOU_GH": "none"}
            e.update(env)
            r = subprocess.run([sys.executable, CLI, "doctor", "--json"], env=e, capture_output=True, text=True,
                               timeout=60)
            rows = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "aider notifications"]
            return rows[0] if rows else None

        self.assertIsNone(check())
        with open(os.path.join(home, ".aider.conf.yml"), "w") as fh:
            fh.write("model: x\n")
        self.assertEqual(check()["status"], "INFO")
        subprocess.run([BASH, INSTALLER], env={"HOME": home, "PATH": os.environ["PATH"]}, capture_output=True,
                       timeout=60)
        row = check(NEEDS_YOU_AGENT_ALERTS="1")
        self.assertEqual(row["status"], "OK", row)
        self.assertIn("NEEDS_YOU_AIDER_EXPIRY_HOURS", row["hint"])
        with open(os.path.join(home, ".aider.conf.yml"), "w") as fh:
            fh.write("model: x\n")
        row = check()
        self.assertEqual(row["status"], "WARN")
        self.assertIn("--aider", row["hint"])


class UninstallHooks(unittest.TestCase):
    def test_offline_removal(self):
        home = tempfile.mkdtemp(prefix="ny-aider-un-")
        self.addCleanup(shutil.rmtree, home, True)
        env = {"HOME": home, "PATH": os.environ["PATH"]}
        conf = os.path.join(home, ".aider.conf.yml")
        with open(conf, "w") as fh:
            fh.write("model: x\n")
        subprocess.run([BASH, INSTALLER], env=env, capture_output=True, timeout=60)
        r = subprocess.run([sys.executable, CLI, "uninstall-hooks", "--aider"], env=env, capture_output=True,
                           text=True, timeout=60, cwd=home)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("removed the needs-you lines", r.stdout)
        with open(conf) as fh:
            self.assertEqual(fh.read(), "model: x\n")
        self.assertFalse(os.path.exists(os.path.join(home, ".config", "needs-you", "aider")))


class Update(UpdateCase):
    def test_hook_copy(self):
        h = self.hub(files=dict(current_files(), **{"install-aider-notifications.sh": read(INSTALLER)}))
        hook = self.install(".config/needs-you/aider/hooks/needs-you-hook.sh", mode=0o755)
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("needs-you-hook.sh (Aider)", r.stdout)
        self.assertEqual(read(hook), read(HOOK))


if __name__ == "__main__":
    unittest.main()
