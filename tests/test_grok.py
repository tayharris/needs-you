"""Grok Build integration (integrations/grok/): the shared hook in `grok` mode, run from
needs-you's own hooks file in ~/.grok/hooks/, and how it coexists with the Claude Code hooks,
which Grok also runs (from ~/.claude/settings.json, on by default).

The payloads are the ones grok 1.0.46 sends (captured live with a temporary HOME and a stub
model server): camelCase keys plus Claude-style aliases (`hook_event_name` "Stop",
`session_id`), but a Notification has only `notificationType`. Grok sets GROK_HOOK_EVENT on
every hook, waits for its hooks, starts each through `sh -c` in a process group of its own and
kills that group on timeout, so the hook returns at once and finishes in a new session; the
tests wait for the fake CLI's log. Everything runs with a temporary HOME, so the real ~/.grok,
~/.claude and ~/.config are never touched.

One card per wait: with needs-you's own Grok hooks installed, the Claude hooks do nothing in
a Grok session; without them, the Claude hooks post as Grok (tests/test_hook_events.py).
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

from support import CLI, ROOT, HubTestCase, free_port, request, wait_until
from test_cli_update import UpdateCase, current_files, read

BASH = shutil.which("bash") or "/bin/bash"
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
GROK_HOOKS_JSON = os.path.join(ROOT, "integrations", "grok", "grok-hooks.json")
INSTALLER = os.path.join(ROOT, "integrations", "grok", "install-grok-hooks.sh")
REAL_HOME = os.path.expanduser("~")

FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
"""

SECRET = "sk-test-SECRET-0123456789"
SESSION = "01a11913-a9a9-7611-97a5-7a7221f8f995"
EVENTS = {"Notification": "notification", "Stop": "stop", "StopFailure": "stop_failure",
          "StopCancelled": "stop_cancelled", "UserPromptSubmit": "user_prompt_submit",
          "PostToolUse": "post_tool_use", "SessionStart": "session_start", "SessionEnd": "session_end"}


def opt(argv, name):
    for i, a in enumerate(argv):
        if a.startswith(name + "="):
            return a[len(name) + 1:]
        if a == name:
            return argv[i + 1]
    raise ValueError(name)


class GrokHook(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-grok-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.cli = os.path.join(self.home, "fake-needs-you")
        with open(self.cli, "w") as fh:
            fh.write(FAKE_CLI)
        os.chmod(self.cli, 0o755)
        self.log = os.path.join(self.home, "calls.log")
        self.state = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks")
        self.cwd = os.path.join(self.home, "src", "my-repo")
        os.makedirs(self.cwd)

    def run_hook(self, mode, event, data, agent="grok", **extra):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_BIN": self.cli, "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1",
               "NEEDS_YOU_HOOK_PLATFORM": "linux", "GROK_HOOK_EVENT": EVENTS[event],
               "GROK_HOOK_NAME": "x", "GROK_SESSION_ID": SESSION, "GROK_WORKSPACE_ROOT": self.cwd,
               "CLAUDE_PROJECT_DIR": self.cwd}
        env.update(extra)
        env = {k: v for k, v in env.items() if v is not None}
        payload = {"hookEventName": EVENTS[event], "sessionId": SESSION, "cwd": self.cwd,
                   "workspaceRoot": self.cwd, "timestamp": "2026-10-08T01:14:43.76+00:00",
                   "permissionMode": "default", "hook_event_name": event, "session_id": SESSION,
                   "permission_mode": "default"}
        payload.update(data)
        argv = [BASH, HOOK, mode] + ([agent] if agent else [])
        started = time.time()
        r = subprocess.run(argv, input=json.dumps(payload), env=env, capture_output=True, text=True, timeout=30)
        # Never exit 2 (it would block Stop or hand stderr to the model) and never print.
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.assertLess(time.time() - started, 5)
        return r

    def calls(self):
        try:
            with open(self.log) as fh:
                return [json.loads(l) for l in fh]
        except OSError:
            return []

    def wait_calls(self, n):
        self.assertTrue(wait_until(lambda: len(self.calls()) >= n, timeout=10), self.calls())
        time.sleep(0.1)
        return self.calls()

    def marker(self):
        path = os.path.join(self.state, SESSION)
        self.assertTrue(wait_until(lambda: os.path.exists(path), timeout=10))
        with open(path) as fh:
            return dict(l.rstrip("\n").split("=", 1) for l in fh)

    def idle(self, **extra):
        self.run_hook("notify", "Notification", {"notificationType": "idle_prompt",
                                                 "message": "Waiting for your next prompt", "level": "info"}, **extra)

    def own_install(self, home=None):
        d = os.path.join(home or os.path.join(self.home, ".grok"), "hooks")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "needs-you.json"), "w") as fh:
            fh.write("{}")

    def test_idle_and_permission_cards(self):
        self.idle()
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"), "Grok finished: my-repo")
        self.assertEqual(opt(argv, "--agent"), "grok")
        self.assertEqual(opt(argv, "--key").split(":")[-1], SESSION)
        self.run_hook("notify", "Notification", {"notificationType": "permission_prompt",
                                                 "message": "Run: curl -H 'Authorization: %s'" % SECRET})
        argv = self.wait_calls(2)[-1]
        self.assertEqual(opt(argv, "--title"), "Grok needs permission: my-repo")
        self.assertEqual(self.marker()["kind"], "permission")
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_idle_keeps_an_open_permission_card(self):
        self.run_hook("notify", "Notification", {"notificationType": "permission_prompt"})
        self.wait_calls(1)
        self.assertEqual(self.marker()["kind"], "permission")
        self.idle()
        time.sleep(0.8)
        self.assertEqual(len(self.calls()), 1)

    def test_no_card_on_stop_by_default_and_turn_cards_off(self):
        # The idle_prompt notification is the "waiting for you" card (a minute after the turn,
        # and none if the person types first): the turn's Stop posts nothing.
        self.run_hook("notify", "Stop", {"reason": "end_turn", "stopHookActive": False,
                                         "lastAssistantMessage": SECRET})
        self.idle(NEEDS_YOU_AGENT_TURN_CARDS="0")
        self.idle(NEEDS_YOU_AGENT_ALERTS=None)
        time.sleep(0.8)
        self.assertEqual(self.calls(), [])

    def test_failure_card(self):
        self.run_hook("notify", "StopFailure", {"error": "rate_limit", "errorDetails": SECRET})
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"), "Grok hit a rate limit: my-repo")
        self.assertEqual(self.marker()["kind"], "failure")
        self.run_hook("notify", "StopFailure", {"error": "something_new"})
        self.assertEqual(opt(self.wait_calls(2)[-1], "--title"), "Grok stopped on an error: my-repo")
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_prompt_tool_cancel_and_session_end_resolve(self):
        self.idle()
        key = opt(self.wait_calls(1)[-1], "--key")
        self.marker()
        self.run_hook("resolve", "UserPromptSubmit", {"prompt": SECRET, "promptId": "p1"})
        self.assertEqual(self.wait_calls(2)[-1], ["resolve", "--key", key])
        self.run_hook("notify", "Notification", {"notificationType": "permission_prompt"})
        self.wait_calls(3)
        self.marker()
        self.run_hook("resolve", "PostToolUse", {"toolName": "run_terminal_command", "toolResult": SECRET})
        self.assertEqual(self.wait_calls(4)[-1], ["resolve", "--key", key])
        self.run_hook("notify", "Notification", {"notificationType": "permission_prompt"})
        self.wait_calls(5)
        self.marker()
        self.run_hook("resolve", "StopCancelled", {"reason": "permission_declined", "cancelledBy": "user"})
        self.assertEqual(self.wait_calls(6)[-1], ["resolve", "--key", key])
        self.idle()
        self.wait_calls(7)
        self.marker()
        self.run_hook("end", "SessionEnd", {"reason": "shutdown"})
        self.assertEqual(self.wait_calls(8)[-1], ["resolve", "--key", key])
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_subagent_sessions_post_nothing(self):
        self.run_hook("notify", "Notification", {"notificationType": "permission_prompt",
                                                 "subagentType": "general"})
        self.run_hook("notify", "StopFailure", {"error": "rate_limit", "subagentType": "explore"})
        time.sleep(0.8)
        self.assertEqual(self.calls(), [])

    def test_one_card_per_wait_with_both_installs(self):
        # Grok runs the Claude hooks too. Without needs-you's own Grok hooks they post as
        # Grok (one card); with them, the Claude hooks step aside (still one card).
        self.idle(agent=None)
        self.assertEqual(opt(self.wait_calls(1)[-1], "--agent"), "grok")
        self.own_install()
        self.idle(agent=None)
        self.run_hook("notify", "Notification", {"notificationType": "permission_prompt"}, agent=None)
        self.run_hook("resolve", "UserPromptSubmit", {"prompt": "x"}, agent=None)
        self.run_hook("stop", "Stop", {"reason": "end_turn"}, agent=None)
        time.sleep(0.8)
        self.assertEqual(len(self.calls()), 1)
        self.idle()  # the Grok install itself
        self.assertEqual(opt(self.wait_calls(2)[-1], "--agent"), "grok")
        # GROK_HOME moves the Grok install, as it moves Grok's own hooks.
        other = os.path.join(self.home, "grok2")
        self.run_hook("resolve", "UserPromptSubmit", {"prompt": "x"}, agent=None, GROK_HOME=other)
        self.assertEqual(self.wait_calls(3)[-1][0], "resolve")
        # Claude Code itself (no GROK_HOOK_EVENT) is never affected.
        self.run_hook("notify", "Notification", {"notification_type": "idle_prompt"}, agent=None,
                      GROK_HOOK_EVENT=None)
        self.assertEqual(opt(self.wait_calls(4)[-1], "--agent"), "claude-code")


class GrokHooksJson(unittest.TestCase):
    def test_registers_the_events(self):
        with open(GROK_HOOKS_JSON) as fh:
            doc = json.load(fh)
        self.assertRegex(doc["_needs_you_version"], r"^\d+\.\d+\.\d+$")
        hooks = doc["hooks"]
        self.assertEqual({ev: g[0]["hooks"][0]["command"].split()[-2:] for ev, g in hooks.items()},
                         {"Notification": ["notify", "grok"], "StopFailure": ["notify", "grok"],
                          "UserPromptSubmit": ["resolve", "grok"], "PostToolUse": ["resolve", "grok"],
                          "PostToolUseFailure": ["resolve", "grok"], "StopCancelled": ["resolve", "grok"],
                          "SessionStart": ["start", "grok"], "SessionEnd": ["end", "grok"]})
        self.assertEqual(hooks["Notification"][0]["matcher"], "permission_prompt|idle_prompt")
        # The "waiting for you" card comes from idle_prompt, not Stop; and never a gate hook
        # (exit 2 from PreToolUse denies the tool).
        self.assertFalse({"Stop", "PreToolUse", "SubagentStop", "PermissionRequest"} & set(hooks))
        for groups in hooks.values():
            self.assertEqual(len(groups), 1)
            self.assertEqual(len(groups[0]["hooks"]), 1)
            h = groups[0]["hooks"][0]
            self.assertEqual(h["type"], "command")
            self.assertTrue(h["command"].startswith('"${GROK_HOME:-$HOME/.grok}/hooks/needs-you-hook.sh" '))
            self.assertLessEqual(h["timeout"], 10)


class Installer(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-grok-inst-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.assertNotEqual(self.home, REAL_HOME)
        self.grok = os.path.join(self.home, ".grok")
        self.conf = os.path.join(self.grok, "hooks", "needs-you.json")
        self.hook = os.path.join(self.grok, "hooks", "needs-you-hook.sh")

    def run_installer(self, *args, **env):
        e = {"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        e.update(env)
        return subprocess.run([BASH, INSTALLER] + list(args), env=e, capture_output=True, text=True, timeout=60)

    def test_install_rerun_and_uninstall(self):
        os.makedirs(os.path.join(self.grok, "hooks"))
        mine = os.path.join(self.grok, "hooks", "mine.json")
        with open(mine, "w") as fh:
            fh.write('{"hooks": {}}\n')
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Restart running Grok sessions", r.stdout)
        self.assertIn("grok inspect", r.stdout)
        self.assertEqual(read(self.conf), read(GROK_HOOKS_JSON))
        self.assertEqual(read(self.hook), read(HOOK))
        self.assertTrue(os.access(self.hook, os.X_OK))
        self.assertEqual(self.run_installer().stdout.count("already up to date"), 2)
        r = self.run_installer("--uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(self.conf))
        self.assertFalse(os.path.exists(self.hook))
        self.assertTrue(os.path.exists(mine))  # other hook files stay

    def test_grok_home_dry_run_and_managed_only_policy(self):
        other = os.path.join(self.home, "g2")
        os.makedirs(other)
        with open(os.path.join(other, "requirements.toml"), "w") as fh:
            fh.write("allow_managed_hooks_only = true\n")
        r = self.run_installer("--dry-run", GROK_HOME=other)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(os.path.join(other, "hooks")))
        r = self.run_installer(GROK_HOME=other)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(other, "hooks", "needs-you.json")))
        self.assertIn("allows only managed hooks", r.stdout)
        self.assertFalse(os.path.exists(self.grok))
        r = self.run_installer("--grok-home", os.path.join(self.home, "g3"))
        self.assertIn("only when it runs with GROK_HOME=", r.stdout)

    def test_symlinks_are_refused(self):
        os.makedirs(os.path.join(self.grok, "hooks"))
        victim = os.path.join(self.home, "victim.json")
        with open(victim, "w") as fh:
            fh.write("keep\n")
        os.symlink(victim, self.conf)
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("symlink", r.stderr)
        r = self.run_installer("--uninstall")
        self.assertNotEqual(r.returncode, 0)
        with open(victim) as fh:
            self.assertEqual(fh.read(), "keep\n")
        self.assertFalse(os.path.exists(self.hook))


class EndToEnd(HubTestCase):
    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.hub = self.make_hub("hub-a", peers=[])
        self.sender, self.reader = self.tokens(self.hub)
        r = subprocess.run([BASH, INSTALLER], env={"HOME": self.home, "PATH": os.environ.get("PATH", "")},
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.hook = os.path.join(self.home, ".grok", "hooks", "needs-you-hook.sh")

    def run_hook(self, mode, data, url, event):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_BIN": CLI,
               "NEEDS_YOU_URLS": url, "NEEDS_YOU_TOKEN": self.sender, "NEEDS_YOU_TIMEOUT": "2",
               "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_HOOK_PLATFORM": "linux", "GROK_HOOK_EVENT": event}
        payload = {"sessionId": "grok-e2e", "session_id": "grok-e2e", "cwd": "/srv/my-repo"}
        payload.update(data)
        r = subprocess.run([BASH, self.hook, mode, "grok"], input=json.dumps(payload), env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))

    def items(self):
        _, body = request("GET", self.hub.url + "/v1/items?status=all", self.reader)
        return [i for i in body["items"] if i["key"].endswith(":grok-e2e")]

    def test_post_then_resolve(self):
        self.run_hook("notify", {"hook_event_name": "Notification", "notificationType": "idle_prompt"},
                      self.hub.url, "notification")
        self.assertTrue(wait_until(lambda: len(self.items()) == 1, timeout=10))
        item = self.items()[0]
        self.assertEqual(item["title"], "Grok finished: my-repo")
        self.assertEqual(item["source"]["agent"], "grok")
        marker = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks", "grok-e2e")
        self.assertTrue(wait_until(lambda: os.path.exists(marker), timeout=10))
        self.run_hook("resolve", {"hook_event_name": "UserPromptSubmit", "prompt": "next"}, self.hub.url,
                      "user_prompt_submit")
        self.assertTrue(wait_until(lambda: self.items()[0]["status"] == "resolved", timeout=10), self.items())


class Doctor(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-grok-doc-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.grok = os.path.join(self.home, ".grok")

    def check(self, **env):
        e = {"HOME": self.home, "PATH": "/usr/bin:/bin", "NEEDS_YOU_URLS": "http://127.0.0.1:%d" % free_port(),
             "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_TIMEOUT": "1", "NEEDS_YOU_GH": "none"}
        e.update(env)
        r = subprocess.run([sys.executable, CLI, "doctor", "--json"], env=e, capture_output=True, text=True, timeout=60)
        rows = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "grok hooks"]
        return rows[0] if rows else None

    def install(self, **env):
        e = {"HOME": self.home, "PATH": os.environ.get("PATH", "")}
        e.update(env)
        r = subprocess.run([BASH, INSTALLER], env=e, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_states(self):
        self.assertIsNone(self.check())
        os.makedirs(self.grok)
        row = self.check()
        self.assertEqual(row["status"], "INFO")
        self.assertEqual(row["hint"], "to install: curl -fsSL <invite link>/install.sh | bash -s -- --yes "
                                      "--grok-hooks user --alerts")
        # Grok runs the Claude Code hooks: without its own install, say that's where cards come from.
        os.makedirs(os.path.join(self.home, ".claude"))
        with open(os.path.join(self.home, ".claude", "settings.json"), "w") as fh:
            json.dump({"hooks": {"Notification": [{"hooks": [{"command": "~/.claude/hooks/needs-you-hook.sh notify"}]}]}}, fh)
        row = self.check()
        self.assertEqual(row["status"], "INFO")
        self.assertIn("Claude Code hooks", row["detail"])
        self.install()
        row = self.check(NEEDS_YOU_AGENT_ALERTS="1")
        self.assertEqual(row["status"], "OK", row)
        self.assertIn("alerts on", row["detail"])
        self.assertIn("restart Grok", row["hint"])
        with open(os.path.join(self.grok, "requirements.toml"), "w") as fh:
            fh.write("allow_managed_hooks_only = true\n")
        row = self.check()
        self.assertEqual(row["status"], "WARN")
        self.assertIn("allow_managed_hooks_only", row["detail"])
        self.assertNotIn("re-run the installer", row["hint"])
        os.remove(os.path.join(self.grok, "requirements.toml"))
        with open(os.path.join(self.grok, "disabled-hooks"), "w") as fh:
            fh.write("global/needs-you.json:Notification:0\n")
        row = self.check()
        self.assertEqual(row["status"], "WARN")
        self.assertIn("disabled-hooks", row["detail"])
        os.remove(os.path.join(self.grok, "disabled-hooks"))
        for raw in (b"\xff\xfe", b"[1]", b'{"hooks": 1}'):
            with open(os.path.join(self.grok, "hooks", "needs-you.json"), "wb") as fh:
                fh.write(raw)
            row = self.check()
            self.assertEqual(row["status"], "WARN", raw)
            self.assertTrue(row["hint"].startswith("re-run the installer: "), row)
        os.remove(os.path.join(self.grok, "hooks", "needs-you.json"))
        os.remove(os.path.join(self.grok, "hooks", "needs-you-hook.sh"))
        self.assertEqual(self.check()["status"], "INFO")
        # GROK_HOME moves it, as it moves Grok's own hooks.
        other = os.path.join(self.home, "g2")
        self.install(GROK_HOME=other)
        self.assertEqual(self.check(GROK_HOME=other)["status"], "OK")


class UninstallHooks(unittest.TestCase):
    def test_offline_removal(self):
        home = tempfile.mkdtemp(prefix="ny-grok-un-")
        self.addCleanup(shutil.rmtree, home, True)
        env = {"HOME": home, "PATH": os.environ.get("PATH", "")}
        subprocess.run([BASH, INSTALLER], env=env, capture_output=True, timeout=60)
        hooks = os.path.join(home, ".grok", "hooks")
        with open(os.path.join(hooks, "mine.json"), "w") as fh:
            fh.write("{}")
        r = subprocess.run([sys.executable, CLI, "uninstall-hooks", "--grok", "--dry-run"], env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("would delete", r.stdout)
        self.assertTrue(os.path.exists(os.path.join(hooks, "needs-you.json")))
        r = subprocess.run([sys.executable, CLI, "uninstall-hooks"], env=env, capture_output=True, text=True,
                           timeout=60, cwd=home)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(sorted(os.listdir(hooks)), ["mine.json"])


class Update(UpdateCase):
    def test_hooks_file_and_hook_copy(self):
        files = current_files()
        files["install-grok-hooks.sh"] = read(INSTALLER)
        files["grok-hooks.json"] = read(GROK_HOOKS_JSON)
        h = self.hub(files=files)
        conf = self.install(".grok/hooks/needs-you.json", b'{"_needs_you_version": "0.0.1", "hooks": {}}\n')
        hook = self.install(".grok/hooks/needs-you-hook.sh", mode=0o755)
        r = self.run_cli("update", "--check", urls=[h.url])
        self.assertIn("needs-you-hook.sh (Grok)", r.stdout)
        self.assertIn("grok-hooks.json", r.stdout)
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(read(conf), read(GROK_HOOKS_JSON))
        self.assertEqual(read(hook), read(HOOK))
        with open(self.cli, "wb") as fh:
            fh.write(read(CLI))
        r = self.run_cli("--json", "update", "--check", urls=[h.url])
        self.assertEqual(json.loads(r.stdout)["changes"], [])

    def test_nothing_installed_nothing_written(self):
        h = self.hub()
        self.run_cli("update", urls=[h.url])
        self.assertFalse(os.path.exists(os.path.join(self.home, ".grok")))


if __name__ == "__main__":
    unittest.main()
