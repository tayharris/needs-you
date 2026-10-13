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

import os
import subprocess

from hook_case import HookCase, opt

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


if __name__ == "__main__":
    import unittest
    unittest.main()
