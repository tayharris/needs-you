"""The hook's `--event` (source.event, docs/API.md): what kind of card each agent event is, so
the person's alert rules on the Mac can match it, and the fallback for a CLI that predates
the flag (the card still posts, without it)."""
from __future__ import annotations

import json
import os

from hook_case import HookCase, has_opt, opt

SID = "sess-1234-abcd"


class ClaudeEvents(HookCase):
    AGENT = "claude"

    def notify(self, data, args=("notify",), **extra):
        payload = {"session_id": SID, "cwd": self.cwd}
        payload.update(data)
        n = len(self.calls())
        self.run_hook(list(args), payload, **extra)
        calls = self.calls()
        return calls[-1] if len(calls) > n else None

    def event_of(self, data, **extra):
        argv = self.notify(data, **extra)
        self.assertIsNotNone(argv, data)
        self.assertEqual(argv[0], "add")
        return opt(argv, "--event") if has_opt(argv, "--event") else None

    def permission(self, tool, tool_input):
        return {"hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": tool_input}

    def note(self, ntype):
        return {"hook_event_name": "Notification", "notification_type": ntype, "message": "m"}

    def test_each_card_names_its_event(self):
        cases = [
            ("run a command", self.permission("Bash", {"command": "ls"}), "approval"),
            ("edit a file", self.permission("Edit", {"file_path": "/x/a.py"}), "approval"),
            ("plan", self.permission("ExitPlanMode", {"plan": "1. do it"}), "approval"),
            ("other tool", self.permission("WebFetch", {"url": "https://example.com"}), "approval"),
            ("question", self.permission("AskUserQuestion", {"questions": [{"question": "Ship it?"}]}), "question"),
            ("stop failure", {"hook_event_name": "StopFailure", "error_type": "rate_limit"}, "failed"),
            ("permission prompt", self.note("permission_prompt"), "approval"),
            ("idle", self.note("idle_prompt"), "finished"),
            ("elicitation", self.note("elicitation_dialog"), "question"),
            ("sign in", self.note("elicitation_url_dialog"), "failed"),
            ("needs input", self.note("agent_needs_input"), "question"),
            ("usage limit", self.note("quota_auto_resume_disabled"), "failed"),
            ("unknown notification", self.note("something_new"), None),
        ]
        for name, data, want in cases:
            with self.subTest(name):
                # a fresh marker each time: a permission card would hold back the prompt notifications
                self.run_hook(["resolve"], {"session_id": SID, "cwd": self.cwd, "hook_event_name": "UserPromptSubmit"})
                self.assertEqual(self.event_of(data), want)

    def test_finished_turn_that_ends_on_a_question_is_a_question(self):
        transcript = os.path.join(self.home, "t.jsonl")
        with open(transcript, "w") as fh:
            fh.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "text", "text": "I can do either. Should I keep the old API?"}]}}) + "\n")
        argv = self.notify(dict(self.note("idle_prompt"), transcript_path=transcript))
        self.assertTrue(opt(argv, "--title").startswith("Claude asks"), opt(argv, "--title"))
        self.assertEqual(opt(argv, "--event"), "question")

    def old_cli(self):
        """A CLI from before --event: argparse refuses the flag (exit 2), logs every call."""
        path = os.path.join(self.home, "old-needs-you")
        with open(path, "w") as fh:
            fh.write("#!/usr/bin/env python3\nimport json, os, sys\n"
                     "with open(os.environ['FAKE_CLI_LOG'], 'a') as fh:\n"
                     "    fh.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                     "if '--event' in sys.argv:\n"
                     "    sys.stderr.write('needs-you add: error: unrecognized arguments: --event approval\\n')\n"
                     "    sys.exit(2)\n")
        os.chmod(path, 0o755)
        return path

    def test_an_older_cli_still_gets_the_card(self):
        self.notify(self.permission("Bash", {"command": "make deploy"}), NEEDS_YOU_BIN=self.old_cli())
        first, second = self.calls()[-2:]
        self.assertEqual(opt(first, "--event"), "approval")
        self.assertFalse(has_opt(second, "--event"))
        self.assertEqual(first[:1] + [a for a in first[1:] if a not in ("--event", "approval")], second)
        self.wait_marker(SID)
        self.assertEqual(self.read_marker(SID)["kind"], "permission")

    def test_an_older_cli_and_a_question_it_refuses(self):
        """Both refusals at once: --event and --question-json (a CLI older than both)."""
        path = os.path.join(self.home, "older-needs-you")
        with open(path, "w") as fh:
            fh.write("#!/usr/bin/env python3\nimport json, os, sys\n"
                     "with open(os.environ['FAKE_CLI_LOG'], 'a') as fh:\n"
                     "    fh.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                     "if '--event' in sys.argv:\n"
                     "    sys.stderr.write('needs-you add: error: unrecognized arguments: --event question\\n')\n"
                     "    sys.exit(2)\n"
                     "sys.exit(2 if any(a.startswith('--question-json') for a in sys.argv) else 0)\n")
        os.chmod(path, 0o755)
        self.notify(self.permission("AskUserQuestion", {"questions": [{
            "question": "Which?", "options": [{"label": "A"}, {"label": "B"}]}]}), NEEDS_YOU_BIN=path)
        last = self.calls()[-1]
        self.assertFalse(has_opt(last, "--event"))
        self.assertFalse(has_opt(last, "--question-json"))
        self.assertTrue(has_opt(last, "--steps-json"))
        self.wait_marker(SID)

    def test_a_hub_refusal_is_not_taken_for_an_old_cli(self):
        """A hub that refuses every post (exit 2, no usage error): the hook gives up as before,
        trying the same posts with the event (no extra retries)."""
        path = os.path.join(self.home, "refusing-needs-you")
        with open(path, "w") as fh:
            fh.write("#!/usr/bin/env python3\nimport json, os, sys\n"
                     "with open(os.environ['FAKE_CLI_LOG'], 'a') as fh:\n"
                     "    fh.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                     "sys.exit(2)\n")
        os.chmod(path, 0o755)
        self.notify(self.permission("Bash", {"command": "ls"}), NEEDS_YOU_BIN=path)
        self.assertTrue(self.calls())
        self.assertTrue(all(opt(c, "--event") == "approval" for c in self.calls()))
        self.assertFalse(os.path.exists(self.marker(SID)))


class OtherAgentEvents(HookCase):
    AGENT = "multi"

    def event(self, agent, payload, **extra):
        n = len(self.calls())
        payload = dict({"session_id": SID, "cwd": self.cwd}, **payload)
        self.run_hook(["notify", agent], payload, **extra)
        argv = self.wait_calls(n + 1)[-1]
        self.assertEqual(argv[0], "add")
        self.assertTrue(opt(argv, "--agent").startswith(agent), argv)
        return opt(argv, "--event") if has_opt(argv, "--event") else None

    def test_codex(self):
        self.assertEqual(self.event("codex", {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                              "tool_input": {"command": "ls"}}), "approval")
        self.assertEqual(self.event("codex", {"hook_event_name": "PreToolUse", "tool_name": "request_user_input",
                                              "tool_input": {"questions": [{"question": "Which?"}]}}), "question")
        self.assertEqual(self.event("codex", {"hook_event_name": "Stop",
                                              "last_assistant_message": "All done."}), "finished")
        self.assertEqual(self.event("codex", {"hook_event_name": "Stop",
                                              "last_assistant_message": "Want me to push it?"}), "question")

    def test_kimi_and_cursor(self):
        self.assertEqual(self.event("kimi", {"hook_event_name": "StopFailure", "error_message": "boom"}), "failed")
        self.assertEqual(self.event("cursor", {"hook_event_name": "stop", "status": "error",
                                               "conversation_id": "conv-1"}), "failed")
