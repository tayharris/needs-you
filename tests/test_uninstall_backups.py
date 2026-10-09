"""Uninstall deletes the installer backups (<file>.bak-*) that hold only needs-you's part, so
a directory such as ~/.gemini can go once it's empty; a backup with anything of the person's
stays. `needs-you uninstall-hooks` and each installer's own --uninstall, in a temp HOME (no
crontab, no real agent config is touched)."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from support import CLI, ROOT, drop_python_cache

BASH = shutil.which("bash") or "/bin/bash"
BEGIN, END = "# needs-you-backups:begin", "# needs-you-backups:end"

# Each installer that backs up a config file it edits, that file under HOME, and a backup of
# the person's own (kept by every uninstall).
INSTALLERS = {
    "claude-code/install-hooks.sh": (".claude/settings.json", '{"model": "mine"}\n'),
    "codex/install-codex-hooks.sh": (".codex/hooks.json", '{"hooks": {"Stop": [{"hooks": [{"command": "mine"}]}]}}'),
    "gemini/install-gemini-hooks.sh": (".gemini/settings.json", '{"theme": "dark"}'),
    "cursor/install-cursor-hooks.sh": (".cursor/hooks.json", '{"version": 1, "hooks": {"stop": [{"command": "x"}]}}'),
    "kimi/install-kimi-hooks.sh": (".kimi-code/config.toml", 'default_model = "mine"\n'),
    "aider/install-aider-notifications.sh": (".aider.conf.yml", "dark-mode: true\n"),
}


def load_cli():
    loader = importlib.machinery.SourceFileLoader("needs_you_cli_backups", CLI)
    spec = importlib.util.spec_from_loader("needs_you_cli_backups", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def shared_block(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(r"^%s.*?^%s$" % (re.escape(BEGIN), re.escape(END)), text, re.S | re.M)
    return m.group(0) if m else None


class OnlyNeedsYou(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.f = staticmethod(load_cli().only_needs_you)

    def test_the_block_is_the_same_everywhere(self):
        want = shared_block(CLI)
        self.assertIsNotNone(want)
        for script in INSTALLERS:
            self.assertEqual(shared_block(os.path.join(ROOT, "integrations", script)), want, script)

    def test_only_needs_you(self):
        hook = {"type": "command", "command": '"$HOME/.gemini/hooks/needs-you-hook.sh" stop'}
        mcp = {"command": "/usr/bin/python3", "args": ["/home/u/.local/bin/needs-you-mcp"]}
        ours = [
            "", "\n", "{}", '{"version": 1}\n',
            json.dumps({"hooks": {"Stop": [{"hooks": [hook]}], "Notification": [{"matcher": "", "hooks": [hook]}]}}),
            json.dumps({"version": 1, "hooks": {"stop": [{"command": "~/.cursor/hooks/needs-you-hook.sh stop"}]}}),
            json.dumps({"hooks": {"Stop": [{"hooks": [hook]}]}, "mcpServers": {"needs-you": mcp}}),
            json.dumps({"mcp": {"needs-you": {"type": "local", "command": ["python3", "/x/needs-you-mcp"]}}}),
            "# needs-you (managed by install-kimi-hooks.sh; do not edit)\n[[hooks]]\nx = 1\n# end needs-you\n",
            "\n# needs-you (managed by install-aider-notifications.sh; do not edit between these markers)\n"
            "notifications: true\n# end needs-you\n",
            '# >>> needs-you MCP server (added)\n[mcp_servers.needs-you]\ncommand = "p"\n# <<< needs-you MCP server\n',
            "<!-- needs-you:begin (added) -->\nPost when blocked.\n<!-- needs-you:end -->\n",
        ]
        for text in ours:
            self.assertTrue(self.f(text), text)
        theirs = [
            '{"model": "mine"}', '{"hooks": {}, "env": {}}', "[]", "not json", "dark-mode: true\n",
            json.dumps({"hooks": {"Stop": [{"hooks": [hook, {"command": "mine"}]}]}}),
            json.dumps({"hooks": {"Stop": [{"hooks": []}]}}),
            json.dumps({"hooks": {"stop": [{"command": "mine"}]}}),
            json.dumps({"mcpServers": {"needs-you": {"command": "something-else"}}}),
            json.dumps({"mcpServers": {"needs-you": mcp, "theirs": {"command": "x"}}}),
            json.dumps({"version": 2}),
            "# needs-you (managed by install-kimi-hooks.sh)\n[[hooks]]\n",  # no end marker
            "a = 1\n# needs-you (managed by install-kimi-hooks.sh)\n[[hooks]]\n# end needs-you\n",
            "<!-- needs-you:begin -->\nx\n<!-- needs-you:end -->\nMy own notes.\n",
        ]
        for text in theirs:
            self.assertFalse(self.f(text), text)


class Uninstall(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="ny-unbak-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.env = {"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}

    def run_script(self, script, *flags):
        r = subprocess.run([BASH, os.path.join(ROOT, "integrations", script)] + list(flags), env=self.env,
                           capture_output=True, text=True, timeout=60, cwd=self.tmp)
        self.assertEqual(r.returncode, 0, script + r.stdout + r.stderr)
        return r

    def cli(self, *args):
        r = subprocess.run([sys.executable, CLI, "uninstall-hooks"] + list(args), env=self.env,
                           capture_output=True, text=True, timeout=60, cwd=self.tmp)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def write(self, path, text):
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)

    def install_with_backups(self):
        """Every installer on a machine without the agents' files, then the backups a later
        re-install (only needs-you's part) and a time with the person's own settings left."""
        made = {}
        for script, (rel, mine) in INSTALLERS.items():
            self.run_script(script)
            conf = os.path.join(self.home, rel)
            with open(conf, encoding="utf-8") as fh:
                installed = fh.read()
            ours = [conf + ".bak-20261001-120000", conf + ".bak-20261001-120000.1",
                    conf + ".bak-20261001-120001-4242"]
            self.write(ours[0], installed)
            self.write(ours[1], "")
            self.write(ours[2], "{}\n" if rel.endswith(".json") else "\n")
            theirs = conf + ".bak-20261001-120002"
            self.write(theirs, mine)
            made[script] = (conf, ours, theirs)
        return made

    def test_the_cli_deletes_only_needs_you_backups(self):
        made = self.install_with_backups()
        self.cli()
        for script, (conf, ours, theirs) in made.items():
            for b in ours:
                self.assertFalse(os.path.exists(b), b)
            self.assertTrue(os.path.exists(theirs), theirs)
            self.assertFalse(os.path.exists(conf), conf)  # an installer made it

    def test_each_installer_deletes_only_needs_you_backups(self):
        made = self.install_with_backups()
        for script, (conf, ours, theirs) in made.items():
            r = self.run_script(script, "--uninstall")
            for b in ours:
                self.assertFalse(os.path.exists(b), (script, b, r.stdout))
            self.assertTrue(os.path.exists(theirs), theirs)
            self.assertIn("backup", r.stdout)

    def test_a_dry_run_deletes_nothing(self):
        made = self.install_with_backups()
        r = subprocess.run([sys.executable, CLI, "uninstall-hooks", "--dry-run"], env=self.env,
                           capture_output=True, text=True, timeout=60, cwd=self.tmp)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("would delete", r.stdout)
        for script, (conf, ours, theirs) in made.items():
            self.run_script(script, "--uninstall", "--dry-run")
            for b in ours + [theirs, conf]:
                self.assertTrue(os.path.exists(b), b)

    def test_nothing_is_left_once_everything_was_needs_you(self):
        # The motivating case: a re-install left a backup holding only needs-you's hooks, so
        # ~/.gemini (and the others) stayed after an uninstall.
        self.install_with_backups()
        for script, (rel, _) in INSTALLERS.items():
            os.remove(os.path.join(self.home, rel) + ".bak-20261001-120002")
        self.cli()
        drop_python_cache(self.home)
        left = [os.path.relpath(os.path.join(dp, f), self.home) for dp, _, fns in os.walk(self.home)
                for f in fns if not dp.startswith(os.path.join(self.home, ".local", "state"))]
        self.assertEqual(left, [])
        for d in (".gemini", ".codex", ".cursor", ".kimi-code", ".claude"):
            self.assertFalse(os.path.exists(os.path.join(self.home, d)), d)

    def test_a_backup_that_isnt_a_plain_file_of_ours_stays(self):
        self.run_script("gemini/install-gemini-hooks.sh")
        conf = os.path.join(self.home, ".gemini", "settings.json")
        outside = os.path.join(self.tmp, "outside.json")
        self.write(outside, "{}")
        link = conf + ".bak-20261001-120000"
        os.symlink(outside, link)
        other_name = [conf + ".bak-mine", conf + ".bak-20261001", conf + "x.bak-20261001-120000",
                      os.path.join(self.home, ".gemini", "other.json.bak-20261001-120000")]
        for p in other_name:
            self.write(p, "{}")
        self.cli("--gemini")
        self.assertTrue(os.path.islink(link))
        self.assertTrue(os.path.exists(outside))
        for p in other_name:
            self.assertTrue(os.path.exists(p), p)

    def test_a_symlinked_claude_settings_tidies_next_to_its_target(self):
        # The person's own ~/.claude/settings.json may be a dotfile manager's symlink; the
        # installer writes (and backs up) through it.
        dots = os.path.join(self.tmp, "dots")
        os.makedirs(dots)
        os.makedirs(os.path.join(self.home, ".claude"))
        target = os.path.join(dots, "settings.json")
        self.write(target, '{"model": "mine"}')
        os.symlink(target, os.path.join(self.home, ".claude", "settings.json"))
        self.run_script("claude-code/install-hooks.sh", "--user")
        with open(target) as fh:
            hooks = json.load(fh)["hooks"]
        self.write(target + ".bak-20261001-120000", json.dumps({"hooks": hooks}))  # an earlier install's
        self.cli("--user")
        self.assertFalse(os.path.exists(target + ".bak-20261001-120000"))
        kept = [n for n in os.listdir(dots) if ".bak-" in n]
        self.assertEqual(len(kept), 2, kept)  # the install's and the uninstall's: both hold "mine"


if __name__ == "__main__":
    unittest.main()
