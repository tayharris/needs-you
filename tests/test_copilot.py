"""GitHub Copilot CLI integration (integrations/copilot/): the shared hook in `copilot` mode,
the hooks-file installer, a real-hub round trip, `needs-you doctor`, `uninstall-hooks` and
`needs-you update`.

The payloads are the ones Copilot CLI 1.0.93 sends to camelCase hooks (captured live):
`sessionId`, not `session_id`; a notification carries `notification_type` and `message`
("Run command: <the whole command line>"); agentStop carries `stopReason`. Copilot waits for
most hooks, so in this mode the hook returns at once and finishes in the background; the
tests wait for the fake CLI's log. Everything runs with a temporary HOME, so the real
~/.copilot, ~/.claude and ~/.config are never touched.
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

from hook_case import fixture, posted_item
from support import CLI, ROOT, HubTestCase, free_port, request, wait_until
from test_cli_update import UpdateCase, current_files, read

BASH = shutil.which("bash") or "/bin/bash"
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
COPILOT_HOOKS_JSON = os.path.join(ROOT, "integrations", "copilot", "copilot-hooks.json")
INSTALLER = os.path.join(ROOT, "integrations", "copilot", "install-copilot-hooks.sh")
REAL_HOME = os.path.expanduser("~")

FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
"""

SECRET = "sk-test-SECRET-0123456789"
SESSION = "2ab58c43-63b5-4efe-b9f7-2fd9e9c823b6"


def opt(argv, name):
    for i, a in enumerate(argv):
        if a.startswith(name + "="):
            return a[len(name) + 1:]
        if a == name:
            return argv[i + 1]
    raise ValueError(name)


class CopilotHook(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-copilot-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.cli = os.path.join(self.home, "fake-needs-you")
        with open(self.cli, "w") as fh:
            fh.write(FAKE_CLI)
        os.chmod(self.cli, 0o755)
        self.log = os.path.join(self.home, "calls.log")
        self.state = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks")
        self.cwd = os.path.join(self.home, "src", "my-repo")
        os.makedirs(self.cwd)

    def run_hook(self, mode, data, **extra):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_BIN": self.cli, "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1",
               "NEEDS_YOU_HOOK_PLATFORM": "linux", "COPILOT_CLI": "1",
               "COPILOT_PROJECT_DIR": self.cwd, "CLAUDE_PROJECT_DIR": self.cwd}  # Copilot sets both
        env.update(extra)
        payload = {"sessionId": SESSION, "timestamp": 1791416819847, "cwd": self.cwd}
        payload.update(data)
        started = time.time()
        r = subprocess.run([BASH, HOOK, mode, "copilot"], input=json.dumps(payload), env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        # Copilot parses stdout as the hook's JSON answer (a notification's additionalContext
        # would reach the model): it stays empty, and the hook doesn't hold Copilot up.
        self.assertEqual((r.stdout, r.stderr), ("", ""))
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

    def wait_marker(self, present=True):
        path = os.path.join(self.state, SESSION)
        self.assertTrue(wait_until(lambda: os.path.exists(path) == present, timeout=10))

    def notification(self, ntype, message, n):
        self.run_hook("notify", {"message": message, "title": "Permission needed",
                                 "hook_event_name": "Notification", "notification_type": ntype})
        return self.wait_calls(n)[-1]

    def test_permission_card_names_only_the_program(self):
        argv = self.notification("permission_prompt", "Run command: API_KEY=%s npm publish --tag x" % SECRET, 1)
        self.assertEqual(opt(argv, "--title"), "Copilot wants to run npm: my-repo")
        self.assertEqual(opt(argv, "--agent"), "copilot-cli")
        self.assertEqual(opt(argv, "--project"), "my-repo")
        self.assertEqual(opt(argv, "--key").split(":")[-1], SESSION)
        argv = self.notification("permission_prompt", "Fetch URL: https://example.com/x?token=%s" % SECRET, 2)
        self.assertEqual(opt(argv, "--title"), "Copilot wants to fetch a page: my-repo")
        argv = self.notification("permission_prompt", "Something new: %s" % SECRET, 3)
        self.assertEqual(opt(argv, "--title"), "Copilot needs your approval: my-repo")
        self.assertNotIn(SECRET, json.dumps(self.calls()))
        self.wait_marker(True)
        with open(os.path.join(self.state, SESSION)) as fh:
            m = dict(l.rstrip("\n").split("=", 1) for l in fh)
        self.assertEqual(m["kind"], "permission")
        # The lease names the process that ran the hook (Copilot; here this test), not init.
        self.assertEqual(m["pid"], str(os.getpid()))

    def test_question_and_turn_end(self):
        argv = self.notification("elicitation_dialog", "Which color? %s" % SECRET, 1)
        self.assertEqual(opt(argv, "--title"), "Copilot asks \u201cWhich color? [redacted]\u201d: my-repo")
        self.run_hook("notify", {"transcriptPath": "/x/events.jsonl", "stopReason": "end_turn",
                                 "stop_hook_active": False})
        argv = self.wait_calls(2)[-1]
        self.assertEqual(opt(argv, "--title"), "Copilot finished: my-repo")
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_elicitation_from_the_payload(self):
        # an MCP server's elicitation: the message is the question; there are no choices
        data = fixture("copilot-elicitation-dialog.json")
        data.update(sessionId=SESSION, cwd=self.cwd)
        self.run_hook("notify", data)
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"), "Copilot asks \u201cWhich Jira project should the issue go to?\u201d: my-repo")
        self.assertTrue(opt(argv, "--body").startswith("Which Jira project should the issue go to?\n\nAnswer in Copilot."))
        self.assertEqual(posted_item(argv)["steps"], [])
        # Copilot's fallback text names no question: the plain card
        self.notification("elicitation_dialog", "Information requested", 2)
        self.assertEqual(opt(self.calls()[-1], "--title"), "Copilot asked you a question: my-repo")
        self.notification("elicitation_dialog", "Which one?", 3)
        self.run_hook("notify", dict(data, message="Which one?"), NEEDS_YOU_AGENT_QUESTIONS="0")
        self.assertEqual(opt(self.wait_calls(4)[-1], "--title"), "Copilot asked you a question: my-repo")

    def test_turn_cards_can_be_turned_off_and_other_notifications_post_nothing(self):
        self.run_hook("notify", {"stopReason": "end_turn"}, NEEDS_YOU_AGENT_TURN_CARDS="0")
        for ntype in ("agent_idle", "agent_completed", "shell_completed"):
            self.run_hook("notify", {"message": "Background agent done", "hook_event_name": "Notification",
                                     "notification_type": ntype})
        self.run_hook("notify", {"stopReason": "end_turn"}, NEEDS_YOU_AGENT_ALERTS="")  # not opted in
        time.sleep(0.8)
        self.assertEqual(self.calls(), [])

    def test_no_turn_card_from_a_one_shot_run(self):
        # `copilot -p` ends its turn (agentStop), ends the session and exits at once: nobody is
        # waiting, so no card. The turn-end card waits a moment and checks Copilot is still there.
        gone = subprocess.Popen(["true"])
        gone.wait()
        self.run_hook("notify", {"stopReason": "end_turn"}, NY_HOOK_PPID=str(gone.pid))
        self.run_hook("end", {"reason": "complete"}, NY_HOOK_PPID=str(gone.pid))
        time.sleep(3.5)
        self.assertEqual(self.calls(), [])
        self.assertFalse(os.path.exists(os.path.join(self.state, SESSION)))

    def test_prompt_tool_and_session_end_resolve(self):
        self.run_hook("notify", {"stopReason": "end_turn"})
        key = opt(self.wait_calls(1)[-1], "--key")
        self.wait_marker(True)
        self.run_hook("resolve", {"prompt": SECRET})  # userPromptSubmitted
        self.assertEqual(self.wait_calls(2)[-1], ["resolve", "--key", key])
        self.wait_marker(False)
        self.run_hook("resolve", {"toolName": "bash", "toolArgs": {"command": "ls"},
                                  "toolResult": {"resultType": "success", "textResultForLlm": SECRET}})
        time.sleep(0.5)
        self.assertEqual(len(self.calls()), 2)  # nothing posted since: no network call
        self.notification("permission_prompt", "Run command: make", 3)
        self.wait_marker(True)
        self.run_hook("end", {"reason": "user_exit"})
        self.assertEqual(self.wait_calls(4)[-1], ["resolve", "--key", key])
        self.assertNotIn(SECRET, json.dumps(self.calls()))


class CopilotHooksJson(unittest.TestCase):
    def test_registers_the_events(self):
        with open(COPILOT_HOOKS_JSON) as fh:
            doc = json.load(fh)
        self.assertEqual(doc["version"], 1)
        self.assertRegex(doc["_needs_you_version"], r"^\d+\.\d+\.\d+$")
        hooks = doc["hooks"]
        self.assertEqual({ev: h[0]["bash"].split()[-2:] for ev, h in hooks.items()},
                         {"notification": ["notify", "copilot"], "agentStop": ["notify", "copilot"],
                          "userPromptSubmitted": ["resolve", "copilot"], "postToolUse": ["resolve", "copilot"],
                          "postToolUseFailure": ["resolve", "copilot"], "sessionEnd": ["end", "copilot"]})
        self.assertEqual(hooks["notification"][0]["matcher"], "permission_prompt|elicitation_dialog")
        for groups in hooks.values():
            self.assertEqual(len(groups), 1)
            h = groups[0]
            self.assertEqual(h["type"], "command")
            self.assertTrue(h["bash"].startswith('"${COPILOT_HOME:-$HOME/.copilot}/hooks/needs-you-hook.sh" '))
            self.assertLessEqual(h["timeoutSec"], 30)
        # Never a decision hook: a failing preToolUse or permissionRequest hook denies the tool.
        self.assertFalse({"preToolUse", "permissionRequest", "PreToolUse", "PermissionRequest"} & set(hooks))


class Installer(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-copilot-inst-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.assertNotEqual(self.home, REAL_HOME)
        self.copilot = os.path.join(self.home, ".copilot")
        self.conf = os.path.join(self.copilot, "hooks", "needs-you.json")
        self.hook = os.path.join(self.copilot, "hooks", "needs-you-hook.sh")

    def run_installer(self, *args, **env):
        e = {"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        e.update(env)
        return subprocess.run([BASH, INSTALLER] + list(args), env=e, capture_output=True, text=True, timeout=60)

    def test_install_rerun_and_uninstall(self):
        os.makedirs(os.path.join(self.copilot, "hooks"))
        mine = os.path.join(self.copilot, "hooks", "mine.json")
        with open(mine, "w") as fh:
            fh.write('{"version": 1, "hooks": {}}\n')
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Restart running Copilot CLI sessions", r.stdout)
        self.assertEqual(read(self.conf), read(COPILOT_HOOKS_JSON))
        self.assertEqual(read(self.hook), read(HOOK))
        self.assertTrue(os.access(self.hook, os.X_OK))
        self.assertEqual(r.stdout.count("already up to date"), 0)
        self.assertEqual(self.run_installer().stdout.count("already up to date"), 2)
        r = self.run_installer("--uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(self.conf))
        self.assertFalse(os.path.exists(self.hook))
        self.assertTrue(os.path.exists(mine))  # other hook files stay

    def test_copilot_home_dry_run_and_disabled_hooks(self):
        other = os.path.join(self.home, "cp2")
        os.makedirs(other)
        with open(os.path.join(other, "config.json"), "w") as fh:
            json.dump({"disableAllHooks": True}, fh)
        r = self.run_installer("--dry-run", COPILOT_HOME=other)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(os.path.join(other, "hooks")))
        r = self.run_installer(COPILOT_HOME=other)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(other, "hooks", "needs-you.json")))
        self.assertIn('"disableAllHooks": true', r.stdout)
        self.assertFalse(os.path.exists(self.copilot))
        r = self.run_installer("--copilot-home", os.path.join(self.home, "cp3"))
        self.assertIn("only when it runs with COPILOT_HOME=", r.stdout)

    def test_symlinks_are_refused(self):
        os.makedirs(os.path.join(self.copilot, "hooks"))
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
        self.hook = os.path.join(self.home, ".copilot", "hooks", "needs-you-hook.sh")

    def run_hook(self, mode, data, url):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_BIN": CLI,
               "NEEDS_YOU_URLS": url, "NEEDS_YOU_TOKEN": self.sender, "NEEDS_YOU_TIMEOUT": "2",
               "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_HOOK_PLATFORM": "linux"}
        payload = {"sessionId": "cp-e2e", "timestamp": 1791416819847, "cwd": "/srv/my-repo"}
        payload.update(data)
        r = subprocess.run([BASH, self.hook, mode, "copilot"], input=json.dumps(payload), env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))

    def items(self):
        _, body = request("GET", self.hub.url + "/v1/items?status=all", self.reader)
        return [i for i in body["items"] if i["key"].endswith(":cp-e2e")]

    def test_post_then_resolve(self):
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "permission_prompt",
                                 "message": "Run command: make --version", "title": "Permission needed"},
                      self.hub.url)
        self.assertTrue(wait_until(lambda: len(self.items()) == 1, timeout=10))
        item = self.items()[0]
        self.assertEqual(item["title"], "Copilot wants to run make: my-repo")
        self.assertEqual(item["source"]["agent"], "copilot-cli")
        self.assertNotIn("--version", json.dumps(item))
        marker = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks", "cp-e2e")
        self.assertTrue(wait_until(lambda: os.path.exists(marker), timeout=10))
        self.run_hook("resolve", {"toolName": "bash"}, self.hub.url)
        self.assertTrue(wait_until(lambda: self.items()[0]["status"] == "resolved", timeout=10), self.items())

    def test_hub_down_queues(self):
        self.run_hook("notify", {"stopReason": "end_turn"}, "http://127.0.0.1:%d" % free_port())
        outbox = os.path.join(self.home, ".local", "state", "needs-you", "outbox")
        self.assertTrue(wait_until(lambda: os.path.isdir(outbox) and
                                   any(n.endswith(".json") for n in os.listdir(outbox)), timeout=30))  # the hook posts after its turn wait, in the background


class Doctor(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-copilot-doc-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.copilot = os.path.join(self.home, ".copilot")

    def check(self, **env):
        e = {"HOME": self.home, "PATH": "/usr/bin:/bin", "NEEDS_YOU_URLS": "http://127.0.0.1:%d" % free_port(),
             "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_TIMEOUT": "1", "NEEDS_YOU_GH": "none"}
        e.update(env)
        r = subprocess.run([sys.executable, CLI, "doctor", "--json"], env=e, capture_output=True, text=True, timeout=60)
        rows = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "copilot hooks"]
        return rows[0] if rows else None

    def test_states(self):
        self.assertIsNone(self.check())
        os.makedirs(self.copilot)
        self.assertEqual(self.check()["status"], "INFO")
        r = subprocess.run([BASH, INSTALLER], env={"HOME": self.home, "PATH": os.environ.get("PATH", "")},
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        row = self.check(NEEDS_YOU_AGENT_ALERTS="1")
        self.assertEqual(row["status"], "OK", row)
        self.assertIn("alerts on", row["detail"])
        self.assertIn("restart Copilot", row["hint"])
        with open(os.path.join(self.copilot, "settings.json"), "w") as fh:
            json.dump({"disableAllHooks": True}, fh)
        row = self.check()
        self.assertEqual(row["status"], "WARN")
        self.assertIn("disableAllHooks", row["detail"])
        self.assertTrue(row["hint"].startswith('remove "disableAllHooks": true from ~/.copilot/settings.json'), row)
        os.remove(os.path.join(self.copilot, "settings.json"))
        for raw in (b"\xff\xfe", b"[1]", b'{"hooks": 1}'):
            with open(os.path.join(self.copilot, "hooks", "needs-you.json"), "wb") as fh:
                fh.write(raw)
            self.assertEqual(self.check()["status"], "WARN", raw)
        os.remove(os.path.join(self.copilot, "hooks", "needs-you.json"))
        os.remove(os.path.join(self.copilot, "hooks", "needs-you-hook.sh"))
        self.assertEqual(self.check()["status"], "INFO")
        # COPILOT_HOME moves it, as it moves Copilot's own hooks.
        other = os.path.join(self.home, "cp2")
        subprocess.run([BASH, INSTALLER], env={"HOME": self.home, "PATH": os.environ.get("PATH", ""),
                                               "COPILOT_HOME": other}, capture_output=True, timeout=60)
        self.assertEqual(self.check(COPILOT_HOME=other)["status"], "OK")


class UninstallHooks(unittest.TestCase):
    def test_offline_removal(self):
        home = tempfile.mkdtemp(prefix="ny-copilot-un-")
        self.addCleanup(shutil.rmtree, home, True)
        env = {"HOME": home, "PATH": os.environ.get("PATH", "")}
        subprocess.run([BASH, INSTALLER], env=env, capture_output=True, timeout=60)
        hooks = os.path.join(home, ".copilot", "hooks")
        with open(os.path.join(hooks, "mine.json"), "w") as fh:
            fh.write("{}")
        r = subprocess.run([sys.executable, CLI, "uninstall-hooks", "--copilot", "--dry-run"], env=env,
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
        files["install-copilot-hooks.sh"] = read(INSTALLER)
        files["copilot-hooks.json"] = read(COPILOT_HOOKS_JSON)
        h = self.hub(files=files)
        conf = self.install(".copilot/hooks/needs-you.json", b'{"_needs_you_version": "0.0.1", "version": 1}\n')
        hook = self.install(".copilot/hooks/needs-you-hook.sh", mode=0o755)
        r = self.run_cli("update", "--check", urls=[h.url])
        self.assertIn("needs-you-hook.sh (Copilot)", r.stdout)
        self.assertIn("copilot-hooks.json", r.stdout)
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(read(conf), read(COPILOT_HOOKS_JSON))
        self.assertEqual(read(hook), read(HOOK))
        with open(self.cli, "wb") as fh:
            fh.write(read(CLI))
        r = self.run_cli("--json", "update", "--check", urls=[h.url])
        self.assertEqual(json.loads(r.stdout)["changes"], [])

    def test_nothing_installed_nothing_written(self):
        h = self.hub()
        self.run_cli("update", urls=[h.url])
        self.assertFalse(os.path.exists(os.path.join(self.home, ".copilot")))


if __name__ == "__main__":
    unittest.main()
