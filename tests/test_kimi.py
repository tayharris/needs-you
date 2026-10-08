"""Kimi Code CLI integration (integrations/kimi/): the shared hook in `kimi` mode.

The payloads are the ones Kimi Code 2.1.1 sends (captured live with a temporary
KIMI_CODE_HOME and a stub model server): snake_case keys, `session_id` like
`session_<uuid>`, `client_type: kimi_code_cli`. Kimi awaits Stop, UserPromptSubmit,
PreToolUse and the session hooks, starts every hook through `sh -c` in a process group of
its own, and kills that group when a hook runs past its timeout: the hook hands its work to
a copy in a new session and returns at once, so the tests wait for the fake CLI's log.
Everything runs with a temporary HOME, so the real ~/.kimi-code, ~/.claude and ~/.config
are never touched.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

from support import ROOT, wait_until

BASH = shutil.which("bash") or "/bin/bash"
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")

FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys, time
time.sleep(float(os.environ.get("FAKE_CLI_SLEEP") or 0))
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
"""

SECRET = "sk-test-SECRET-0123456789"
SESSION = "session_68842dd7-40c1-4f7d-8df5-31ccf7275b7b"


def opt(argv, name):
    for i, a in enumerate(argv):
        if a.startswith(name + "="):
            return a[len(name) + 1:]
        if a == name:
            return argv[i + 1]
    raise ValueError(name)


class KimiHook(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-kimi-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.cli = os.path.join(self.home, "fake-needs-you")
        with open(self.cli, "w") as fh:
            fh.write(FAKE_CLI)
        os.chmod(self.cli, 0o755)
        self.log = os.path.join(self.home, "calls.log")
        self.state = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks")
        self.cwd = os.path.join(self.home, "src", "my-repo")
        os.makedirs(self.cwd)

    def env(self, **extra):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_BIN": self.cli, "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1",
               "NEEDS_YOU_HOOK_PLATFORM": "linux", "NY_KIMI_TURN_WAIT": "0"}
        env.update(extra)
        return {k: v for k, v in env.items() if v is not None}

    def payload(self, event, data):
        p = {"hook_event_name": event, "session_id": SESSION, "cwd": self.cwd, "client_type": "kimi_code_cli"}
        p.update(data)
        return json.dumps(p)

    def run_hook(self, mode, event, data, **extra):
        started = time.time()
        r = subprocess.run([BASH, HOOK, mode, "kimi"], input=self.payload(event, data), env=self.env(**extra),
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        # Kimi appends a UserPromptSubmit hook's stdout to the model's context, and reads a
        # Stop hook's JSON as a decision: the hook prints nothing and returns at once.
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

    def marker(self):
        path = os.path.join(self.state, SESSION)
        self.assertTrue(wait_until(lambda: os.path.exists(path), timeout=10))
        with open(path) as fh:
            return dict(l.rstrip("\n").split("=", 1) for l in fh)

    def permission(self, tool, display, tool_input, n):
        self.run_hook("notify", "PermissionRequest", {
            "id": "approval_1", "agent_id": "main", "turn_id": "t1", "tool_call_id": "call_1",
            "tool_name": tool, "action": "Running: " + json.dumps(tool_input), "display": display,
            "tool_input": tool_input, "session_title": SECRET})
        return self.wait_calls(n)[-1]

    def test_permission_card_names_only_the_program(self):
        cmd = "API_KEY=%s make deploy" % SECRET
        argv = self.permission("Bash", {"kind": "command", "command": cmd, "cwd": self.cwd,
                                        "description": SECRET, "language": "bash"}, {"command": cmd}, 1)
        self.assertEqual(opt(argv, "--title"), "Kimi wants to run make: my-repo")
        self.assertEqual(opt(argv, "--agent"), "kimi-code")
        self.assertEqual(opt(argv, "--project"), "my-repo")
        self.assertEqual(opt(argv, "--key").split(":")[-1], SESSION)
        self.assertEqual(self.marker()["kind"], "permission")
        argv = self.permission("Write", {"kind": "file"}, {"path": "/x/secrets/.env.prod", "content": SECRET}, 2)
        self.assertEqual(opt(argv, "--title"), "Kimi wants to edit .env.prod: my-repo")
        argv = self.permission("Edit", {}, {"file_path": "/x/a.py", "old_string": SECRET}, 3)
        self.assertEqual(opt(argv, "--title"), "Kimi wants to edit a.py: my-repo")
        argv = self.permission("FetchURL", {}, {"url": "https://example.com/?t=" + SECRET}, 4)
        self.assertEqual(opt(argv, "--title"), "Kimi wants to fetch a page: my-repo")
        argv = self.permission("ExitPlanMode", {}, {"plan": SECRET}, 5)
        self.assertEqual(opt(argv, "--title"), "Approve Kimi's plan: my-repo")
        argv = self.permission("mcp__github__create_issue", {}, {"body": SECRET}, 6)
        self.assertEqual(opt(argv, "--title"), "Kimi needs permission for github create_issue: my-repo")
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_question_turn_end_and_failure(self):
        self.run_hook("notify", "PreToolUse", {"tool_name": "AskUserQuestion", "tool_call_id": "c2",
                                               "tool_input": {"questions": [{"question": SECRET}]}})
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"), "Kimi asked you a question: my-repo")
        # PreToolUse for any other tool (a wider matcher by hand) posts nothing
        self.run_hook("notify", "PreToolUse", {"tool_name": "Bash", "tool_input": {"command": "ls"}})
        self.run_hook("notify", "Stop", {"stop_hook_active": False})
        argv = self.wait_calls(2)[-1]
        self.assertEqual(opt(argv, "--title"), "Kimi is waiting for you: my-repo")
        self.run_hook("notify", "StopFailure", {"error_type": "rate_limit", "error_message": "429 Too Many Requests"})
        argv = self.wait_calls(3)[-1]
        self.assertEqual(opt(argv, "--title"), "Kimi stopped on an error: my-repo")
        self.assertIn("429 Too Many Requests", opt(argv, "--body"))
        self.assertEqual(self.marker()["kind"], "failure")
        time.sleep(0.3)
        self.assertEqual(len(self.calls()), 3)
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_turn_cards_can_be_turned_off_and_opt_in_is_required(self):
        self.run_hook("notify", "Stop", {"stop_hook_active": False}, NEEDS_YOU_AGENT_TURN_CARDS="0")
        self.run_hook("notify", "Stop", {"stop_hook_active": False}, NEEDS_YOU_AGENT_ALERTS=None)
        self.run_hook("notify", "PermissionRequest", {"tool_name": "Bash", "display": {"command": "ls"}},
                      NEEDS_YOU_AGENT_ALERTS="0")
        time.sleep(0.8)
        self.assertEqual(self.calls(), [])

    def test_no_turn_card_from_a_one_shot_run(self):
        # `kimi -p` ends its turn (Stop) and exits a moment later: nobody is waiting, so no
        # card. The turn-end card waits that moment and checks Kimi is still there.
        gone = subprocess.Popen(["true"])
        gone.wait()
        self.run_hook("notify", "Stop", {"stop_hook_active": False}, NY_HOOK_PPID=str(gone.pid),
                      NY_KIMI_TURN_WAIT="0.5")
        time.sleep(1.5)
        self.assertEqual(self.calls(), [])
        self.assertFalse(os.path.exists(os.path.join(self.state, SESSION)))

    def test_answer_prompt_tool_interrupt_and_session_end_resolve(self):
        self.permission("Bash", {"command": "make"}, {"command": "make"}, 1)
        key = opt(self.calls()[-1], "--key")
        self.marker()
        self.run_hook("resolve", "PermissionResult", {"tool_name": "Bash", "decision": "approved",
                                                      "feedback": SECRET})
        self.assertEqual(self.wait_calls(2)[-1], ["resolve", "--key", key])
        self.run_hook("resolve", "PostToolUse", {"tool_name": "Bash", "tool_output": SECRET})
        time.sleep(0.5)
        self.assertEqual(len(self.calls()), 2)  # nothing open: no network call
        self.run_hook("notify", "Stop", {"stop_hook_active": False})
        self.wait_calls(3)
        self.marker()
        self.run_hook("resolve", "UserPromptSubmit", {"prompt": [{"type": "text", "text": SECRET}],
                                                      "is_steer": False})
        self.assertEqual(self.wait_calls(4)[-1], ["resolve", "--key", key])
        self.run_hook("notify", "Stop", {"stop_hook_active": False})
        self.wait_calls(5)
        self.marker()
        self.run_hook("resolve", "Interrupt", {"turn_id": "t2", "reason": "user"})
        self.assertEqual(self.wait_calls(6)[-1], ["resolve", "--key", key])
        self.run_hook("notify", "Stop", {"stop_hook_active": False})
        self.wait_calls(7)
        self.marker()
        self.run_hook("end", "SessionEnd", {"reason": "exit"})
        self.assertEqual(self.wait_calls(8)[-1], ["resolve", "--key", key])
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_lease_names_kimi_not_the_shell_it_starts_hooks_with(self):
        # Kimi runs `sh -c '<command>'`; by the time the background copy looks, that shell has
        # exited, so the foreground names its parent (Kimi) for the lease.
        script = '"$0" "$@"; exit 0'  # a shell between "Kimi" (this test) and the hook, gone at once
        r = subprocess.run(["sh", "-c", script, BASH, HOOK, "notify", "kimi"],
                           input=self.payload("PermissionRequest", {"tool_name": "Bash", "display": {"command": "make"}}),
                           env=self.env(), capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.wait_calls(1)
        self.assertEqual(self.marker()["pid"], str(os.getpid()))

    def test_background_work_survives_the_process_group_kill(self):
        # Kimi kills a hook's whole process group (SIGTERM, then SIGKILL) when it runs past its
        # timeout. The background copy runs in a session of its own, so a slow hub doesn't
        # lose the card.
        p = subprocess.Popen([BASH, HOOK, "notify", "kimi"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, env=self.env(FAKE_CLI_SLEEP="1.5"),
                             start_new_session=True, text=True)
        p.communicate(self.payload("PermissionRequest", {"tool_name": "Bash", "display": {"command": "make"}}),
                      timeout=10)
        time.sleep(0.3)
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"), "Kimi wants to run make: my-repo")


if __name__ == "__main__":
    unittest.main()
