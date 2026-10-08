"""Cursor integration (integrations/cursor/): the shared hook in `cursor` mode, and the Claude
Code hooks stepping aside when Cursor runs them.

No live Cursor run: Cursor needs a login and has no custom model endpoint to stub. The
payloads are replayed from Cursor's hooks reference (cursor.com/docs/hooks, 2026-10): every
hook gets conversation_id, generation_id, model, hook_event_name, cursor_version,
workspace_roots, user_email and transcript_path; stop adds status and loop_count;
sessionEnd adds session_id (= conversation_id) and reason. Cursor reads a hook's stdout as
its answer, so the hook prints exactly `{"continue":true}` on beforeSubmitPrompt and `{}`
elsewhere, and does its work in the background.
"""
from __future__ import annotations

import json
import os
import time

from hook_case import SECRET, HookCase, opt

CONV = "8e1f4d2c-6b7a-4c39-9a51-0f3e2d1c4b5a"
EMAIL = "someone@acme.example"


class CursorHook(HookCase):
    AGENT = "cursor"

    def payload(self, event, **extra):
        p = {"conversation_id": CONV, "generation_id": "gen-1", "model": "claude-sonnet",
             "hook_event_name": event, "cursor_version": "1.7.2", "workspace_roots": [self.cwd],
             "user_email": EMAIL, "transcript_path": None}
        p.update(extra)
        return p

    def hook(self, mode, payload, **extra):
        # Cursor runs user hooks from ~/.cursor, and names the project in the environment.
        extra.setdefault("CURSOR_PROJECT_DIR", self.cwd)
        extra.setdefault("CLAUDE_PROJECT_DIR", self.cwd)
        extra.setdefault("CURSOR_VERSION", "1.7.2")
        extra.setdefault("CURSOR_USER_EMAIL", EMAIL)
        return self.run_hook([mode, "cursor"], payload, cwd=self.home, **extra)

    def test_finished_card_and_stdout(self):
        r = self.hook("notify", self.payload("stop", status="completed", loop_count=0))
        self.assertEqual(r.stdout, "{}\n")
        argv = self.wait_calls(1)[-1]
        self.assertEqual(argv[0], "add")
        self.assertEqual(opt(argv, "--title"), "Cursor finished: my-repo")
        self.assertEqual(opt(argv, "--agent"), "cursor")
        self.assertEqual(opt(argv, "--project"), "my-repo")
        self.assertEqual(opt(argv, "--key").split(":")[-1], CONV)
        self.assertNotIn(EMAIL, json.dumps(self.calls()))
        self.wait_marker(CONV)
        # The lease names the process that ran the hook (Cursor; here this test).
        self.assertEqual(self.read_marker(CONV)["pid"], str(os.getpid()))

    def test_prompt_answers_continue_and_resolves(self):
        self.hook("notify", self.payload("stop", status="completed"))
        key = opt(self.wait_calls(1)[-1], "--key")
        self.wait_marker(CONV)
        r = self.hook("resolve", self.payload("beforeSubmitPrompt", prompt=SECRET, attachments=[]))
        self.assertEqual(r.stdout, '{"continue":true}\n')
        self.assertEqual(self.wait_calls(2)[-1], ["resolve", "--key", key])
        self.wait_marker(CONV, present=False)
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_prompt_is_never_blocked(self):
        # Not opted in, opted out, no session id, garbage input: Cursor still gets "continue".
        for extra, payload in (({"NEEDS_YOU_AGENT_ALERTS": ""}, self.payload("beforeSubmitPrompt")),
                               ({"NEEDS_YOU_AGENT_ALERTS": "0"}, self.payload("beforeSubmitPrompt")),
                               ({}, {"hook_event_name": "beforeSubmitPrompt"}),
                               ({}, "not json")):
            r = self.hook("resolve", payload, **extra)
            self.assertEqual(r.stdout, '{"continue":true}\n', extra)
        r = self.hook("notify", self.payload("stop", status="completed"), NEEDS_YOU_AGENT_ALERTS="")
        self.assertEqual(r.stdout, "{}\n")
        time.sleep(0.5)
        self.assertEqual(self.calls(), [])

    def test_error_aborted_and_turn_cards_off(self):
        self.hook("notify", self.payload("stop", status="aborted"))
        self.hook("notify", self.payload("stop", status="completed"), NEEDS_YOU_AGENT_TURN_CARDS="0")
        time.sleep(0.8)
        self.assertEqual(self.calls(), [])
        self.hook("notify", self.payload("stop", status="error"))
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"), "Cursor stopped on an error: my-repo")
        self.wait_marker(CONV)
        self.assertEqual(self.read_marker(CONV)["kind"], "failure")

    def test_session_end_resolves(self):
        self.hook("notify", self.payload("stop", status="completed"))
        key = opt(self.wait_calls(1)[-1], "--key")
        self.wait_marker(CONV)
        self.hook("end", self.payload("sessionEnd", session_id=CONV, reason="user_close", duration_ms=5,
                                      is_background_agent=False, final_status="completed"))
        self.assertEqual(self.wait_calls(2)[-1], ["resolve", "--key", key])

    def test_no_card_once_cursor_has_exited(self):
        # cursor-agent -p ends its turn and exits: nobody is waiting.
        self.hook("notify", self.payload("stop", status="completed"), NY_HOOK_PPID=self.gone_pid())
        time.sleep(0.8)
        self.assertEqual(self.calls(), [])

    def test_cursor_links_on_the_mac(self):
        self.hook("notify", self.payload("stop", status="completed"), NEEDS_YOU_HOOK_PLATFORM="darwin")
        argv = self.wait_calls(1)[-1]
        links = [argv[i + 1] for i, a in enumerate(argv) if a == "--link"]
        self.assertIn("Cursor=cursor://file" + self.cwd, links)
        self.assertFalse([l for l in links if l.startswith("VS Code=")], links)


class ClaudeHooksUnderCursor(HookCase):
    """Cursor also runs the Claude Code hooks in ~/.claude/settings.json (Stop, UserPromptSubmit,
    SessionStart, SessionEnd). With Cursor's payload they would clear the cursor hooks' card
    (same conversation id) and spawn work for nothing: they step aside."""
    AGENT = "claude-cursor"

    def test_claude_hooks_do_nothing_with_a_cursor_payload(self):
        os.makedirs(self.state)
        with open(os.path.join(self.state, CONV), "w") as fh:
            fh.write("key=agent:box:%s\nkind=notify\n" % CONV)
        payload = {"conversation_id": CONV, "session_id": CONV, "hook_event_name": "Stop",
                   "cursor_version": "1.7.2", "workspace_roots": [self.cwd], "status": "completed"}
        for mode in ("stop", "resolve", "start", "end"):
            r = self.run_hook([mode], payload, CURSOR_VERSION="1.7.2", CLAUDE_PROJECT_DIR=self.cwd)
            self.assertEqual(r.stdout, "")
        no_version = dict(payload)
        del no_version["cursor_version"]
        self.run_hook(["stop"], no_version, CLAUDE_PROJECT_DIR=self.cwd)
        time.sleep(0.5)
        self.assertEqual(self.calls(), [])
        self.assertTrue(os.path.exists(os.path.join(self.state, CONV)))

    def test_claude_code_itself_is_unaffected(self):
        os.makedirs(self.state)
        sid = "0b7d4c1e-claude"
        with open(os.path.join(self.state, sid), "w") as fh:
            fh.write("key=agent:box:%s\nkind=notify\n" % sid)
        # A Claude Code session started from Cursor's terminal: Cursor's variables may be in the
        # environment, but the payload is Claude's.
        self.run_hook(["resolve"], {"session_id": sid, "hook_event_name": "UserPromptSubmit", "prompt": "x"},
                      CURSOR_VERSION="1.7.2", TERM_PROGRAM="vscode")
        self.assertEqual(self.wait_calls(1)[-1], ["resolve", "--key", "agent:box:%s" % sid])


if __name__ == "__main__":
    import unittest
    unittest.main()
