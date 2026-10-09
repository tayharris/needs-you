"""A "<agent> is waiting for you" card must go when the person answers in the terminal.

The hook posts a card on one event (Notification, PermissionRequest, a turn's end) and
resolves it on another (UserPromptSubmit, PostToolUse, Stop), each in its own process. The
resolve finds the card through the marker the post leaves behind, so a reply that lands while
the post is still under way (a slow hub, a hub that hangs, Kimi's or Cursor's wait before a
turn-end card) used to find no marker: the card arrived after the reply and stayed. Seen live
with Claude Code 2.1.294 and a hub that answered after 3 s: idle_prompt at .242, the reply's
UserPromptSubmit at .352 and its Stop at .410, the card posted 3 s later and left open.

Also here: a post the CLI didn't finish (killed at the hook's 15 s limit, its request left in
the outbox) still leaves a marker, so the reply resolves it; and the hook's own card is never
taken for "the agent's own item" (Claude Code gives hooks CLAUDECODE and
CLAUDE_CODE_SESSION_ID, which the CLI reads to note an agent's items), which would hold back
the next waiting card. Temp HOME, fake or offline CLI: nothing real is touched.
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

from support import CLI, ROOT, wait_until

BASH = shutil.which("bash") or "/bin/bash"
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
SESSION = "sess-1234-abcd"

# Logs its argv. `add` touches $FAKE_ADD_STARTED, sleeps $FAKE_ADD_SLEEP seconds (or, with
# $FAKE_ADD_UNTIL, until that file exists: no race on a slow machine) and exits $FAKE_ADD_RC; with FAKE_ENV_LOG it also records which session variables it was given.
FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys, time
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:2] == ["add"]:
    if os.environ.get("FAKE_ENV_LOG"):
        names = ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CODEX_SESSION_ID", "CODEX_THREAD_ID",
                 "NEEDS_YOU_AGENT_SESSION", "GEMINI_CLI", "ORCA_TERMINAL_HANDLE", "TERM")
        with open(os.environ["FAKE_ENV_LOG"], "a") as fh:
            fh.write(json.dumps(sorted(n for n in names if n in os.environ)) + "\\n")
    if os.environ.get("FAKE_ADD_STARTED"):
        open(os.environ["FAKE_ADD_STARTED"], "w").close()
    time.sleep(float(os.environ.get("FAKE_ADD_SLEEP") or 0))
    until = os.environ.get("FAKE_ADD_UNTIL")
    deadline = time.time() + 30
    while until and not os.path.exists(until) and time.time() < deadline:
        time.sleep(0.05)
    sys.exit(int(os.environ.get("FAKE_ADD_RC") or 0))
"""

QUESTION = {"questions": [{"question": "Which database?", "header": "DB", "multiSelect": False,
                           "options": [{"label": "Postgres", "description": "relational"},
                                       {"label": "SQLite", "description": "a file"}]}]}


class WaitingResolve(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-waitres-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.cli = os.path.join(self.home, "fake-needs-you")
        with open(self.cli, "w") as fh:
            fh.write(FAKE_CLI)
        os.chmod(self.cli, 0o755)
        self.log = os.path.join(self.home, "calls.log")
        self.started = os.path.join(self.home, "add-started")
        self.state = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks")
        self.cwd = os.path.join(self.home, "src", "my-repo")
        os.makedirs(self.cwd)
        self.procs = []
        self.addCleanup(self._reap)

    def _reap(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
            p.wait()

    def env(self, **extra):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_BIN": self.cli, "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1",
               "NEEDS_YOU_HOOK_PLATFORM": "linux", "NEEDS_YOU_HOOK_LOG": os.path.join(self.home, "hook.log"),
               "NY_TURN_WAIT": "0", "NY_KIMI_TURN_WAIT": "0", "NY_COPILOT_TURN_WAIT": "0"}
        env.update(extra)
        return {k: v for k, v in env.items() if v is not None}

    def payload(self, data):
        p = {"session_id": SESSION, "cwd": self.cwd}
        p.update(data)
        return json.dumps(p)

    def start(self, args, data, **extra):
        """The posting hook, in the background (as Claude Code runs an async hook)."""
        p = subprocess.Popen([BASH, HOOK] + list(args), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env=self.env(**extra), cwd=self.cwd)
        self.procs.append(p)
        p.stdin.write(self.payload(data).encode())
        p.stdin.close()
        return p

    def run_hook(self, args, data, **extra):
        r = subprocess.run([BASH, HOOK] + list(args), input=self.payload(data), env=self.env(**extra),
                           capture_output=True, text=True, timeout=30, cwd=self.cwd)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def finish(self, p):
        p.wait(timeout=30)
        self.assertEqual(p.returncode, 0)

    def calls(self):
        try:
            with open(self.log) as fh:
                return [json.loads(l) for l in fh]
        except OSError:
            return []

    def in_flight(self):
        """Wait until the posting hook's `needs-you add` is running."""
        self.assertTrue(wait_until(lambda: os.path.exists(self.started), timeout=15), self.calls())

    def marker(self, name=SESSION):
        return os.path.join(self.state, name)

    def key(self):
        add = [c for c in self.calls() if c[0] == "add"][0]
        return add[add.index("--key") + 1]

    def assert_resolved_after_add(self):
        calls = self.calls()
        self.assertEqual([c[0] for c in calls], ["add", "resolve"], calls)
        self.assertEqual(calls[1], ["resolve", "--key", self.key()])
        self.assertFalse(os.path.exists(self.marker()), "a marker is left for a card already resolved")

    # ---------------------------------------------------------------- the race

    def test_reply_while_the_idle_card_is_posting_resolves_it(self):
        p = self.start(["notify"], {"hook_event_name": "Notification", "notification_type": "idle_prompt",
                                    "message": "Claude is waiting for your input"},
                       FAKE_ADD_SLEEP="1.5", FAKE_ADD_STARTED=self.started)
        self.in_flight()
        self.run_hook(["resolve"], {"hook_event_name": "UserPromptSubmit", "prompt": "go on"})
        self.finish(p)
        self.assert_resolved_after_add()

    def test_the_replys_stop_while_posting_resolves_it_too(self):
        p = self.start(["notify"], {"hook_event_name": "Notification", "notification_type": "idle_prompt"},
                       FAKE_ADD_SLEEP="1.5", FAKE_ADD_STARTED=self.started)
        self.in_flight()
        self.run_hook(["stop"], {"hook_event_name": "Stop"}, NEEDS_YOU_CONTEXT_ALERT_PCT="0")
        self.finish(p)
        self.assert_resolved_after_add()

    def test_permission_answered_while_its_card_is_posting(self):
        p = self.start(["notify"], {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                    "tool_input": {"command": "make deploy"}},
                       FAKE_ADD_SLEEP="1.5", FAKE_ADD_STARTED=self.started)
        self.in_flight()
        self.run_hook(["resolve"], {"hook_event_name": "PostToolUse", "tool_name": "Bash",
                                    "tool_input": {"command": "make deploy"}})
        self.finish(p)
        self.assert_resolved_after_add()

    def test_question_answered_in_the_terminal_while_its_card_is_posting(self):
        # The `ask` entry posts the card, then waits for a click. Answered in the terminal
        # meanwhile: resolve the card and don't wait (nothing would end the wait but Stop).
        p = self.start(["ask"], {"hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
                                 "tool_input": QUESTION},
                       FAKE_ADD_UNTIL=os.path.join(self.home, "add-may-end"), FAKE_ADD_STARTED=self.started)
        self.in_flight()
        self.run_hook(["resolve"], {"hook_event_name": "PostToolUse", "tool_name": "AskUserQuestion",
                                    "tool_input": dict(QUESTION, answers={"Which database?": "SQLite"})})
        open(os.path.join(self.home, "add-may-end"), "w").close()  # the add ends only after the answer
        self.finish(p)
        self.assertEqual(p.stdout.read(), b"")  # no decision printed
        self.assert_resolved_after_add()

    def test_failure_card_outlives_a_stop_while_posting(self):
        # A StopFailure card stays until the next prompt, as before.
        p = self.start(["notify"], {"hook_event_name": "StopFailure", "error_type": "rate_limit"},
                       FAKE_ADD_SLEEP="1.5", FAKE_ADD_STARTED=self.started)
        self.in_flight()
        self.run_hook(["stop"], {"hook_event_name": "Stop"}, NEEDS_YOU_CONTEXT_ALERT_PCT="0")
        self.finish(p)
        self.assertEqual([c[0] for c in self.calls()], ["add"])
        with open(self.marker()) as fh:
            self.assertIn("kind=failure\n", fh.read())
        self.run_hook(["resolve"], {"hook_event_name": "UserPromptSubmit", "prompt": "retry"})
        self.assertEqual([c[0] for c in self.calls()], ["add", "resolve"])

    def test_two_cards_posting_at_once_both_stand(self):
        # A PermissionRequest and the permission_prompt notification that follows it run
        # side by side; neither is taken for a reply.
        p1 = self.start(["notify"], {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                     "tool_input": {"command": "make"}},
                        FAKE_ADD_SLEEP="1", FAKE_ADD_STARTED=self.started)
        self.in_flight()
        p2 = self.start(["notify"], {"hook_event_name": "Notification", "notification_type": "elicitation_dialog"},
                        FAKE_ADD_SLEEP="0.2")
        self.finish(p1)
        self.finish(p2)
        self.assertEqual([c[0] for c in self.calls()], ["add", "add"])
        self.assertTrue(os.path.exists(self.marker()))

    def test_no_reply_leaves_the_card(self):
        p = self.start(["notify"], {"hook_event_name": "Notification", "notification_type": "idle_prompt"},
                       FAKE_ADD_SLEEP="0.5")
        self.finish(p)
        self.assertEqual([c[0] for c in self.calls()], ["add"])
        self.assertTrue(os.path.exists(self.marker()))
        # and nothing of the in-flight bookkeeping is left in the state directory
        self.assertEqual(sorted(n for n in os.listdir(self.state) if n.startswith(".pending")), [])

    def test_codex_prompt_while_the_turn_card_is_posting(self):
        p = self.start(["notify", "codex"], {"hook_event_name": "Stop", "turn_id": "t1"},
                       FAKE_ADD_SLEEP="1.5", FAKE_ADD_STARTED=self.started)
        self.in_flight()
        self.run_hook(["resolve", "codex"], {"hook_event_name": "UserPromptSubmit", "prompt": "next"})
        self.finish(p)
        self.assertTrue(wait_until(lambda: len(self.calls()) >= 2, timeout=10), self.calls())
        self.assert_resolved_after_add()

    # ---------------------------------------------------------------- a post that didn't finish

    def test_post_cut_short_still_leaves_a_marker_for_the_reply(self):
        # The CLI killed at the hook's limit (its request may already be on the hub or in the
        # outbox, to go out later): the reply must still resolve the key.
        p = self.start(["notify"], {"hook_event_name": "Notification", "notification_type": "idle_prompt"},
                       FAKE_ADD_RC="1")
        self.finish(p)
        self.assertTrue(os.path.exists(self.marker()))
        self.run_hook(["resolve"], {"hook_event_name": "UserPromptSubmit", "prompt": "go on"})
        self.assertEqual([c[0] for c in self.calls()], ["add", "resolve"])

    def test_a_card_with_nothing_to_post_leaves_no_marker(self):
        p = self.start(["notify"], {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                    "requires_user_approval": False})
        self.finish(p)
        self.assertEqual(self.calls(), [])
        self.assertFalse(os.path.exists(self.marker()))

    # ---------------------------------------------------------------- the hook's own card

    def test_hooks_card_is_not_noted_as_the_agents_own_item(self):
        env_log = os.path.join(self.home, "env.log")
        in_claude = {"CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": SESSION, "ORCA_TERMINAL_HANDLE": "term_0123abcd",
                     "CODEX_SESSION_ID": "c", "NEEDS_YOU_AGENT_SESSION": "s", "GEMINI_CLI": "1", "TERM": "dumb",
                     "FAKE_ENV_LOG": env_log}
        self.finish(self.start(["notify"], {"hook_event_name": "Notification", "notification_type": "idle_prompt"},
                               **in_claude))
        with open(env_log) as fh:
            self.assertEqual(json.loads(fh.readline()), [])

    def test_with_the_real_cli_the_next_waiting_card_still_posts(self):
        # Claude Code gives its hooks CLAUDECODE and CLAUDE_CODE_SESSION_ID. The real CLI (hub
        # down: queued) must not note the hook's card as the agent's own blocker for the session.
        real = {"NEEDS_YOU_BIN": CLI, "NEEDS_YOU_URLS": "http://127.0.0.1:9", "NEEDS_YOU_TOKEN": "t",
                "NEEDS_YOU_TIMEOUT": "1", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": SESSION}
        if not os.access(CLI, os.X_OK):
            self.skipTest("cli/needs-you is not executable here")
        self.finish(self.start(["notify"], {"hook_event_name": "Notification", "notification_type": "idle_prompt"},
                               **real))
        items = os.path.join(self.home, ".local", "state", "needs-you", "session-items", SESSION)
        self.assertEqual(os.listdir(items) if os.path.isdir(items) else [], [])
        # so the card for the next wait isn't skipped as "the agent's own item is open"
        before = len(self.calls())
        self.finish(self.start(["notify"], {"hook_event_name": "Notification", "notification_type": "idle_prompt"},
                               CLAUDECODE="1", CLAUDE_CODE_SESSION_ID=SESSION))
        self.assertEqual(len(self.calls()), before + 1)

    def test_context_card_does_not_hold_back_waiting_cards(self):
        # The low-priority "context is 80% full" card stays open for the rest of a long
        # session. Noted as the agent's own item, it held back every waiting card after it.
        real = {"NEEDS_YOU_BIN": CLI, "NEEDS_YOU_URLS": "http://127.0.0.1:9", "NEEDS_YOU_TOKEN": "t",
                "NEEDS_YOU_TIMEOUT": "1", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": SESSION}
        if not os.access(CLI, os.X_OK):
            self.skipTest("cli/needs-you is not executable here")
        transcript = os.path.join(self.home, "t.jsonl")
        with open(transcript, "w") as fh:
            fh.write(json.dumps({"type": "assistant", "message": {
                "model": "claude-x", "usage": {"input_tokens": 180000}}}) + "\n")
        self.run_hook(["stop"], {"hook_event_name": "Stop", "transcript_path": transcript}, **real)
        self.assertTrue(os.path.exists(self.marker(SESSION + ".context")))
        before = len(self.calls())
        self.finish(self.start(["notify"], {"hook_event_name": "Notification", "notification_type": "idle_prompt"},
                               CLAUDECODE="1", CLAUDE_CODE_SESSION_ID=SESSION))
        self.assertEqual(len(self.calls()), before + 1)


if __name__ == "__main__":
    unittest.main()
