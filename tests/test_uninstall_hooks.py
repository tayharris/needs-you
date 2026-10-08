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

    def test_project_install_in_home_is_the_user_level(self):
        # The invite one-liner run right after ssh-ing in: the "project" is $HOME, whose .claude
        # is the user level. Project commands ($CLAUDE_PROJECT_DIR/...) there broke every hook
        # in every other project.
        for args in (["--project"], ["--project", self.home], ["--project", ".", "--local"]):
            r = subprocess.run([BASH, INSTALL_HOOKS] + args, env=self.env, capture_output=True, text=True,
                               timeout=60, cwd=self.home)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("user level", r.stderr)
            text = json.dumps(self.settings(self.user_settings()))
            self.assertIn("$HOME/.claude/hooks/needs-you-hook.sh", text)
            self.assertNotIn("CLAUDE_PROJECT_DIR", text)
            self.assertFalse(os.path.exists(os.path.join(self.home, ".claude", "settings.local.json")))
            self.assertFalse(os.path.exists(os.path.join(self.home, ".local", "state", "needs-you",
                                                         "claude-projects.json")))

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
        self.assertIn("Restart open agent sessions", r.stdout)
        r = self.cli()
        self.assertIn("no needs-you hooks found", r.stdout)

    def test_an_enclosing_home_is_never_a_project(self):
        # A temp HOME made under a real home (a sandbox, a test): the real ~/.claude above it is
        # that account's user level, not a project, and neither uninstall nor doctor may touch it.
        self.install("--user")
        before = self.text(self.user_settings())
        inner = os.path.join(self.home, "tmp", "inner")
        os.makedirs(inner)
        env = dict(self.env, HOME=inner)
        for args in (["uninstall-hooks"], ["uninstall-hooks", "--project"], ["doctor"]):
            r = subprocess.run([sys.executable, CLI] + args, env=env, capture_output=True, text=True,
                               timeout=60, cwd=inner)
            self.assertNotIn(self.user_settings(), r.stdout + r.stderr, args)
            self.assertNotIn("project hooks", r.stdout.lower(), args)
        self.assertEqual(self.text(self.user_settings()), before)

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

    def install_agents(self):
        """Codex, Gemini CLI and opencode, by their own installers (in a temp HOME)."""
        for script in ("codex/install-codex-hooks.sh", "gemini/install-gemini-hooks.sh",
                       "opencode/install-opencode-plugin.sh"):
            r = subprocess.run([BASH, os.path.join(ROOT, "integrations", script)], env=self.env,
                               capture_output=True, text=True, timeout=60, cwd=self.tmp)
            self.assertEqual(r.returncode, 0, script + r.stderr)
        self.codex = os.path.join(self.home, ".codex")
        self.gemini = os.path.join(self.home, ".gemini")
        self.opencode = os.path.join(self.home, ".config", "opencode")
        with open(os.path.join(self.codex, "hooks.json")) as fh:  # another tool's hook stays
            doc = json.load(fh)
        doc["hooks"]["Stop"].append({"hooks": [OTHER]})
        with open(os.path.join(self.codex, "hooks.json"), "w") as fh:
            json.dump(doc, fh)

    def test_other_agents_removed_offline(self):
        self.install_agents()
        self.install("--user")
        r = self.cli("--codex", "--opencode")  # only those
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.settings(self.codex, "hooks.json"), {"hooks": {"Stop": [{"hooks": [OTHER]}]}})
        self.assertFalse(os.path.exists(os.path.join(self.codex, "hooks", "needs-you-hook.sh")))
        self.assertFalse(os.path.exists(os.path.join(self.opencode, "plugins", "needs-you.js")))
        self.assertFalse(os.path.exists(os.path.join(self.opencode, "hooks", "needs-you-hook.sh")))
        self.assertTrue(self.has_hooks(os.path.join(self.gemini, "settings.json")))
        self.assertTrue(self.has_hooks(self.user_settings()))
        r = self.cli()  # everything else
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.has_hooks(os.path.join(self.gemini, "settings.json")))
        self.assertFalse(os.path.exists(os.path.join(self.gemini, "hooks", "needs-you-hook.sh")))
        self.assertFalse(self.has_hooks(self.user_settings()))
        self.assertIn("no needs-you hooks found", self.cli().stdout)

    def test_other_agents_symlinks_are_never_followed(self):
        self.install_agents()
        outside = os.path.join(self.tmp, "outside")
        os.makedirs(outside)
        conf = os.path.join(self.gemini, "settings.json")
        target = os.path.join(outside, "settings.json")
        shutil.move(conf, target)
        os.symlink(target, conf)
        before = self.text(target)
        plugin_target = os.path.join(outside, "needs-you.js")
        plugin = os.path.join(self.opencode, "plugins", "needs-you.js")
        shutil.move(plugin, plugin_target)
        os.symlink(plugin_target, plugin)
        r = self.cli("--gemini", "--opencode")
        self.assertEqual(r.returncode, 1)
        self.assertIn("symlink", r.stderr)
        self.assertEqual(self.text(target), before)
        self.assertTrue(os.path.exists(plugin_target))
        self.assertTrue(os.path.exists(os.path.join(self.gemini, "hooks", "needs-you-hook.sh")))

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
