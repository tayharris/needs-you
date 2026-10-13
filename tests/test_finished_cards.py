"""Finished-turn cards don't outlive the turn by much.

A "Claude finished: <session>" card (source.event finished, and every other agent's "finished
its turn and is waiting for your next message") is resolved by the next prompt, SessionEnd,
/clear, /resume or the lease reaper. A session left idle in its terminal while the person
works in another sends none of those, so the card has a short expiry of its own
(NEEDS_YOU_FINISHED_EXPIRY_HOURS, default 3) instead of the 48 h of every other agent card.

Then each way the person leaves a session behind, and what resolves its finished card: /clear,
/resume, a new session in the same terminal, and a new session in the same Orca pane (the
term_<uuid> key). Temporary HOME, a fake CLI that records its argv (the real CLI and a real
hub for the reaper); the crontab is never touched.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

from hook_case import HookCase, opt
from support import CLI, ROOT, HubTestCase, request, wait_until

BASH = shutil.which("bash") or "/bin/bash"
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
HANDLE = "term_0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
IDLE = {"hook_event_name": "Notification", "notification_type": "idle_prompt"}


class Base(HookCase):
    SESSION = "sess-old-1111"

    def hook(self, mode, data=None, session=None, agent=None, **env):
        payload = {"session_id": session or self.SESSION, "cwd": self.cwd}
        payload.update(data or {})
        return self.run_hook([mode] + ([agent] if agent else []), payload, **env)

    def adds(self):
        return [c for c in self.calls() if c[0] == "add"]

    def resolved(self):
        return [c[c.index("--key") + 1] for c in self.calls() if c[0] == "resolve"]

    def other_claude(self):
        """A stand-in for another Claude process (the hook takes its parent as the session's
        process; NY_HOOK_PPID names it): alive until killed."""
        p = subprocess.Popen(["sleep", "120"])
        self.addCleanup(lambda: (p.kill(), p.wait()))
        return p


class FinishedExpiryTests(Base):
    def expiry(self, argv):
        return float(opt(argv, "--expires-in"))

    def test_finished_card_expires_in_three_hours(self):
        self.hook("notify", IDLE)
        argv = self.adds()[-1]
        self.assertEqual(opt(argv, "--event"), "finished")
        self.assertTrue(opt(argv, "--title").startswith("Claude finished"), argv)
        self.assertEqual(self.expiry(argv), 3)

    def test_the_old_waiting_card_too(self):
        self.hook("notify", IDLE, NEEDS_YOU_TURN_TEXT="0")
        argv = self.adds()[-1]
        self.assertEqual(opt(argv, "--event"), "finished")
        self.assertEqual(self.expiry(argv), 3)

    def test_cards_that_really_wait_keep_48_hours(self):
        self.hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                             "tool_input": {"command": "make deploy"}})
        self.hook("notify", {"hook_event_name": "StopFailure", "error": "rate_limit"})
        self.hook("notify", {"hook_event_name": "Notification", "notification_type": "elicitation_dialog"})
        # a turn that ended on a question is a question
        self.hook("stop", {"hook_event_name": "Stop", "last_assistant_message": "Shall I merge it?",
                           "transcript_path": ""}, NEEDS_YOU_CONTEXT_ALERT_PCT="0")
        self.hook("notify", IDLE)
        adds = self.adds()
        self.assertEqual([opt(a, "--event") for a in adds], ["approval", "failed", "question", "question"])
        self.assertEqual([self.expiry(a) for a in adds], [48, 48, 48, 48])

    def test_settings(self):
        cases = [({"NEEDS_YOU_FINISHED_EXPIRY_HOURS": "0.5"}, 0.5),
                 ({"NEEDS_YOU_FINISHED_EXPIRY_HOURS": "0"}, 48),  # 0: the general expiry
                 ({"NEEDS_YOU_FINISHED_EXPIRY_HOURS": "nope"}, 3),
                 ({"NEEDS_YOU_FINISHED_EXPIRY_HOURS": "nan"}, 3),
                 ({"NEEDS_YOU_AGENT_EXPIRY_HOURS": "2"}, 2),  # never longer than that
                 ({"NEEDS_YOU_AGENT_EXPIRY_HOURS": "0"}, 3),  # cards never expire, but these do
                 ({"NEEDS_YOU_AGENT_EXPIRY_HOURS": "12", "NEEDS_YOU_FINISHED_EXPIRY_HOURS": "6"}, 6)]
        for env, want in cases:
            self.hook("notify", IDLE, **env)
            self.assertEqual(self.expiry(self.adds()[-1]), want, env)
        self.hook("notify", IDLE, NEEDS_YOU_AGENT_EXPIRY_HOURS="0", NEEDS_YOU_FINISHED_EXPIRY_HOURS="0")
        self.assertNotIn("--expires-in", self.adds()[-1])

    def test_read_from_the_env_file(self):
        conf = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(conf)
        with open(os.path.join(conf, "env"), "w") as fh:
            fh.write("NEEDS_YOU_FINISHED_EXPIRY_HOURS=1.5\n")
        self.hook("notify", IDLE)
        self.assertEqual(self.expiry(self.adds()[-1]), 1.5)

    def test_every_agents_turn_card(self):
        # Codex's Stop: "Codex finished: ..." (or "Codex is waiting for you"), event finished
        self.hook("notify", {"hook_event_name": "Stop", "last_assistant_message": "Done.",
                             "transcript_path": None}, agent="codex")
        argv = self.adds()[-1]
        self.assertEqual(opt(argv, "--agent"), "codex")
        self.assertEqual(opt(argv, "--event"), "finished")
        self.assertEqual(self.expiry(argv), 3)
        # its approval keeps the long expiry
        self.hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                             "tool_input": {"command": "ls"}}, agent="codex")
        self.assertEqual(self.expiry(self.adds()[-1]), 48)


class LeftBehindTests(Base):
    """Each way a session is left behind resolves the finished card it posted."""

    def test_clear(self):
        # /clear: SessionEnd (reason clear) for the old session, SessionStart (source clear)
        # for the new one, in the same Claude process. Each resolves the old card alone.
        self.hook("notify", IDLE)
        old = opt(self.adds()[-1], "--key")
        self.hook("end", {"hook_event_name": "SessionEnd", "reason": "clear"})
        self.assertEqual(self.resolved(), [old])
        self.hook("notify", IDLE)
        self.hook("start", {"hook_event_name": "SessionStart", "source": "clear"}, session="sess-new-2222")
        self.assertEqual(self.resolved(), [old, old])
        self.assertEqual([n for n in os.listdir(self.state) if not n.startswith(".")], [])

    def test_resume(self):
        # /resume in a running Claude: SessionStart (source resume) with the resumed session's
        # id, in the same process: the card of the session it left goes.
        self.hook("notify", IDLE)
        old = opt(self.adds()[-1], "--key")
        self.hook("start", {"hook_event_name": "SessionStart", "source": "resume"}, session="sess-resumed-3333")
        self.assertEqual(self.resolved(), [old])

    def test_resume_leaves_other_sessions_alone(self):
        other = self.other_claude()
        self.hook("notify", IDLE, session="sess-elsewhere", NY_HOOK_PPID=str(other.pid))
        self.hook("start", {"hook_event_name": "SessionStart", "source": "resume"}, session="sess-resumed-3333")
        self.hook("start", {"hook_event_name": "SessionStart", "source": "startup"}, session="sess-new-4444")
        self.assertEqual(self.resolved(), [])

    def test_clear_in_orca(self):
        self.hook("notify", IDLE, ORCA_TERMINAL_HANDLE=HANDLE)
        key = opt(self.adds()[-1], "--key")
        self.assertTrue(key.endswith(":" + HANDLE))
        self.hook("end", {"hook_event_name": "SessionEnd", "reason": "clear"}, ORCA_TERMINAL_HANDLE=HANDLE)
        self.hook("start", {"hook_event_name": "SessionStart", "source": "clear"}, session="sess-new-2222",
                  ORCA_TERMINAL_HANDLE=HANDLE)
        self.assertEqual(self.resolved(), [key])

    def test_resume_in_orca(self):
        self.hook("notify", IDLE, ORCA_TERMINAL_HANDLE=HANDLE)
        key = opt(self.adds()[-1], "--key")
        self.hook("start", {"hook_event_name": "SessionStart", "source": "resume"}, session="sess-resumed-3333",
                  ORCA_TERMINAL_HANDLE=HANDLE)
        self.assertEqual(self.resolved(), [key])

    def test_new_session_in_the_same_orca_pane(self):
        # The earlier Claude in this Orca pane posted its finished card and was then killed
        # (no SessionEnd), or is still there, suspended. A new `claude` in the pane starts:
        # the pane's card (term_<uuid> key) was about the earlier session, which is over.
        for kill in (True, False):
            before = len(self.resolved())
            old = self.other_claude()
            self.hook("notify", IDLE, ORCA_TERMINAL_HANDLE=HANDLE, NY_HOOK_PPID=str(old.pid))
            key = opt(self.adds()[-1], "--key")
            self.assertEqual(self.read_marker(HANDLE)["pid"], str(old.pid))
            if kill:
                old.kill()
                old.wait()
            self.hook("start", {"hook_event_name": "SessionStart", "source": "startup"}, session="sess-new-5555",
                      ORCA_TERMINAL_HANDLE=HANDLE)
            self.assertEqual(self.resolved()[before:], [key], kill)
            self.assertFalse(os.path.exists(self.marker(HANDLE)))

    def test_startup_keeps_the_panes_card_of_this_process(self):
        # (a SessionStart of the process that posted it, as after compaction, isn't a new session)
        self.hook("notify", IDLE, ORCA_TERMINAL_HANDLE=HANDLE)
        self.hook("start", {"hook_event_name": "SessionStart", "source": "startup"}, ORCA_TERMINAL_HANDLE=HANDLE)
        self.assertEqual(self.resolved(), [])
        self.assertTrue(os.path.exists(self.marker(HANDLE)))

    def test_new_session_in_the_same_orca_pane_with_codex(self):
        # Codex runs every session's hooks from one app-server daemon: its pid names no session,
        # so it never counts as another process here (no regression for Codex in Orca).
        self.hook("notify", {"hook_event_name": "Stop", "last_assistant_message": "Done.",
                             "transcript_path": None}, agent="codex", ORCA_TERMINAL_HANDLE=HANDLE)
        self.hook("start", {"hook_event_name": "SessionStart", "source": "startup"}, agent="codex",
                  session="019b-new", ORCA_TERMINAL_HANDLE=HANDLE)
        self.assertEqual(self.resolved(), [])


# Runs the hook as a grandchild (via sh -c), as Claude Code does, says "ready", then waits.
STAND_IN = """
import subprocess, sys, time
subprocess.run(["/bin/sh", "-c", '"$0" ' + sys.argv[3], sys.argv[1]], input=sys.argv[2].encode(),
               timeout=30)
print("ready", flush=True)
time.sleep(120)
"""


class SameTerminalTests(HubTestCase):
    """A new session in the same (plain) terminal: the old Claude exited there. With SessionEnd,
    that resolves the card; without it (killed, the terminal's job control), the 5-minute
    `needs-you flush` finds the old process gone. Real hub, real CLI."""

    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        self.cwd = os.path.join(self.home, "src", "my-repo")
        os.makedirs(self.cwd)
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)

    def env(self, **extra):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
               "NEEDS_YOU_URL": self.hub.url, "NEEDS_YOU_TOKEN": self.sender, "NEEDS_YOU_TIMEOUT": "2",
               "NEEDS_YOU_HOST": "testbox", "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_BIN": CLI}
        env.update(extra)
        return env

    def claude(self, session, mode="notify", data=None):
        payload = {"session_id": session, "cwd": self.cwd}
        payload.update(IDLE if data is None else data)
        proc = subprocess.Popen([sys.executable, "-c", STAND_IN, HOOK, json.dumps(payload), mode],
                                env=self.env(), stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: (proc.kill(), proc.wait(), proc.stdout.close()))
        self.assertEqual(proc.stdout.readline().strip(), "ready")
        return proc

    def items(self):
        items = request("GET", self.hub.url + "/v1/items?status=all", self.reader)[1]["items"]
        return {i["key"].rsplit(":", 1)[-1]: i for i in items}

    def test_old_session_killed_then_a_new_one(self):
        old = self.claude("sess-old")
        item = self.items()["sess-old"]
        self.assertEqual((item["status"], item["source"].get("event")), ("open", "finished"))
        self.assertIsNotNone(item["expires_at"])
        old.kill()
        old.wait()
        self.claude("sess-new", "start", {"hook_event_name": "SessionStart", "source": "startup"})
        r = subprocess.run([sys.executable, CLI, "flush"], env=self.env(), capture_output=True, text=True,
                           timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.items()["sess-old"]["status"], "resolved")

    def test_old_session_exited(self):
        self.claude("sess-old")
        self.claude("sess-old", "end", {"hook_event_name": "SessionEnd", "reason": "prompt_input_exit"})
        self.assertTrue(wait_until(lambda: self.items()["sess-old"]["status"] == "resolved"))


if __name__ == "__main__":
    import unittest
    unittest.main()
