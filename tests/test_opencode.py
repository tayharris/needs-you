"""opencode integration (integrations/opencode/): the plugin, the shared hook in `opencode`
mode, the installer, doctor, the invite installer flag and update.

The plugin test needs `node` (opencode runs plugins under Bun; the plugin only uses
node:child_process, node:fs, node:path and node:url) and is skipped without it.
Everything runs with a temporary HOME, so the real ~/.config/opencode is never touched.
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

from support import CLI, ROOT, free_port, wait_until
from test_cli_update import UpdateCase, current_files, read

BASH = shutil.which("bash") or "/bin/bash"
NODE = shutil.which("node")
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
PLUGIN = os.path.join(ROOT, "integrations", "opencode", "needs-you.js")
INSTALLER = os.path.join(ROOT, "integrations", "opencode", "install-opencode-plugin.sh")
SECRET = "sk-test-SECRET-0123456789"

FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
"""


def opt(argv, name):
    for i, a in enumerate(argv):
        if a.startswith(name + "="):
            return a[len(name) + 1:]
        if a == name:
            return argv[i + 1]
    raise ValueError(name)


class Base(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-opencode-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.cli = os.path.join(self.home, "fake-needs-you")
        with open(self.cli, "w") as fh:
            fh.write(FAKE_CLI)
        os.chmod(self.cli, 0o755)
        self.log = os.path.join(self.home, "calls.log")
        self.cwd = os.path.join(self.home, "src", "my-repo")
        os.makedirs(self.cwd)
        self.oc = os.path.join(self.home, ".config", "opencode")

    def env(self, **extra):
        e = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home, "NEEDS_YOU_BIN": self.cli,
             "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_HOOK_PLATFORM": "linux"}
        e.update(extra)
        return e

    def calls(self):
        try:
            with open(self.log) as fh:
                return [json.loads(l) for l in fh]
        except OSError:
            return []

    def install(self):
        r = subprocess.run([BASH, INSTALLER], env={"HOME": self.home, "PATH": os.environ.get("PATH", "")},
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r


class HookMode(Base):
    def run_hook(self, mode, data, **extra):
        payload = {"session_id": "ses_abc123", "cwd": self.cwd}
        payload.update(data)
        r = subprocess.run([BASH, HOOK, mode, "opencode"], input=json.dumps(payload), env=self.env(**extra),
                           capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        return self.calls()

    def title(self, perm, patterns):
        return opt(self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": perm,
                                            "patterns": patterns})[-1], "--title")

    def test_cards(self):
        self.assertEqual(self.title("bash", ["API_KEY=%s npm publish" % SECRET]), "opencode wants to run npm: my-repo")
        self.assertEqual(self.title("edit", ["src/app/main.ts"]), "opencode wants to edit main.ts: my-repo")
        self.assertEqual(self.title("webfetch", ["https://x/%s" % SECRET]), "opencode wants to fetch a page: my-repo")
        self.assertEqual(self.title("external_directory", ["/etc/*"]),
                         "opencode wants to use a folder outside the project: my-repo")
        self.assertEqual(self.title("github_create_pr", []), "opencode needs permission for github_create_pr: my-repo")
        argv = self.run_hook("notify", {"hook_event_name": "Question"})[-1]
        self.assertEqual(opt(argv, "--title"), "opencode asked you a question: my-repo")
        argv = self.run_hook("notify", {"hook_event_name": "Stop"})[-1]
        self.assertEqual(opt(argv, "--title"), "opencode is waiting for you: my-repo")
        self.assertEqual(opt(argv, "--agent"), "opencode")
        self.assertNotIn(SECRET, json.dumps(self.calls()))
        n = len(self.calls())
        self.run_hook("notify", {"hook_event_name": "Stop"}, NEEDS_YOU_AGENT_TURN_CARDS="0")
        self.assertEqual(len(self.calls()), n)


@unittest.skipIf(NODE is None, "node isn't installed")
class Plugin(Base):
    DRIVER = r"""
import { pathToFileURL } from "node:url"
const mod = await import(pathToFileURL(process.argv[2]).href)
const names = Object.keys(mod)
if (names.length !== 1 || typeof mod[names[0]] !== "function") throw new Error("exports: " + names)
const hooks = await mod[names[0]]({ directory: process.argv[3], worktree: process.argv[3] })
const events = JSON.parse(process.argv[4])
const t0 = Date.now()
for (const e of events) await hooks.event({ event: e })
await hooks.event({ event: null })              // junk never throws
await hooks.event({ event: { type: "permission.asked" } })
console.log(JSON.stringify({ ms: Date.now() - t0 }))
"""

    def drive(self, events):
        driver = os.path.join(self.home, "driver.mjs")
        with open(driver, "w") as fh:
            fh.write(self.DRIVER)
        plugin = os.path.join(self.oc, "plugins", "needs-you.js")
        # opencode loads plugins with Bun, which takes ES modules as they are; plain Node
        # needs to be told (some versions fail, newer ones only warn on stderr).
        with open(os.path.join(self.oc, "plugins", "package.json"), "w") as fh:
            fh.write('{"type": "module"}\n')
        r = subprocess.run([NODE, driver, plugin, self.cwd, json.dumps(events)], env=self.env(),
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLess(json.loads(r.stdout)["ms"], 1000)  # never waits for the hook
        return r

    def test_events_post_and_resolve(self):
        self.install()
        sid = "ses_0123abc"
        self.drive([
            {"type": "session.status", "properties": {"sessionID": sid, "status": {"type": "busy"}}},
            {"type": "permission.asked", "properties": {"id": "per_1", "sessionID": sid, "permission": "bash",
                                                         "patterns": ["git push --force %s" % SECRET],
                                                         "metadata": {"secret": SECRET}, "always": []}},
        ])
        self.assertTrue(wait_until(lambda: len(self.calls()) >= 1, timeout=10))
        time.sleep(0.3)
        calls = self.calls()
        self.assertEqual(len(calls), 1)  # the busy event before any card cost nothing
        self.assertEqual(opt(calls[0], "--title"), "opencode wants to run git: my-repo")
        self.assertTrue(opt(calls[0], "--key").endswith(":ses_0123abc"))
        self.assertNotIn(SECRET, json.dumps(calls))

    def test_idle_twice_posts_once_and_reply_resolves(self):
        self.install()
        sid = "ses_idle1"
        state = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks", sid)
        self.drive([
            {"type": "session.status", "properties": {"sessionID": sid, "status": {"type": "idle"}}},
            {"type": "session.idle", "properties": {"sessionID": sid}},
        ])
        self.assertTrue(wait_until(lambda: os.path.exists(state), timeout=10))
        time.sleep(0.3)
        self.assertEqual([c[0] for c in self.calls()], ["add"])
        # A new plugin instance doesn't know the card, but a fresh one posts and resolves.
        self.drive([
            {"type": "question.asked", "properties": {"id": "que_1", "sessionID": sid, "questions": []}},
            {"type": "question.replied", "properties": {"sessionID": sid, "requestID": "que_1", "answers": []}},
        ])
        self.assertTrue(wait_until(lambda: [c[0] for c in self.calls()][-1:] == ["resolve"], timeout=10),
                        self.calls())

    def test_shell_env_names_the_session(self):
        # The agent's commands learn their session (for the CLI's one-card-for-one-wait note),
        # and a terminal without a session or a junk call gets nothing and never throws.
        driver = os.path.join(self.home, "env-driver.mjs")
        with open(driver, "w") as fh:
            fh.write(r"""
import { pathToFileURL } from "node:url"
const mod = await import(pathToFileURL(process.argv[2]).href)
const hooks = await mod[Object.keys(mod)[0]]({ directory: process.argv[3] })
const out = []
for (const input of [{ cwd: "/x", sessionID: "ses_0123abc" }, { cwd: "/x" }, { cwd: "/x", sessionID: 5 }]) {
  const o = { env: {} }
  await hooks["shell.env"](input, o)
  out.push(o.env)
}
await hooks["shell.env"](null, null)
console.log(JSON.stringify(out))
""")
        self.install()
        with open(os.path.join(self.oc, "plugins", "package.json"), "w") as fh:
            fh.write('{"type": "module"}\n')
        r = subprocess.run([NODE, driver, os.path.join(self.oc, "plugins", "needs-you.js"), self.cwd],
                           env=self.env(), capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), [{"NEEDS_YOU_AGENT_SESSION": "ses_0123abc"}, {}, {}])

    def test_missing_hook_is_harmless(self):
        os.makedirs(os.path.join(self.oc, "plugins"))
        shutil.copy(PLUGIN, os.path.join(self.oc, "plugins", "needs-you.js"))
        self.drive([{"type": "session.idle", "properties": {"sessionID": "ses_x"}}])
        time.sleep(0.3)
        self.assertEqual(self.calls(), [])


class Installer(Base):
    def test_install_uninstall_and_symlink(self):
        hooks = os.path.join(self.oc, "hooks")
        os.makedirs(hooks)
        victim = os.path.join(self.home, "victim.sh")
        with open(victim, "w") as fh:
            fh.write("keep\n")
        os.symlink(victim, os.path.join(hooks, "needs-you-hook.sh"))
        r = self.install()
        self.assertIn("Restart opencode", r.stdout)
        self.assertEqual(read(os.path.join(self.oc, "plugins", "needs-you.js")), read(PLUGIN))
        hook = os.path.join(hooks, "needs-you-hook.sh")
        self.assertFalse(os.path.islink(hook))  # replaced, not written through
        self.assertTrue(os.access(hook, os.X_OK))
        with open(victim) as fh:
            self.assertEqual(fh.read(), "keep\n")
        self.assertIn("already up to date", self.install().stdout)
        r = subprocess.run([BASH, INSTALLER, "--uninstall"], env={"HOME": self.home, "PATH": os.environ["PATH"]},
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.oc, "plugins", "needs-you.js")))
        self.assertFalse(os.path.exists(hook))


class Doctor(Base):
    def check(self, **env):
        e = {"HOME": self.home, "PATH": "/usr/bin:/bin", "NEEDS_YOU_URLS": "http://127.0.0.1:%d" % free_port(),
             "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_TIMEOUT": "1", "NEEDS_YOU_GH": "none"}
        e.update(env)
        r = subprocess.run([sys.executable, CLI, "doctor", "--json"], env=e, capture_output=True, text=True, timeout=60)
        rows = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "opencode plugin"]
        return rows[0] if rows else None

    def test_states(self):
        self.assertIsNone(self.check())
        os.makedirs(self.oc)
        self.assertEqual(self.check()["status"], "INFO")
        self.install()
        row = self.check(NEEDS_YOU_AGENT_ALERTS="1")
        self.assertEqual(row["status"], "OK", row)
        os.remove(os.path.join(self.oc, "hooks", "needs-you-hook.sh"))
        self.assertEqual(self.check()["status"], "WARN")


class Update(UpdateCase):
    def test_plugin_and_hook_copy(self):
        files = current_files()
        files["install-opencode-plugin.sh"] = read(INSTALLER)
        files["needs-you-opencode.js"] = read(PLUGIN)
        h = self.hub(files=files)
        plugin = self.install(".config/opencode/plugins/needs-you.js", b"// needs-you-version: 0.0.1\n")
        hook = self.install(".config/opencode/hooks/needs-you-hook.sh", mode=0o755)
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(read(plugin), read(PLUGIN))
        self.assertEqual(read(hook), read(HOOK))
        self.assertIn("needs-you-hook.sh (opencode)", r.stdout)


if __name__ == "__main__":
    unittest.main()
