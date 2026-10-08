"""Cline integration (integrations/cline/): the shared hook in `cline` mode.

The payloads are the ones the Cline CLI 3.0.69 sends to the executables in
~/Documents/Cline/Hooks/ (captured live against a loopback model stub): JSON on stdin,
camelCase, the conversation in `taskId`, `hookName` in the SDK's snake form (agent_start,
agent_end), `parent_agent_id` null for the main agent, and on TaskComplete the agent's last
text in `turn.outputText` (never put in a card). The hook files pass the event name as a
third argument. Cline waits up to 30 s for a hook in VS Code, so the work runs in the
background.
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

from hook_case import BASH, FAKE_CLI, HOOK, REAL_HOME, SECRET, HookCase, opt
from support import CLI, ROOT, free_port, wait_until
from test_cli_update import UpdateCase, current_files, read

TASK = "conv_1791422254715_afjarb4"


class ClineHook(HookCase):
    AGENT = "cline"

    def payload(self, hook_name, **extra):
        p = {"clineVersion": "", "timestamp": "2026-10-08T01:17:34.787Z", "taskId": TASK,
             "sessionContext": {"rootSessionId": "1791422235085_n1jtu"}, "workspaceRoots": [self.cwd],
             "workspaceInfo": {"rootPath": self.cwd, "hint": "my-repo"}, "userId": "someone",
             "agent_id": "agent_9d5bfcc7", "parent_agent_id": None, "hookName": hook_name}
        p.update(extra)
        return p

    def complete(self, task=TASK, **extra):
        p = self.payload("agent_end", iteration=1, turn={"outputText": "Here it is: " + SECRET,
                                                          "status": "completed"},
                         taskComplete={"taskMetadata": {"result": SECRET}})
        p["taskId"] = task
        return self.run_hook(["notify", "cline", "TaskComplete"], p, cwd=self.home, **extra)

    def test_finished_card(self):
        r = self.complete()
        self.assertEqual(r.stdout, "")  # "no JSON" is "go on" for Cline
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"), "Cline finished: my-repo")
        self.assertEqual(opt(argv, "--agent"), "cline")
        self.assertEqual(opt(argv, "--project"), "my-repo")  # from workspaceRoots, not the hook's cwd
        self.assertEqual(opt(argv, "--key").split(":")[-1], TASK)
        self.assertNotIn(SECRET, json.dumps(self.calls()))
        self.wait_marker(TASK)
        self.assertEqual(self.read_marker(TASK)["pid"], str(os.getpid()))

    def test_prompt_cancel_and_shutdown_resolve(self):
        for event, mode in (("UserPromptSubmit", "resolve"), ("TaskCancel", "resolve"), ("SessionShutdown", "end")):
            self.complete()
            n = len(self.wait_calls(1))
            key = opt(self.calls()[-1], "--key")
            self.wait_marker(TASK)
            r = self.run_hook([mode, "cline", event], self.payload(event, userPromptSubmit={"prompt": SECRET}),
                              cwd=self.home)
            self.assertEqual(r.stdout, "")
            self.assertEqual(self.wait_calls(n + 1)[-1], ["resolve", "--key", key], event)
            self.wait_marker(TASK, present=False)
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_new_task_clears_the_finished_card_of_the_last_one(self):
        # A new task in the same Cline (VS Code window, CLI hub) has a new taskId.
        self.complete(task="conv_old")
        key = opt(self.wait_calls(1)[-1], "--key")
        self.wait_marker("conv_old")
        self.run_hook(["start", "cline", "TaskStart"], self.payload("agent_start", taskStart={"taskMetadata": {}}),
                      cwd=self.home)
        self.assertEqual(self.wait_calls(2)[-1], ["resolve", "--key", key])

    def test_error_card(self):
        self.run_hook(["notify", "cline", "TaskError"], self.payload("agent_error", error={"message": SECRET}),
                      cwd=self.home)
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"), "Cline stopped on an error: my-repo")
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_quiet_cases(self):
        self.complete(NEEDS_YOU_AGENT_ALERTS="")                          # not opted in
        self.complete(NEEDS_YOU_AGENT_TURN_CARDS="0")                     # turn cards off
        sub = self.payload("agent_end", parent_agent_id="agent_parent")   # a subagent
        self.run_hook(["notify", "cline", "TaskComplete"], sub, cwd=self.home)
        self.complete(NY_HOOK_PPID=self.gone_pid())                       # `cline "task"` exited
        time.sleep(0.8)
        self.assertEqual(self.calls(), [])


INSTALLER = os.path.join(ROOT, "integrations", "cline", "install-cline-hooks.sh")
EVENTS = {"TaskComplete": "notify", "TaskError": "notify", "UserPromptSubmit": "resolve", "TaskCancel": "resolve",
          "TaskStart": "start", "TaskResume": "start", "SessionShutdown": "end"}


class Installer(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-cline-inst-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.assertNotEqual(self.home, REAL_HOME)
        self.hooks = os.path.join(self.home, "Documents", "Cline", "Hooks")
        self.hook = os.path.join(self.home, ".config", "needs-you", "cline", "hooks", "needs-you-hook.sh")

    def run_installer(self, *args):
        return subprocess.run([BASH, INSTALLER] + list(args), env={"HOME": self.home, "PATH": os.environ["PATH"]},
                              capture_output=True, text=True, timeout=60)

    def test_install_rerun_uninstall(self):
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(sorted(os.listdir(self.hooks)), sorted(EVENTS))
        for ev, mode in EVENTS.items():
            f = os.path.join(self.hooks, ev)
            self.assertTrue(os.access(f, os.X_OK), ev)
            with open(f) as fh:
                text = fh.read()
            self.assertTrue(text.startswith("#!/bin/sh\n"))
            self.assertIn("exec \"$hook\" %s cline %s\n" % (mode, ev), text)
        self.assertEqual(read(self.hook), read(HOOK))
        self.assertIn("no hook when it waits for your approval", r.stdout)
        self.assertEqual(self.run_installer().stdout.count("already up to date"), len(EVENTS) + 1)
        r = self.run_installer("--uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.listdir(self.hooks), [])
        self.assertFalse(os.path.exists(self.hook))

    def test_own_hook_files_are_kept(self):
        os.makedirs(self.hooks)
        mine = os.path.join(self.hooks, "UserPromptSubmit")
        with open(mine, "w") as fh:
            fh.write("#!/bin/sh\necho mine\n")
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Kept your own hook files: UserPromptSubmit", r.stdout)
        with open(mine) as fh:
            self.assertEqual(fh.read(), "#!/bin/sh\necho mine\n")
        self.run_installer("--uninstall")
        self.assertEqual(os.listdir(self.hooks), ["UserPromptSubmit"])
        # Their own TaskComplete: no card possible, so nothing is installed.
        with open(os.path.join(self.hooks, "TaskComplete"), "w") as fh:
            fh.write("#!/bin/sh\n")
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("TaskComplete is your own hook", r.stderr)
        self.assertEqual(sorted(os.listdir(self.hooks)), ["TaskComplete", "UserPromptSubmit"])

    def test_hook_file_runs_the_hook(self):
        self.run_installer()
        cli = os.path.join(self.home, "fake-needs-you")
        with open(cli, "w") as fh:
            fh.write(FAKE_CLI)
        os.chmod(cli, 0o755)
        log = os.path.join(self.home, "calls.log")
        payload = {"taskId": "conv_x", "hookName": "agent_end", "workspaceRoots": ["/srv/my-repo"],
                   "parent_agent_id": None, "turn": {"outputText": SECRET}}
        env = {"HOME": self.home, "PATH": os.environ["PATH"], "NEEDS_YOU_BIN": cli, "FAKE_CLI_LOG": log,
               "NEEDS_YOU_AGENT_ALERTS": "1", "NY_TURN_WAIT": "0"}
        r = subprocess.run([os.path.join(self.hooks, "TaskComplete")], input=json.dumps(payload), env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.assertTrue(wait_until(lambda: os.path.exists(log), timeout=10))
        with open(log) as fh:
            argv = json.loads(fh.readline())
        self.assertEqual(opt(argv, "--title"), "Cline finished: my-repo")
        self.assertNotIn(SECRET, json.dumps(argv))


class Doctor(unittest.TestCase):
    def test_states(self):
        home = tempfile.mkdtemp(prefix="ny-cline-doc-")
        self.addCleanup(shutil.rmtree, home, True)

        def check(**env):
            e = {"HOME": home, "PATH": "/usr/bin:/bin", "NEEDS_YOU_URLS": "http://127.0.0.1:%d" % free_port(),
                 "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_TIMEOUT": "1", "NEEDS_YOU_GH": "none"}
            e.update(env)
            r = subprocess.run([sys.executable, CLI, "doctor", "--json"], env=e, capture_output=True, text=True,
                               timeout=60)
            rows = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "cline hooks"]
            return rows[0] if rows else None

        self.assertIsNone(check())
        os.makedirs(os.path.join(home, "Documents", "Cline"))
        self.assertEqual(check()["status"], "INFO")
        subprocess.run([BASH, INSTALLER], env={"HOME": home, "PATH": os.environ["PATH"]}, capture_output=True,
                       timeout=60)
        row = check(NEEDS_YOU_AGENT_ALERTS="1")
        self.assertEqual(row["status"], "OK", row)
        self.assertIn("alerts on", row["detail"])
        os.remove(os.path.join(home, ".config", "needs-you", "cline", "hooks", "needs-you-hook.sh"))
        row = check()
        self.assertEqual(row["status"], "WARN")
        self.assertIn("--cline-hooks user", row["hint"])


class UninstallHooks(unittest.TestCase):
    def test_offline_removal(self):
        home = tempfile.mkdtemp(prefix="ny-cline-un-")
        self.addCleanup(shutil.rmtree, home, True)
        env = {"HOME": home, "PATH": os.environ["PATH"]}
        subprocess.run([BASH, INSTALLER], env=env, capture_output=True, timeout=60)
        hooks = os.path.join(home, "Documents", "Cline", "Hooks")
        with open(os.path.join(hooks, "PreToolUse"), "w") as fh:
            fh.write("#!/bin/sh\n")
        r = subprocess.run([sys.executable, CLI, "uninstall-hooks", "--cline", "--dry-run"], env=env,
                           capture_output=True, text=True, timeout=60, cwd=home)
        self.assertIn("would delete", r.stdout)
        self.assertEqual(len(os.listdir(hooks)), len(EVENTS) + 1)
        r = subprocess.run([sys.executable, CLI, "uninstall-hooks"], env=env, capture_output=True, text=True,
                           timeout=60, cwd=home)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.listdir(hooks), ["PreToolUse"])
        self.assertFalse(os.path.exists(os.path.join(home, ".config", "needs-you", "cline")))


class Update(UpdateCase):
    def test_hook_copy(self):
        h = self.hub(files=dict(current_files(), **{"install-cline-hooks.sh": read(INSTALLER)}))
        hook = self.install(".config/needs-you/cline/hooks/needs-you-hook.sh", mode=0o755)
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("needs-you-hook.sh (Cline)", r.stdout)
        self.assertEqual(read(hook), read(HOOK))


if __name__ == "__main__":
    unittest.main()
