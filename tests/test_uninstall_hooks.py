"""`needs-you uninstall-hooks`: removes the Claude Code hooks with no hub, no config and no
download, at the user level and in project installs. Runs install-hooks.sh and the CLI with
a temporary HOME, so the real ~/.claude is never touched."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

from support import CLI, ROOT

BASH = shutil.which("bash") or "/bin/bash"
INSTALL_HOOKS = os.path.join(ROOT, "integrations", "claude-code", "install-hooks.sh")
OTHER = {"type": "command", "command": "echo mine"}


class UninstallHooks(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="ny-unhooks-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        self.proj = os.path.join(self.tmp, "proj")
        self.other = os.path.join(self.tmp, "other")
        for d in (self.home, os.path.join(self.proj, "src"), self.other):
            os.makedirs(d)
        self.env = {"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}

    def install(self, *flags):
        r = subprocess.run([BASH, INSTALL_HOOKS] + list(flags), env=self.env, capture_output=True,
                           text=True, timeout=60, cwd=self.tmp)
        self.assertEqual(r.returncode, 0, r.stderr)

    def cli(self, *args, cwd=None):
        # No NEEDS_YOU_URLS, no token, no env file: nothing but local files.
        return subprocess.run([sys.executable, CLI, "uninstall-hooks"] + list(args), env=self.env,
                              capture_output=True, text=True, timeout=60, cwd=cwd or self.tmp)

    def settings(self, *parts):
        with open(os.path.join(*parts)) as fh:
            return json.load(fh)

    def user_settings(self):
        return os.path.join(self.home, ".claude", "settings.json")

    def setup_all(self):
        os.makedirs(os.path.join(self.home, ".claude"))
        with open(self.user_settings(), "w") as fh:
            json.dump({"model": "keep", "hooks": {"Stop": [{"hooks": [OTHER]}]}}, fh)
        self.install("--user")
        self.install("--project", self.proj)
        self.install("--project", self.other, "--local")

    def has_hooks(self, path):
        with open(path) as fh:
            return "needs-you-hook.sh" in fh.read()

    def test_default_removes_everything_offline(self):
        self.setup_all()
        r = self.cli()
        self.assertEqual(r.returncode, 0, r.stderr)
        user = self.settings(self.user_settings())
        self.assertEqual(user, {"model": "keep", "hooks": {"Stop": [{"hooks": [OTHER]}]}})
        self.assertFalse(self.has_hooks(os.path.join(self.proj, ".claude", "settings.json")))
        self.assertFalse(self.has_hooks(os.path.join(self.other, ".claude", "settings.local.json")))
        for d in (self.home, self.proj, self.other):
            self.assertFalse(os.path.exists(os.path.join(d, ".claude", "hooks", "needs-you-hook.sh")), d)
        self.assertTrue([n for n in os.listdir(os.path.join(self.home, ".claude")) if ".bak-" in n])
        with open(os.path.join(self.home, ".local", "state", "needs-you", "claude-projects.json")) as fh:
            self.assertEqual(json.load(fh), {})
        self.assertIn("Restart open Claude Code sessions", r.stdout)
        r = self.cli()
        self.assertIn("no needs-you hooks found", r.stdout)

    def test_project_only_from_inside_it(self):
        self.setup_all()
        r = self.cli("--project", cwd=os.path.join(self.proj, "src"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.has_hooks(os.path.join(self.proj, ".claude", "settings.json")))
        self.assertTrue(self.has_hooks(self.user_settings()))
        self.assertTrue(self.has_hooks(os.path.join(self.other, ".claude", "settings.local.json")))
        self.assertTrue(os.path.exists(os.path.join(self.home, ".claude", "hooks", "needs-you-hook.sh")))
        r = self.cli("--user")
        self.assertFalse(self.has_hooks(self.user_settings()))
        self.assertTrue(self.has_hooks(os.path.join(self.other, ".claude", "settings.local.json")))

    def test_unrecorded_project_found_from_the_current_directory(self):
        self.install("--project", self.proj)
        os.remove(os.path.join(self.home, ".local", "state", "needs-you", "claude-projects.json"))
        r = self.cli()
        self.assertIn("no needs-you hooks found", r.stdout)  # run elsewhere: not found
        r = self.cli(cwd=os.path.join(self.proj, "src"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.has_hooks(os.path.join(self.proj, ".claude", "settings.json")))

    def test_hook_kept_while_another_settings_file_uses_it(self):
        self.install("--project", self.proj)
        self.install("--project", self.proj, "--local")
        local = os.path.join(self.proj, ".claude", "settings.local.json")
        with open(local, "w") as fh:  # hand-edited: no longer recorded, still a needs-you user
            json.dump({"hooks": {"Stop": [{"hooks": [{"type": "command",
                       "command": "\"$CLAUDE_PROJECT_DIR/.claude/hooks/needs-you-hook.sh\" stop"}]}]}}, fh)
        r = self.cli("--project", self.proj)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.has_hooks(local))
        self.assertFalse(os.path.exists(os.path.join(self.proj, ".claude", "hooks", "needs-you-hook.sh")))

    @staticmethod
    def text(path):
        with open(path) as fh:
            return fh.read()

    def test_dry_run_and_invalid_json(self):
        self.setup_all()
        before = self.text(self.user_settings())
        r = self.cli("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("would remove the needs-you hooks from ~/.claude/settings.json", r.stdout)
        self.assertEqual(self.text(self.user_settings()), before)
        self.assertTrue(os.path.exists(os.path.join(self.proj, ".claude", "hooks", "needs-you-hook.sh")))
        with open(self.user_settings(), "w") as fh:
            fh.write('{"hooks": "needs-you-hook.sh", broken')
        r = self.cli()
        self.assertEqual(r.returncode, 1)
        self.assertIn("nothing was changed", r.stderr)
        self.assertEqual(self.text(self.user_settings()), '{"hooks": "needs-you-hook.sh", broken')
        self.assertFalse(self.has_hooks(os.path.join(self.proj, ".claude", "settings.json")))  # the rest goes

    def test_project_symlinks_are_never_followed(self):
        # A cloned repo's .claude is untrusted: a symlinked settings file or hooks directory
        # must not let uninstall-hooks rewrite or delete anything outside it.
        outside = os.path.join(self.tmp, "outside")
        os.makedirs(outside)
        target = os.path.join(outside, "settings.json")
        content = json.dumps({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "needs-you-hook.sh"}]}]}})
        with open(target, "w") as fh:
            fh.write(content)
        victim = os.path.join(outside, "needs-you-hook.sh")
        with open(victim, "w") as fh:
            fh.write("not ours\n")
        claude = os.path.join(self.proj, ".claude")
        os.makedirs(claude)
        os.symlink(target, os.path.join(claude, "settings.json"))
        os.symlink(outside, os.path.join(claude, "hooks"))
        r = self.cli("--project", cwd=self.proj)
        self.assertEqual(r.returncode, 1)
        self.assertIn("symlink", r.stderr)
        self.assertEqual(self.text(target), content)
        self.assertTrue(os.path.exists(victim))
        self.assertEqual([n for n in os.listdir(outside) if ".bak-" in n], [])

    def test_bogus_recorded_paths_are_ignored(self):
        state = os.path.join(self.home, ".local", "state", "needs-you")
        os.makedirs(state)
        precious = os.path.join(self.tmp, "precious.json")
        content = '{"hooks": {"Stop": [{"hooks": [{"command": "needs-you-hook.sh"}]}]}}'
        with open(precious, "w") as fh:
            fh.write(content)
        with open(os.path.join(state, "claude-projects.json"), "w") as fh:
            json.dump({precious: {}, "relative/.claude/settings.json": {},
                       self.tmp + "/x/../precious.json": {}}, fh)
        r = self.cli()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.text(precious), content)


if __name__ == "__main__":
    unittest.main()
