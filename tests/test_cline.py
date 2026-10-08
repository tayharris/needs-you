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
import time

from hook_case import SECRET, HookCase, opt

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


if __name__ == "__main__":
    import unittest
    unittest.main()
