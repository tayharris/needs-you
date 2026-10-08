"""Gemini CLI integration (integrations/gemini/): the shared hook in `gemini` mode, the
settings.json installer, a real-hub round trip, `needs-you doctor` and `needs-you update`.

Gemini waits for every hook, so in this mode the hook returns at once and finishes in the
background; the tests wait for the fake CLI's log. Everything runs with a temporary HOME,
so the real ~/.gemini, ~/.claude and ~/.config are never touched.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from hook_case import fixture, choice_texts
from support import CLI, ROOT, HubTestCase, free_port, request, wait_until
from test_cli_update import UpdateCase, current_files, read

BASH = shutil.which("bash") or "/bin/bash"
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
GEMINI_HOOKS_JSON = os.path.join(ROOT, "integrations", "gemini", "gemini-hooks.json")
INSTALLER = os.path.join(ROOT, "integrations", "gemini", "install-gemini-hooks.sh")
REAL_HOME = os.path.expanduser("~")

FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
"""

SECRET = "sk-test-SECRET-0123456789"
OTHER_HOOK = {"name": "mine", "type": "command", "command": "/opt/other/hook.sh", "timeout": 5000}


def opt(argv, name):
    for i, a in enumerate(argv):
        if a.startswith(name + "="):
            return a[len(name) + 1:]
        if a == name:
            return argv[i + 1]
    raise ValueError(name)


class GeminiHook(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-gemini-")
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
               "NEEDS_YOU_HOOK_PLATFORM": "linux", "GEMINI_PROJECT_DIR": self.cwd,
               "CLAUDE_PROJECT_DIR": self.cwd}  # Gemini sets this one too
        env.update(extra)
        payload = {"session_id": "gem-sess-1", "cwd": self.cwd, "transcript_path": "",
                   "timestamp": "2026-10-07T12:00:00Z"}
        payload.update(data)
        started = time.time()
        r = subprocess.run([BASH, HOOK, mode, "gemini"], input=json.dumps(payload), env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        # Gemini parses stdout (and else stderr) as the hook's JSON answer: both stay empty.
        self.assertEqual((r.stdout, r.stderr), ("", ""))
        self.assertLess(time.time() - started, 2)
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
        path = os.path.join(self.state, "gem-sess-1")
        self.assertTrue(wait_until(lambda: os.path.exists(path) == present, timeout=10))

    def permission(self, details, n):
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "ToolPermission",
                                 "message": "Tool %s requires execution" % SECRET, "details": details})
        return self.wait_calls(n)[-1]

    def test_exec_names_only_the_program(self):
        argv = self.permission({"type": "exec", "title": "Confirm Shell Command",
                                "command": "curl -H 'Authorization: %s' https://x" % SECRET,
                                "rootCommand": "curl"}, 1)
        self.assertEqual(argv[0], "add")
        self.assertEqual(opt(argv, "--title"), "Gemini wants to run curl: my-repo")
        self.assertEqual(opt(argv, "--agent"), "gemini-cli")
        self.assertTrue(opt(argv, "--key").endswith(":gem-sess-1"))
        self.assertNotIn(SECRET, json.dumps(argv))

    def test_edit_mcp_info_and_unknown(self):
        self.assertEqual(opt(self.permission({"type": "edit", "fileName": "app.py", "filePath": "/x/app.py",
                                              "fileDiff": SECRET, "newContent": SECRET}, 1), "--title"),
                         "Gemini wants to edit app.py: my-repo")
        self.assertEqual(opt(self.permission({"type": "mcp", "serverName": "github", "toolName": "create_pr"}, 2),
                             "--title"), "Gemini needs permission for github create_pr: my-repo")
        self.assertEqual(opt(self.permission({"type": "info", "urls": [SECRET]}, 3), "--title"),
                         "Gemini wants to fetch a page: my-repo")
        argv = self.permission({}, 4)
        self.assertEqual(opt(argv, "--title"), "Gemini needs your approval: my-repo")
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_ask_user_question_and_choices(self):
        # BeforeTool (matcher ^ask_user$) has the questions; the ToolPermission notification
        # that follows for ask_user has none, and posts nothing over the question card.
        data = fixture("gemini-ask-user.json")
        data.update(session_id="gem-sess-1", cwd=self.cwd)
        self.run_hook("notify", data)
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"),
                         "Gemini asks \u201cWhich test runner should the new package use?\u201d and 1 more: my-repo")
        self.assertIn("**Publish** \u00b7 choose one\nPublish it to npm now?", opt(argv, "--body"))
        self.assertEqual(choice_texts(argv), ["Tests: Vitest \u2014 Same as the other packages",
                                            "Tests: Jest \u2014 What the template ships", "Publish: Yes", "Publish: No"])
        self.wait_marker()
        self.permission({"type": "ask_user", "title": "Ask User"}, 1)
        time.sleep(0.5)
        self.assertEqual(len(self.calls()), 1)
        # another tool through a wider matcher posts nothing
        self.run_hook("notify", {"hook_event_name": "BeforeTool", "tool_name": "run_shell_command",
                                 "tool_input": {"command": SECRET}})
        # the turn ends with the question card still up (never shown): it goes, then "waiting"
        self.run_hook("notify", {"hook_event_name": "AfterAgent"})
        calls = self.wait_calls(3)
        self.assertEqual([c[0] for c in calls], ["add", "resolve", "add"])
        self.assertEqual(opt(calls[2], "--title"), "Gemini is waiting for you: my-repo")
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_plan_approval(self):
        argv = self.permission({"type": "exit_plan_mode", "title": "Plan", "planPath": "/x/%s.md" % SECRET}, 1)
        self.assertEqual(opt(argv, "--title"), "Gemini wants approval for a plan: my-repo")
        self.assertNotIn(SECRET, json.dumps(argv))

    def test_turn_end_card_and_switch(self):
        self.run_hook("notify", {"hook_event_name": "AfterAgent", "prompt": SECRET,
                                 "prompt_response": SECRET, "stop_hook_active": False})
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"), "Gemini is waiting for you: my-repo")
        self.assertNotIn(SECRET, json.dumps(argv))
        self.run_hook("notify", {"hook_event_name": "AfterAgent"}, NEEDS_YOU_AGENT_TURN_CARDS="0")
        time.sleep(0.5)
        self.assertEqual(len(self.calls()), 1)

    def test_quiet_unless_opted_in(self):
        self.run_hook("notify", {"hook_event_name": "AfterAgent"}, NEEDS_YOU_AGENT_ALERTS="")
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "Other"})
        time.sleep(0.5)
        self.assertEqual(self.calls(), [])

    def test_prompt_and_tool_resolve(self):
        self.run_hook("notify", {"hook_event_name": "AfterAgent"})
        key = opt(self.wait_calls(1)[-1], "--key")
        self.wait_marker(True)
        self.run_hook("resolve", {"hook_event_name": "BeforeAgent", "prompt": SECRET})
        self.assertEqual(self.wait_calls(2)[-1], ["resolve", "--key", key])
        self.wait_marker(False)
        self.run_hook("resolve", {"hook_event_name": "AfterTool", "tool_name": "x"})
        time.sleep(0.5)
        self.assertEqual(len(self.calls()), 2)  # nothing posted since: no network call

    def test_session_end_and_lease(self):
        self.permission({"type": "exec", "rootCommand": "ls"}, 1)
        self.wait_marker(True)
        with open(os.path.join(self.state, "gem-sess-1")) as fh:
            m = dict(l.rstrip("\n").split("=", 1) for l in fh)
        # The lease names the process that ran the hook (here: this test), not init.
        self.assertEqual(m["pid"], str(os.getpid()))
        self.run_hook("end", {"hook_event_name": "SessionEnd", "reason": "exit"})
        self.assertEqual(self.wait_calls(2)[-1][0], "resolve")


class GeminiHooksJson(unittest.TestCase):
    def test_registers_the_events(self):
        with open(GEMINI_HOOKS_JSON) as fh:
            doc = json.load(fh)
        self.assertNotIn("_needs_you_version", doc["hooks"])
        hooks = doc["hooks"]
        self.assertEqual({ev: g[0]["hooks"][0]["command"].split()[-2:] for ev, g in hooks.items()},
                         {"Notification": ["notify", "gemini"], "AfterAgent": ["notify", "gemini"],
                          "BeforeTool": ["notify", "gemini"],
                          "BeforeAgent": ["resolve", "gemini"], "AfterTool": ["resolve", "gemini"],
                          "SessionStart": ["start", "gemini"], "SessionEnd": ["end", "gemini"]})
        self.assertEqual(hooks["Notification"][0]["matcher"], "ToolPermission")
        self.assertEqual(hooks["BeforeTool"][0]["matcher"], "^ask_user$")  # a regex in Gemini
        for groups in hooks.values():
            h = groups[0]["hooks"][0]
            self.assertEqual((h["type"], h["name"]), ("command", "needs-you"))
            self.assertLessEqual(h["timeout"], 60000)  # milliseconds in Gemini


class Installer(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-gemini-inst-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.assertNotEqual(self.home, REAL_HOME)
        self.gemini = os.path.join(self.home, ".gemini")
        self.settings = os.path.join(self.gemini, "settings.json")

    def run_installer(self, *args):
        return subprocess.run([BASH, INSTALLER] + list(args),
                              env={"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")},
                              capture_output=True, text=True, timeout=60)

    def test_merge_keeps_settings_and_other_hooks(self):
        os.makedirs(self.gemini)
        before = {"theme": "Default", "security": {"auth": {"selectedType": "oauth-personal"}},
                  "hooks": {"AfterAgent": [{"hooks": [OTHER_HOOK]}]}}
        with open(self.settings, "w") as fh:
            json.dump(before, fh)
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(self.settings) as fh:
            doc = json.load(fh)
        self.assertEqual(doc["theme"], "Default")
        self.assertEqual(doc["security"], before["security"])
        self.assertEqual(doc["hooks"]["AfterAgent"][0], {"hooks": [OTHER_HOOK]})
        self.assertEqual(doc["hooks"]["AfterAgent"][1]["hooks"][0]["command"],
                         '"$HOME/.gemini/hooks/needs-you-hook.sh" notify gemini')
        self.assertEqual(read(os.path.join(self.gemini, "hooks", "needs-you-hook.sh")), read(HOOK))
        self.assertIn("already up to date", self.run_installer().stdout)
        r = self.run_installer("--uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.settings) as fh:
            self.assertEqual(json.load(fh), before)
        self.assertFalse(os.path.exists(os.path.join(self.gemini, "hooks", "needs-you-hook.sh")))

    def test_settings_with_comments_are_left_alone(self):
        os.makedirs(self.gemini)
        text = '{\n  // my theme\n  "theme": "Default"\n}\n'
        with open(self.settings, "w") as fh:
            fh.write(text)
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("merge gemini-hooks.json into it by hand", r.stderr)
        with open(self.settings) as fh:
            self.assertEqual(fh.read(), text)

    def test_symlinked_or_malformed_settings_are_left_alone(self):
        os.makedirs(self.gemini)
        target = os.path.join(self.home, "dotfiles-settings.json")
        with open(target, "w") as fh:
            fh.write('{"theme": "x"}')
        os.symlink(target, self.settings)
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("symlink", r.stderr)
        with open(target) as fh:
            self.assertEqual(fh.read(), '{"theme": "x"}')
        os.remove(self.settings)
        for text in ("[]", '{"hooks": "x"}', "\xff\xfe"):
            with open(self.settings, "w", encoding="latin-1") as fh:
                fh.write(text)
            r = self.run_installer()
            self.assertNotEqual(r.returncode, 0, text)
            with open(self.settings, encoding="latin-1") as fh:
                self.assertEqual(fh.read(), text)

    def test_warns_when_hooks_are_off_and_gemini_dir(self):
        os.makedirs(self.gemini)
        with open(self.settings, "w") as fh:
            json.dump({"hooksConfig": {"enabled": False}}, fh)
        self.assertIn("hooksConfig.enabled is false", self.run_installer().stdout)
        other = os.path.join(self.home, "g2")
        r = self.run_installer("--gemini-dir", other)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(other, "settings.json")) as fh:
            cmd = json.load(fh)["hooks"]["SessionEnd"][0]["hooks"][0]["command"]
        self.assertEqual(cmd, '"%s/hooks/needs-you-hook.sh" end gemini' % other)


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
        self.hook = os.path.join(self.home, ".gemini", "hooks", "needs-you-hook.sh")

    def run_hook(self, mode, data, url):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_BIN": CLI,
               "NEEDS_YOU_URLS": url, "NEEDS_YOU_TOKEN": self.sender, "NEEDS_YOU_TIMEOUT": "2",
               "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_HOOK_PLATFORM": "linux"}
        payload = {"session_id": "gem-e2e", "cwd": "/srv/my-repo"}
        payload.update(data)
        r = subprocess.run([BASH, self.hook, mode, "gemini"], input=json.dumps(payload), env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))

    def items(self):
        _, body = request("GET", self.hub.url + "/v1/items?status=all", self.reader)
        return [i for i in body["items"] if i["key"].endswith(":gem-e2e")]

    def test_post_then_resolve(self):
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "ToolPermission",
                                 "details": {"type": "exec", "rootCommand": "npm"}}, self.hub.url)
        self.assertTrue(wait_until(lambda: len(self.items()) == 1, timeout=10))
        item = self.items()[0]
        self.assertEqual(item["title"], "Gemini wants to run npm: my-repo")
        self.assertEqual(item["source"]["agent"], "gemini-cli")
        marker = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks", "gem-e2e")
        self.assertTrue(wait_until(lambda: os.path.exists(marker), timeout=10))
        self.run_hook("resolve", {"hook_event_name": "BeforeAgent"}, self.hub.url)
        self.assertTrue(wait_until(lambda: self.items()[0]["status"] == "resolved", timeout=10), self.items())

    def test_hub_down_queues(self):
        self.run_hook("notify", {"hook_event_name": "AfterAgent"}, "http://127.0.0.1:%d" % free_port())
        outbox = os.path.join(self.home, ".local", "state", "needs-you", "outbox")
        self.assertTrue(wait_until(lambda: os.path.isdir(outbox) and
                                   any(n.endswith(".json") for n in os.listdir(outbox)), timeout=30))  # the hook posts after its turn wait, in the background


class Doctor(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-gemini-doc-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.gemini = os.path.join(self.home, ".gemini")

    def check(self, **env):
        e = {"HOME": self.home, "PATH": "/usr/bin:/bin", "NEEDS_YOU_URLS": "http://127.0.0.1:%d" % free_port(),
             "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_TIMEOUT": "1", "NEEDS_YOU_GH": "none"}
        e.update(env)
        r = subprocess.run([sys.executable, CLI, "doctor", "--json"], env=e, capture_output=True, text=True, timeout=60)
        rows = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "gemini hooks"]
        return rows[0] if rows else None

    def test_states(self):
        self.assertIsNone(self.check())
        os.makedirs(self.gemini)
        self.assertEqual(self.check()["status"], "INFO")
        r = subprocess.run([BASH, INSTALLER], env={"HOME": self.home, "PATH": os.environ.get("PATH", "")},
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        row = self.check(NEEDS_YOU_AGENT_ALERTS="1")
        self.assertEqual(row["status"], "OK", row)
        self.assertIn("alerts on", row["detail"])
        # Gemini CLI runs no hooks at all (user-level included) in a folder it doesn't trust,
        # and folder trust is on by default.
        self.assertIn("trusted folders", row["hint"])
        settings = os.path.join(self.gemini, "settings.json")
        with open(settings) as fh:
            doc = json.load(fh)
        doc["security"] = {"folderTrust": {"enabled": False}}
        with open(settings, "w") as fh:
            json.dump(doc, fh)
        row = self.check(NEEDS_YOU_AGENT_ALERTS="1")
        self.assertEqual(row["status"], "OK", row)
        self.assertNotIn("trusted folders", row["hint"])
        doc["hooksConfig"] = {"enabled": False}
        with open(settings, "w") as fh:
            json.dump(doc, fh)
        row = self.check()
        self.assertEqual(row["status"], "WARN")
        self.assertIn("hooksConfig.enabled is false", row["detail"])
        # Malformed settings are read as data only: no crash, never trusted.
        for raw in (b"\xff\xfe needs-you-hook.sh", b'{"hooksConfig": "x", "hooks": 1} needs-you-hook.sh',
                    b'[1] needs-you-hook.sh'):
            with open(settings, "wb") as fh:
                fh.write(raw)
            self.assertIn(self.check()["status"], ("OK", "WARN"), raw)


class Update(UpdateCase):
    def test_gemini_hook_and_entries(self):
        files = current_files()
        files["install-gemini-hooks.sh"] = read(INSTALLER)
        files["gemini-hooks.json"] = read(GEMINI_HOOKS_JSON)
        h = self.hub(files=files)
        hook = self.install(".gemini/hooks/needs-you-hook.sh", mode=0o755)
        settings = self.install(".gemini/settings.json", json.dumps({"theme": "keep", "hooks": {"AfterAgent": [
            {"hooks": [{"type": "command", "command": '"$HOME/.gemini/hooks/needs-you-hook.sh" notify gemini'}]}]}}).encode())
        r = self.run_cli("update", "--check", urls=[h.url])
        self.assertIn("would update needs-you-hook.sh (Gemini)", r.stdout)
        self.assertIn("gemini-hooks.json", r.stdout)
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(read(hook), read(HOOK))
        with open(settings) as fh:
            doc = json.load(fh)
        self.assertEqual(doc["theme"], "keep")
        self.assertIn("Notification", doc["hooks"])
        with open(os.path.join(self.home, ".local", "state", "needs-you", "update.json")) as fh:
            st = json.load(fh)
        self.assertEqual(st["gemini_hooks_json_sha256"], hashlib.sha256(read(GEMINI_HOOKS_JSON)).hexdigest())
        with open(self.cli, "wb") as fh:
            fh.write(read(CLI))
        r = self.run_cli("--json", "update", "--check", urls=[h.url])
        self.assertEqual(json.loads(r.stdout)["changes"], [])


if __name__ == "__main__":
    unittest.main()
