"""The Claude Code hook beyond the plain Notification card: PermissionRequest titles
(never the tool input), StopFailure and usage-limit cards, automatic editor links,
the context-usage card, and SessionStart/SessionEnd cleanup.

The hook runs with a temporary HOME and a fake `needs-you` CLI that records its argv,
so nothing touches the real ~/.claude or ~/.config.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

from hook_case import choice_texts, fixture, has_opt, posted_item, step_texts
from support import CLI, ROOT, hubmod

BASH = shutil.which("bash") or "/bin/bash"
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
HOOKS_JSON = os.path.join(ROOT, "integrations", "claude-code", "hooks.json")

FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
"""

SECRET = "sk-test-SECRET-0123456789"


class HookHarness(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-hookev-")
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
               "NEEDS_YOU_HOOK_PLATFORM": "linux"}
        env.update(extra)
        env = {k: v for k, v in env.items() if v is not None}  # None: unset it
        payload = {"session_id": "sess-1234-abcd", "cwd": self.cwd}
        payload.update(data)
        r = subprocess.run([BASH, HOOK, mode], input=json.dumps(payload), env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        return r

    def calls(self):
        try:
            with open(self.log) as fh:
                return [json.loads(l) for l in fh]
        except OSError:
            return []

    def last(self):
        return self.calls()[-1]

    @staticmethod
    def opt(argv, name):
        for i, a in enumerate(argv):
            if a.startswith(name + "="):
                return a[len(name) + 1:]
            if a == name:
                return argv[i + 1]
        raise ValueError(name)

    @staticmethod
    def links(argv):
        return [argv[i + 1] for i, a in enumerate(argv) if a == "--link"]

    def marker(self, name="sess-1234-abcd"):
        with open(os.path.join(self.state, name)) as fh:
            return dict(l.rstrip("\n").split("=", 1) for l in fh)


class PermissionTests(HookHarness):
    def permission(self, tool, tool_input, **extra):
        self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": tool,
                                 "tool_input": tool_input, "permission_mode": "default"}, **extra)
        return self.last()

    def assert_clean(self, argv):
        text = json.dumps(argv)
        self.assertNotIn(SECRET, text)
        self.assertNotIn("Authorization", text)

    def test_plan_approval(self):
        argv = self.permission("ExitPlanMode", {"plan": "1. leak %s" % SECRET})
        self.assertEqual(self.opt(argv, "--title"), "Claude wants approval for a plan: my-repo")
        self.assertTrue(self.opt(argv, "--key").endswith(":sess-1234-abcd"))
        self.assertTrue(self.opt(argv, "--body").startswith("1. leak [redacted]\n\nApprove or reject it in Claude."))
        self.assert_clean(argv)
        self.assertEqual(self.marker()["kind"], "permission")
        # no plan text (an older Claude, or no plan file): the card still says what it is
        argv = self.permission("ExitPlanMode", {})
        self.assertTrue(self.opt(argv, "--body").startswith("Claude has a plan ready. Approve or reject it in Claude."))
        argv = self.permission("ExitPlanMode", {"plan": "1. leak %s" % SECRET}, NEEDS_YOU_AGENT_QUESTIONS="0")
        self.assertNotIn("leak", json.dumps(argv))

    def test_plan_from_the_captured_payload(self):
        data = fixture("claude-exit-plan-mode.json")
        data.update(session_id="sess-1234-abcd", cwd=self.cwd)
        self.run_hook("notify", data)
        argv = self.last()
        self.assertEqual(self.opt(argv, "--title"), "Claude wants approval for a plan: my-repo")
        body = self.opt(argv, "--body")
        lines = body.split("\n\n")[0].split("\n")
        self.assertEqual(lines[:3], ["**Add a cache layer**", "**Steps**", "1. Add `CacheClient` in `src/cache.ts`."])
        self.assertIn("const client = new CacheClient", body)  # the fence lines are gone, the code stays
        self.assertNotIn("```", body)
        self.assertEqual(len(lines), 13)  # 12 lines, then an ellipsis
        self.assertEqual(lines[-1], "\u2026")
        self.assertNotIn("ACME-123", body)
        self.assertNotIn("plans/", body)  # never the plan file's path
        posted_item(argv)

    def test_huge_plan_still_posts_a_clamped_card(self):
        # Over 200 KB: too big for one environment variable (about 128 KB on Linux), so the
        # hook hands the payload to its Python on a file descriptor instead.
        plan = "# Big plan\n\n" + "".join("%d. Step with some detail %s\n" % (i, "x" * 60) for i in range(4000))
        self.assertGreater(len(plan), 200 * 1024)
        argv = self.permission("ExitPlanMode", {"plan": plan})
        self.assertEqual(self.opt(argv, "--title"), "Claude wants approval for a plan: my-repo")
        body = self.opt(argv, "--body")
        self.assertTrue(body.startswith("**Big plan**\n0. Step with some detail"), body[:80])
        self.assertLessEqual(len(body), 2000)
        posted_item(argv)

    def test_question(self):
        argv = self.permission("AskUserQuestion", {"questions": [{"question": "Use %s?" % SECRET}]})
        self.assertEqual(self.opt(argv, "--title"), "Claude asks \u201cUse [redacted]?\u201d: my-repo")
        self.assert_clean(argv)
        self.assertEqual(self.marker()["kind"], "permission")
        argv = self.permission("AskUserQuestion", {"questions": [{"question": "Use %s?" % SECRET}]},
                               NEEDS_YOU_AGENT_QUESTIONS="0")
        self.assertEqual(self.opt(argv, "--title"), "Claude asked you a question: my-repo")
        self.assertNotIn("Use", self.opt(argv, "--body"))
        # nothing usable in it: the plain card
        argv = self.permission("AskUserQuestion", {"questions": "nope"})
        self.assertEqual(self.opt(argv, "--title"), "Claude asked you a question: my-repo")

    def test_question_from_the_captured_payload(self):
        data = fixture("claude-ask-user-question.json")
        data.update(session_id="sess-1234-abcd", cwd=self.cwd)
        self.run_hook("notify", data)
        argv = self.last()
        self.assertEqual(self.opt(argv, "--title"),
                         "Claude asks \u201cWhich database should we use?\u201d and 1 more: my-repo")
        self.assertTrue(self.opt(argv, "--body").startswith(
            "**Database** \u00b7 choose one\nWhich database should we use?\n"
            "- Postgres \u2014 Relational, robust\n- SQLite \u2014 Embedded, simple\n\n"
            "**Features** \u00b7 choose any\nWhich features?\n"
            "- Auth \u2014 Login\n- Search \u2014 Full text\n- Export \u2014 CSV\n\n"
            "Answer in Claude.\n\n`"), self.opt(argv, "--body"))
        q = posted_item(argv)["question"]
        self.assertNotIn("id", q)  # Claude's PermissionRequest has no tool_use_id
        self.assertEqual([(i["header"], i["multi_select"]) for i in q["items"]],
                         [("Database", False), ("Features", True)])
        self.assertFalse(has_opt(argv, "--steps-json"))  # the choices travel as the question
        self.assertEqual(choice_texts(argv), [
            "Database: Postgres \u2014 Relational, robust", "Database: SQLite \u2014 Embedded, simple",
            "Features: Auth \u2014 Login", "Features: Search \u2014 Full text", "Features: Export \u2014 CSV"])
        # the permission_prompt notification that follows ~6 s later keeps this card
        n = len(self.calls())
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "permission_prompt",
                                 "message": "Claude needs your permission"})
        self.assertEqual(len(self.calls()), n)

    def old_cli(self):
        """A fake CLI from before --question-json: it refuses the flag (argparse, exit 2)."""
        path = os.path.join(self.home, "old-needs-you")
        with open(path, "w") as fh:
            fh.write("#!/usr/bin/env python3\nimport json, os, sys\n"
                     "with open(os.environ['FAKE_CLI_LOG'], 'a') as fh:\n"
                     "    fh.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                     "sys.exit(2 if any(a.startswith('--question-json') for a in sys.argv) else 0)\n")
        os.chmod(path, 0o755)
        return path

    def test_old_cli_gets_the_choices_as_steps(self):
        data = fixture("claude-ask-user-question.json")
        data.update(session_id="sess-1234-abcd", cwd=self.cwd)
        self.run_hook("notify", data, NEEDS_YOU_BIN=self.old_cli())
        first, argv = self.calls()[-2:]
        self.assertTrue(has_opt(first, "--question-json"))
        self.assertFalse(has_opt(argv, "--question-json"))
        self.assertEqual(step_texts(argv), [
            "Database: Postgres \u2014 Relational, robust", "Database: SQLite \u2014 Embedded, simple",
            "Features: Auth \u2014 Login", "Features: Search \u2014 Full text", "Features: Export \u2014 CSV"])
        self.assertIn("Answer in Claude; the choices below are what it offered.", self.opt(argv, "--body"))
        self.assertNotIn("- Postgres", self.opt(argv, "--body"))
        self.assertEqual(self.marker()["kind"], "permission")

    def test_single_question_has_no_header_prefix(self):
        argv = self.permission("AskUserQuestion", {"questions": [{
            "question": "Ship it?", "header": "Ship", "multiSelect": False,
            "options": [{"label": "Yes", "description": "Now"}, {"label": "No", "description": ""}]}]})
        self.assertEqual(self.opt(argv, "--title"), "Claude asks \u201cShip it?\u201d: my-repo")
        self.assertEqual(choice_texts(argv), ["Yes \u2014 Now", "No"])

    def test_question_limits(self):
        # 4 questions of 4 options (Claude's maximum), long text everywhere: within the hub's
        # limits as a question field, and as steps for a CLI that refuses the field, where every
        # question keeps some choices and the last step counts the rest.
        long = "word " * 300
        qs = [{"question": "Q%d %s" % (i, long), "header": "H%d %s" % (i, long), "multiSelect": i % 2 == 1,
               "options": [{"label": "L%d%d %s" % (i, j, long), "description": "D %s" % long} for j in range(4)]}
              for i in range(4)]
        argv = self.permission("AskUserQuestion", {"questions": qs})
        item = posted_item(argv)  # raises if the hub would refuse it
        self.assertEqual([len(i["options"]) for i in item["question"]["items"]], [4, 4, 4, 4])
        self.assertLessEqual(len(item["body"]), 2000)
        self.assertIn("Session `sess-123`", item["body"])
        argv = self.permission("AskUserQuestion", {"questions": qs}, NEEDS_YOU_BIN=self.old_cli())
        item = posted_item(argv)
        self.assertLessEqual(len(item["title"]), 100)
        self.assertTrue(item["title"].startswith("Claude asks \u201cQ0 word"))
        self.assertTrue(item["title"].endswith("\u201d and 3 more: my-repo"), item["title"])
        texts = [s["text"] for s in item["steps"]]
        self.assertEqual(len(texts), 10)
        self.assertEqual(texts[-1], "+7 more choices in Claude")
        for i in range(4):
            self.assertTrue(any(t.startswith("H%d " % i) for t in texts[:-1]), texts)
        self.assertTrue(all(len(t) <= 200 for t in texts))
        self.assertIn("Session `sess-123`", item["body"])  # the where lines survive the clamp

    def test_question_text_is_cleaned_and_redacted(self):
        nasty = ("Deploy with\x07 \u202eevil\u202c token=%s and Authorization: Bearer abcdefghijklmnop "
                 "key ghp_%s and ny_%s, invite nyi_%s, sha %s, blob %s, and a branch "
                 "feature/ACME-123-add-a-new-flag-for-the-UserService2 stays"
                 % (SECRET, "A" * 36, "b" * 30, "c" * 20, "0123456789abcdef" * 4,
                    "QWxhZGRpbjpvcGVuIHNlc2FtZQ0123456789abcdefXYZ"))
        argv = self.permission("AskUserQuestion", {"questions": [{
            "question": nasty + "\n-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----",
            "header": "password: hunter2", "options": [{"label": "sk-%s" % ("x" * 30), "description": nasty}]}]})
        text = "\n".join(argv)  # raw, so escapes don't hide a character
        for leak in (SECRET, "abcdefghijklmnop", "A" * 36, "b" * 30, "c" * 20, "0123456789abcdef" * 4,
                     "QWxhZGRpbjpvcGVuIHNlc2FtZQ", "MIIEow", "hunter2", "x" * 30, "\u202e", "\u0007"):
            self.assertNotIn(leak, text)
        self.assertIn("UserService2 stays", text)
        posted_item(argv)

    def test_bash_names_only_the_program(self):
        argv = self.permission("Bash", {"command": "TOKEN=%s sudo -E /usr/bin/curl -H 'Authorization: Bearer %s' x"
                                                   % (SECRET, SECRET), "description": "call %s" % SECRET})
        self.assertEqual(self.opt(argv, "--title"), "Claude wants to run curl: my-repo")
        self.assert_clean(argv)
        argv = self.permission("Bash", {"command": "'unbalanced %s" % SECRET})
        self.assertEqual(self.opt(argv, "--title"), "Claude wants to run a command: my-repo")
        self.assert_clean(argv)

    def test_edit_names_only_the_basename(self):
        argv = self.permission("Write", {"file_path": "/home/me/secret-dir/config.yml", "content": SECRET})
        self.assertEqual(self.opt(argv, "--title"), "Claude wants to edit config.yml: my-repo")
        self.assertNotIn("secret-dir", json.dumps(argv))
        self.assert_clean(argv)

    def test_other_tools(self):
        argv = self.permission("mcp__github__create_issue", {"body": SECRET})
        self.assertEqual(self.opt(argv, "--title"), "Claude needs permission for github create_issue: my-repo")
        self.assert_clean(argv)
        argv = self.permission("Weird tool; rm", {})
        self.assertEqual(self.opt(argv, "--title"), "Claude needs permission for a tool: my-repo")

    def test_no_card_when_approval_not_required(self):
        self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                 "tool_input": {"command": "ls"}, "requires_user_approval": False})
        self.assertEqual(self.calls(), [])

    def test_generic_prompt_does_not_overwrite_it(self):
        self.permission("ExitPlanMode", {})
        n = len(self.calls())
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "permission_prompt",
                                 "message": "Claude needs your permission"})
        self.assertEqual(len(self.calls()), n)
        # once resolved, a later prompt posts again
        self.run_hook("resolve", {"hook_event_name": "PostToolUse"})
        self.assertEqual(self.last()[:1], ["resolve"])
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "permission_prompt"})
        self.assertEqual(self.opt(self.last(), "--title"), "Claude needs permission: my-repo")


class NestedKeyTests(HookHarness):
    """Scan 2026-10-08: the hook read session_id (and the keys it skips on) with a sed grab
    over the whole payload, so the same key inside tool_input (an MCP tool's argument) took
    over the card's key and marker, or made the hook skip the event."""

    def run_raw(self, text, mode="notify"):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_BIN": self.cli, "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1",
               "NEEDS_YOU_HOOK_PLATFORM": "linux"}
        r = subprocess.run([BASH, HOOK, mode], input=text, env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)

    def test_session_id_inside_tool_input_is_not_the_session(self):
        for order in ("before", "after"):
            with self.subTest(order):
                inner = '"tool_input": {"session_id": "other-session", "conversation_id": "c-1"}'
                top = '"session_id": "sess-1234-abcd", "cwd": %s, "hook_event_name": "PermissionRequest", ' \
                      '"tool_name": "mcp__x__y"' % json.dumps(self.cwd)
                text = "{%s, %s}" % ((inner, top) if order == "before" else (top, inner))
                n = len(self.calls())
                self.run_raw(text)
                self.assertEqual(len(self.calls()), n + 1, "the card was skipped")
                self.assertTrue(self.opt(self.last(), "--key").endswith(":sess-1234-abcd"), self.last())
                self.assertTrue(os.path.exists(os.path.join(self.state, "sess-1234-abcd")))
                self.assertFalse(os.path.exists(os.path.join(self.state, "other-session")))
                self.run_hook("resolve", {"hook_event_name": "UserPromptSubmit"})


class OddNameTests(HookHarness):
    """Scan 2026-10-08: names the hub refuses lost the card (the CLI exits 2 and the hook's
    retries fail the same way), and a session id of '..' named a directory as the marker."""

    def test_long_or_control_character_folder_still_posts(self):
        for name in ("p" * 150, "a\x1bb\x07c"):
            with self.subTest(name=name[:10]):
                d = os.path.join(self.home, "src", name)
                os.makedirs(d, exist_ok=True)
                n = len(self.calls())
                self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "permission_prompt",
                                         "cwd": d})
                self.assertEqual(len(self.calls()), n + 1)
                argv = self.last()
                project = self.opt(argv, "--project")
                self.assertLessEqual(len(project), 100)
                for field in (project, self.opt(argv, "--title"), self.opt(argv, "--body")):
                    self.assertFalse(any(ord(c) < 32 and c not in "\n\t" for c in field), repr(field))
                # what the hub would say about it
                hubmod.validate_item_input({"title": self.opt(argv, "--title"), "body": self.opt(argv, "--body"),
                                            "source": {"project": project}})
                self.run_hook("resolve", {"hook_event_name": "UserPromptSubmit"})

    def test_dot_session_ids_are_not_paths(self):
        for sid in ("..", "."):
            with self.subTest(sid):
                self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "permission_prompt",
                                         "session_id": sid})
                key = self.opt(self.last(), "--key")
                self.assertFalse(key.endswith(":" + sid), key)
                self.assertEqual([n for n in os.listdir(os.path.dirname(self.state)) if n.startswith(".")], [])


class PayloadEdgeTests(HookHarness):
    """Hook input the card must survive: huge tool input, odd bytes, nested look-alike keys."""

    def test_huge_tool_input_still_posts(self):
        # A Write of a big file: the payload is far past one environment variable's limit
        # (128 KiB on Linux, ARG_MAX in all on macOS).
        self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "Write",
                                 "tool_input": {"file_path": "/x/big.txt", "content": "x" * 3000000}})
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.opt(self.last(), "--title"), "Claude wants to edit big.txt: my-repo")

    def test_bytes_that_are_not_utf8_become_replacement_characters(self):
        # The hub refuses unpaired surrogates (400), so a raw \\xff must not reach the CLI as one.
        raw = (b'{"session_id":"sess-1234-abcd","cwd":"%s","hook_event_name":"Notification",'
               b'"notification_type":"permission_prompt","message":"bad \xff\xfe bytes"}'
               % self.cwd.encode())
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_BIN": self.cli, "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1",
               "NEEDS_YOU_HOOK_PLATFORM": "linux"}
        r = subprocess.run([BASH, HOOK, "notify"], input=raw, env=env, capture_output=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        body = self.opt(self.last(), "--body")
        self.assertTrue(body.startswith("bad �� bytes"), body)
        body.encode("utf-8")  # no lone surrogates

    def test_closed_stdin_returns_at_once(self):
        # With fd 0 closed, $(cat) gets its own pipe's read end as stdin and waits on itself
        # forever: the agent's hook never returns.
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_BIN": self.cli, "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1",
               "NEEDS_YOU_HOOK_PLATFORM": "linux", "HOOK": HOOK}
        for agent in ("claude", "gemini"):
            with self.subTest(agent):
                p = subprocess.Popen([BASH, "-c", 'exec 0<&-; exec "$0" "$HOOK" notify "$1"', BASH, agent],
                                     env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                     start_new_session=True)
                try:
                    _, err = p.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(p.pid, 9)
                    p.communicate()
                    self.fail("the hook hung with stdin closed")
                self.assertEqual(p.returncode, 0, err)

    def test_tool_input_keys_are_not_the_payloads(self):
        # An MCP tool whose arguments are named like Cursor's or Claude's own fields: still
        # Claude's card, keyed by Claude's session.
        self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "mcp__chat__send",
                                 "tool_input": {"conversation_id": "C1", "cursor_version": "1"}})
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.opt(self.last(), "--key").rsplit(":", 1)[1], "sess-1234-abcd")
        self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "mcp__db__query",
                                 "tool_input": {"session_id": "other-999", "hook_event_name": "Stop"}})
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(self.opt(self.last(), "--key").rsplit(":", 1)[1], "sess-1234-abcd")
        self.assertEqual(self.marker()["kind"], "permission")


class FailureTests(HookHarness):
    def test_free_text_on_cards_is_redacted(self):
        # Scan 2026-10-08: error_message and a notification's message are free text from the
        # API or the agent, and went onto the card as they came.
        secrets = ("sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz012345",
                   "ny_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
                   "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789")
        text = "upstream said: %s; Authorization: Bearer abcdefghijklmnop12345 api_key=hunter2hunter2 %s %s" % secrets
        self.run_hook("notify", {"hook_event_name": "StopFailure", "error_type": "rate_limit",
                                 "error_message": text})
        body = self.opt(self.last(), "--body")
        self.assertIn("upstream said", body)
        for s in secrets + ("abcdefghijklmnop12345", "hunter2hunter2"):
            self.assertNotIn(s, body)
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "idle_prompt",
                                 "message": "waiting " + text}, NEEDS_YOU_AGENT_TURN_CARDS="1")
        body = self.opt(self.last(), "--body")
        for s in secrets + ("abcdefghijklmnop12345", "hunter2hunter2"):
            self.assertNotIn(s, body)

    def test_credentials_in_urls_and_glued_names_are_redacted(self):
        # Security review 0.2: a password in a URL's user part, and a name with the keyword
        # glued on (PGPASSWORD=, MYSQL_PASSWORD already worked) or ending in _key, went out as is.
        text = ("connect to postgres://app:Hunter2pw@db.example:5432/app failed; "
                "https://bot:Gh0stPass99@git.example/repo.git; PGPASSWORD=Sw0rdfish42 psql; "
                "secret_key: Zebra-Stripes-77; private-key=Kx9pQ2mL")
        self.run_hook("notify", {"hook_event_name": "StopFailure", "error_type": "rate_limit",
                                 "error_message": text})
        body = self.opt(self.last(), "--body")
        for s in ("Hunter2pw", "Gh0stPass99", "Sw0rdfish42", "Zebra-Stripes-77", "Kx9pQ2mL"):
            self.assertNotIn(s, body)
        for kept in ("postgres://app:", "@db.example:5432/app", "https://bot:", "PGPASSWORD=", "psql"):
            self.assertIn(kept, body)

    def test_quoted_names_flags_and_arrows_are_redacted(self):
        # Security review 0.2, second pass: a quoted name (JSON, a Python dict), `=>`, a
        # --password flag with a space, and DB_PASS / passphrase went out as is.
        text = ('{"password":"Jzq81kLmw"} {\'api_key\': \'Pv72hhQx\'} auth_token => Rt55wqPz '
                "mysql --password Ux31mmKa; DB_PASS=Wc48rrTy; passphrase: Lq09ssDe")
        self.run_hook("notify", {"hook_event_name": "StopFailure", "error_type": "rate_limit",
                                 "error_message": text})
        body = self.opt(self.last(), "--body")
        for s in ("Jzq81kLmw", "Pv72hhQx", "Rt55wqPz", "Ux31mmKa", "Wc48rrTy", "Lq09ssDe"):
            self.assertNotIn(s, body)
        for kept in ('"password"', "mysql --password", "DB_PASS=", "passphrase:"):
            self.assertIn(kept, body)

    def test_long_names_and_passwords_are_redacted_whole(self):
        # The linear-time patterns must not cap what they catch: a 300-character URL password,
        # an 80-character name before _PASSWORD=, a long --flag name.
        pw = "qx7" * 100  # one case only: not a base64-like run either
        cases = [("postgres://app:%s@db/app" % pw, pw[:30]),
                 ("%s_password=vb62nn" % ("a" * 80), "vb62nn"),
                 ("mysql --%s-password mk40ff" % "-".join(["opt"] * 30), "mk40ff")]
        for text, leak in cases:
            with self.subTest(text=text[:20]):
                self.run_hook("notify", {"hook_event_name": "StopFailure", "error_type": "rate_limit",
                                         "error_message": text})
                self.assertNotIn(leak, self.opt(self.last(), "--body"))
                self.assertIn("[redacted]", self.opt(self.last(), "--body"))

    def test_redaction_takes_linear_time(self):
        # Security review 0.2: ~100 KB of text built to make the redaction patterns backtrack
        # (names glued with "_", "-" runs before "://", "--a-a-a" flags) must not stall the hook.
        import time
        for chunk in ("a_", "x_password_", "a-", "--a-", "token_", "a://b:", "//user", "x:", "a="):
            with self.subTest(chunk=chunk):
                started = time.time()
                self.run_hook("notify", {"hook_event_name": "StopFailure", "error_type": "rate_limit",
                                         "error_message": chunk * (100000 // len(chunk))})
                self.assertLess(time.time() - started, 8)

    def test_stop_failure_card(self):
        self.run_hook("notify", {"hook_event_name": "StopFailure", "error_type": "rate_limit",
                                 "error_message": "Rate limit exceeded"})
        argv = self.last()
        self.assertEqual(self.opt(argv, "--title"), "Claude hit a rate limit: my-repo")
        self.assertIn("Rate limit exceeded", self.opt(argv, "--body"))
        self.assertEqual(self.marker()["kind"], "failure")
        # Stop doesn't clear it (the turn ended on the error); the next prompt does
        self.run_hook("stop", {"hook_event_name": "Stop"}, NEEDS_YOU_CONTEXT_ALERT_PCT="0")
        self.assertEqual(self.last()[0], "add")
        self.run_hook("resolve", {"hook_event_name": "UserPromptSubmit"})
        self.assertEqual(self.last()[:3], ["resolve", "--key", self.opt(argv, "--key")])

    def test_dash_project_and_error_survive_the_cli(self):
        # real CLI argparse, offline: the card queues instead of failing on "-x" values
        self.cwd = os.path.join(self.home, "-odd")
        os.makedirs(self.cwd)
        cli = os.path.join(ROOT, "cli", "needs-you")
        self.run_hook("notify", {"hook_event_name": "StopFailure", "error_message": "--bad"},
                      NEEDS_YOU_BIN=cli, NEEDS_YOU_URL="http://127.0.0.1:9", NEEDS_YOU_TOKEN="t",
                      NEEDS_YOU_TIMEOUT="1")
        self.assertEqual(self.marker()["kind"], "failure")  # the CLI exited 0 (queued)

    def test_unknown_error_type(self):
        self.run_hook("notify", {"hook_event_name": "StopFailure", "error_type": "something_new"})
        self.assertEqual(self.opt(self.last(), "--title"), "Claude stopped on an API error: my-repo")

    def test_usage_limit_notification(self):
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "quota_auto_resume_disabled",
                                 "message": "Usage limit reached"})
        self.assertEqual(self.opt(self.last(), "--title"), "Claude hit its usage limit: my-repo")

    def test_agent_needs_input_title_names_claude(self):
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "agent_needs_input"})
        self.assertEqual(self.opt(self.last(), "--title"), "Claude needs your input: my-repo")

    def test_hooks_json_registers_the_events(self):
        with open(HOOKS_JSON) as fh:
            hooks = json.load(fh)["hooks"]
        modes = {ev: g[0]["hooks"][0]["command"].split()[-1] for ev, g in hooks.items()}
        self.assertEqual(modes, {"Notification": "notify", "PermissionRequest": "notify", "StopFailure": "notify",
                                 "UserPromptSubmit": "resolve", "PostToolUse": "resolve",
                                 # an approved tool that fails fires only PostToolUseFailure (2.1.294)
                                 "PostToolUseFailure": "resolve", "Stop": "stop",
                                 "SessionStart": "start", "SessionEnd": "end"})
        self.assertIn("quota_auto_resume_disabled", hooks["Notification"][0]["matcher"])
        for groups in hooks.values():
            for h in groups[0]["hooks"]:
                self.assertTrue(h["async"])


class LinkTests(HookHarness):
    def notify_links(self, **extra):
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "idle_prompt"}, **extra)
        return self.links(self.last())

    def test_mac_gets_a_folder_link(self):
        self.assertEqual(self.notify_links(NEEDS_YOU_HOOK_PLATFORM="darwin"),
                         ["VS Code=vscode://file" + self.cwd])

    def test_mac_over_ssh_without_alias_gets_none(self):
        self.assertEqual(self.notify_links(NEEDS_YOU_HOOK_PLATFORM="darwin", SSH_CONNECTION="1 2 3 4"), [])

    def test_remote_host_with_alias(self):
        self.assertEqual(self.notify_links(NEEDS_YOU_SSH_ALIAS="devbox"),
                         ["VS Code=vscode://vscode-remote/ssh-remote+devbox" + self.cwd])
        self.assertEqual(self.notify_links(NEEDS_YOU_SSH_ALIAS="bad alias;x"), [])
        self.assertEqual(self.notify_links(), [])

    def test_alias_from_env_file(self):
        conf = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(conf)
        with open(os.path.join(conf, "env"), "w") as fh:
            fh.write("NEEDS_YOU_SSH_ALIAS=devbox\n")
        self.assertEqual(self.notify_links(), ["VS Code=vscode://vscode-remote/ssh-remote+devbox" + self.cwd])

    def test_env_file_is_read_like_the_cli_reads_it(self):
        # The CLI trims each value and takes spaces around "=": a trailing space, a CRLF line
        # or "KEY = 1" opted the CLI in but left the hook quietly off (and NEEDS_YOU_SSH_ALIAS
        # with a trailing space was refused as a bad alias).
        conf = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(conf)
        data = {"hook_event_name": "Notification", "notification_type": "idle_prompt"}
        for text in ("NEEDS_YOU_AGENT_ALERTS=1 \nNEEDS_YOU_SSH_ALIAS=devbox \n",
                     "NEEDS_YOU_AGENT_ALERTS=1\r\nNEEDS_YOU_SSH_ALIAS=devbox\r\n",
                     "NEEDS_YOU_AGENT_ALERTS = 1\nexport NEEDS_YOU_SSH_ALIAS = 'devbox'  \n"):
            with self.subTest(text):
                with open(os.path.join(conf, "env"), "w", newline="") as fh:
                    fh.write(text)
                n = len(self.calls())
                self.run_hook("notify", data, NEEDS_YOU_AGENT_ALERTS=None)
                self.assertEqual(len(self.calls()), n + 1)
                self.assertEqual(self.links(self.last()),
                                 ["VS Code=vscode://vscode-remote/ssh-remote+devbox" + self.cwd])

    def test_env_file_follows_xdg_config_home_like_the_cli(self):
        # --alerts writes NEEDS_YOU_AGENT_ALERTS=1 where the CLI looks; the hook must look there too.
        xdg = os.path.join(self.home, "xdg")
        conf = os.path.join(xdg, "needs-you")
        os.makedirs(conf)
        with open(os.path.join(conf, "env"), "w") as fh:
            fh.write("NEEDS_YOU_AGENT_ALERTS=1\nNEEDS_YOU_SSH_ALIAS=devbox\n")
        env = {"NEEDS_YOU_AGENT_ALERTS": None}  # not in the environment: only the file opts in
        data = {"hook_event_name": "Notification", "notification_type": "idle_prompt"}
        self.run_hook("notify", data, **env)
        self.assertEqual(self.calls(), [])  # ~/.config/needs-you/env doesn't exist
        self.run_hook("notify", data, XDG_CONFIG_HOME=xdg, **env)
        self.assertEqual(self.links(self.last()), ["VS Code=vscode://vscode-remote/ssh-remote+devbox" + self.cwd])
        # NEEDS_YOU_CONFIG (the CLI's override) wins over XDG, NEEDS_YOU_ENV_FILE over both
        other = os.path.join(self.home, "other.env")
        with open(other, "w") as fh:
            fh.write("NEEDS_YOU_AGENT_ALERTS=0\n")
        n = len(self.calls())
        self.run_hook("notify", data, XDG_CONFIG_HOME=xdg, NEEDS_YOU_CONFIG=other, **env)
        self.assertEqual(len(self.calls()), n)
        self.run_hook("notify", data, XDG_CONFIG_HOME=xdg, NEEDS_YOU_CONFIG=other,
                      NEEDS_YOU_ENV_FILE=os.path.join(conf, "env"), **env)
        self.assertEqual(len(self.calls()), n + 1)

    def test_path_is_percent_encoded(self):
        self.cwd = os.path.join(self.home, "my repo")
        os.makedirs(self.cwd)
        self.assertEqual(self.notify_links(NEEDS_YOU_HOOK_PLATFORM="darwin"),
                         ["VS Code=vscode://file" + self.cwd.replace(" ", "%20")])

    def test_vscode_extension_session_gets_the_claude_tab(self):
        self.assertEqual(self.notify_links(NEEDS_YOU_HOOK_PLATFORM="darwin", CLAUDE_CODE_ENTRYPOINT="claude-vscode"),
                         ["Claude=vscode://anthropic.claude-code/open?session=sess-1234-abcd",
                          "VS Code=vscode://file" + self.cwd])
        # a CLI in VS Code's terminal isn't an extension session
        self.assertEqual(self.notify_links(NEEDS_YOU_HOOK_PLATFORM="darwin", TERM_PROGRAM="vscode"),
                         ["VS Code=vscode://file" + self.cwd])

    def test_every_automatic_link_passes_the_hub(self):
        # security audit #14: the narrowed vscode/cursor shapes still take everything the hook writes
        self.cwd = os.path.join(self.home, "my repo", "josé")
        os.makedirs(self.cwd)
        got = (self.notify_links(NEEDS_YOU_HOOK_PLATFORM="darwin", CLAUDE_CODE_ENTRYPOINT="claude-vscode")
               + self.notify_links(NEEDS_YOU_SSH_ALIAS="devbox")
               + self.notify_links(NEEDS_YOU_AGENT_LINK="Cursor=cursor://file{cwd}")
               + self.notify_links(NEEDS_YOU_AGENT_LINK="VS Code=vscode://vscode-remote/ssh-remote+{host}{cwd}"))
        self.assertEqual(len(got), 5)
        for lk in got:
            with self.subTest(lk):
                self.assertTrue(hubmod.link_allowed(lk.partition("=")[2]))

    def test_template_wins_and_none_turns_them_off(self):
        self.assertEqual(self.notify_links(NEEDS_YOU_HOOK_PLATFORM="darwin",
                                           NEEDS_YOU_AGENT_LINK="Cursor=cursor://file{cwd}"),
                         ["Cursor=cursor://file" + self.cwd])
        self.assertEqual(self.notify_links(NEEDS_YOU_HOOK_PLATFORM="darwin", NEEDS_YOU_AGENT_LINK="none",
                                           NEEDS_YOU_SSH_ALIAS="devbox"), [])


UUID = "4F261AE3-041A-47C6-872A-CF02E1E40804"
TERM = "Terminal=needsyou://terminal/focus?"


class TerminalLinkTests(HookHarness):
    """The Terminal link to the Mac terminal tab: from the local terminal's environment on
    the Mac, from LC_NEEDS_YOU_TERM over SSH. Mirrors TerminalJump's validation."""

    def terminal(self, **extra):
        extra.setdefault("NEEDS_YOU_AGENT_LINK", "none")  # only the terminal link
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "idle_prompt"}, **extra)
        return self.links(self.last())

    def mac(self, **extra):
        return self.terminal(NEEDS_YOU_HOOK_PLATFORM="darwin", **extra)

    def test_wezterm(self):
        self.assertEqual(self.mac(TERM_PROGRAM="WezTerm", WEZTERM_PANE="12"), [TERM + "app=wezterm&pane=12"])
        self.assertEqual(self.mac(TERM_PROGRAM="WezTerm", WEZTERM_PANE="12;x"), [])

    def test_tmux_wins_and_names_its_host(self):
        tmux = {"TMUX": "/private/tmp/tmux-501/default,123,0", "TMUX_PANE": "%7"}
        self.assertEqual(self.mac(**tmux), [TERM + "app=tmux&pane=7"])
        self.assertEqual(self.mac(ITERM_SESSION_ID="w0t0p0:" + UUID, **tmux), [TERM + "app=tmux&pane=7&host=iterm"])
        self.assertEqual(self.mac(WEZTERM_PANE="3", **tmux), [TERM + "app=tmux&pane=7&host=wezterm"])
        self.assertEqual(self.mac(TERM_PROGRAM="Apple_Terminal", **tmux), [TERM + "app=tmux&pane=7&host=terminal"])
        self.assertEqual(self.mac(TMUX="x", TMUX_PANE="%7;rm"), [])

    def test_iterm_session_uuid(self):
        self.assertEqual(self.mac(TERM_PROGRAM="iTerm.app", ITERM_SESSION_ID="w0t1p0:" + UUID),
                         [TERM + "app=iterm&session=" + UUID])
        self.assertEqual(self.mac(ITERM_SESSION_ID="w0t1p0:not-a-uuid"), [])

    def test_terminal_app_tty(self):
        self.assertEqual(self.mac(TERM_PROGRAM="Apple_Terminal", NEEDS_YOU_HOOK_TTY="ttys004"),
                         [TERM + "app=terminal&tty=/dev/ttys004"])
        self.assertEqual(self.mac(TERM_PROGRAM="Apple_Terminal", NEEDS_YOU_HOOK_TTY="??"), [])

    def test_ghostty_and_unknown(self):
        self.assertEqual(self.mac(TERM_PROGRAM="ghostty"), [TERM + "app=ghostty"])
        self.assertEqual(self.mac(TERM_PROGRAM="Hyper"), [])
        self.assertEqual(self.mac(), [])

    def test_vscode_terminal_gets_none(self):
        self.assertEqual(self.mac(TERM_PROGRAM="vscode", WEZTERM_PANE="1"), [])

    def test_not_on_linux_without_the_mac_variable(self):
        self.assertEqual(self.terminal(WEZTERM_PANE="12", TERM_PROGRAM="WezTerm"), [])

    def test_ssh_reads_lc_needs_you_term(self):
        ssh = {"SSH_CONNECTION": "10.0.0.2 5000 10.0.0.3 22"}
        for value, want in [
            ("app=iterm&session=" + UUID, "app=iterm&session=" + UUID),
            ("app=wezterm&pane=4", "app=wezterm&pane=4"),
            ("app=terminal&tty=/dev/ttys012", "app=terminal&tty=/dev/ttys012"),
            ("app=terminal&tty=%2Fdev%2Fttys012", "app=terminal&tty=/dev/ttys012"),
            ("app=tmux&target=main:1.0&host=iterm", "app=tmux&target=main:1.0&host=iterm"),
            ("host=wezterm&app=tmux&pane=9", "app=tmux&pane=9&host=wezterm"),
            ("app=ghostty", "app=ghostty"),
        ]:
            self.assertEqual(self.terminal(LC_NEEDS_YOU_TERM=value, **ssh), [TERM + want], value)
            self.assertEqual(self.terminal(LC_NEEDS_YOU_TERM=value), [TERM + want], "linux, no ssh: " + value)
        for bad in ["", "iterm", "app=iterm", "app=xterm&pane=1", "app=wezterm&pane=-1", "app=wezterm&pane=1&pane=2",
                    "app=wezterm&pane=1&cmd=rm", "app=wezterm&pane=1;rm", "app=terminal&tty=/dev/ttys1%0A",
                    "app=iterm&session=" + UUID + "%22", "app=tmux&target=-x:1.0", "app=tmux&pane=1&target=a:1.2",
                    "app=tmux&pane=1&host=tmux", "app=wezterm&pane=1&host=iterm", "app=ghostty&pane=1",
                    "app=iterm&session=" + UUID + "&tty=/dev/ttys001", "a" * 301]:
            self.assertEqual(self.terminal(LC_NEEDS_YOU_TERM=bad, **ssh), [], bad)

    def test_ssh_ignores_the_remote_terminal(self):
        # The remote's own tmux/WezTerm variables name panes on the remote, not on the Mac.
        self.assertEqual(self.terminal(SSH_CONNECTION="1 2 3 4", NEEDS_YOU_HOOK_PLATFORM="darwin",
                                       TMUX="x", TMUX_PANE="%3", WEZTERM_PANE="2"), [])

    def test_comes_first_and_editor_links_follow(self):
        self.assertEqual(self.terminal(NEEDS_YOU_HOOK_PLATFORM="darwin", WEZTERM_PANE="12", NEEDS_YOU_AGENT_LINK=""),
                         [TERM + "app=wezterm&pane=12", "VS Code=vscode://file" + self.cwd])

    def test_orca_wins(self):
        h = "term_4f261ae3-041a-47c6-872a-cf02e1e40804"
        self.assertEqual(self.mac(WEZTERM_PANE="12", ORCA_TERMINAL_HANDLE=h),
                         ["Terminal=needsyou://orca/terminal?handle=" + h])

    def test_old_hub_retry_drops_every_app_link(self):
        with open(self.cli, "w") as fh:
            fh.write(FAKE_CLI + "sys.exit(2 if any('=needsyou://' in a for a in sys.argv) else 0)\n")
        self.terminal(NEEDS_YOU_HOOK_PLATFORM="darwin", WEZTERM_PANE="12", NEEDS_YOU_AGENT_LINK="")
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.links(calls[0])[0], TERM + "app=wezterm&pane=12")
        self.assertEqual(self.links(calls[1]), ["VS Code=vscode://file" + self.cwd])

    def test_refused_template_link_still_posts_the_card(self):
        # security audit #14: the hub refuses extension handlers; the card arrives without links
        with open(self.cli, "w") as fh:
            fh.write(FAKE_CLI + "sys.exit(2 if any('ms-python' in a for a in sys.argv) else 0)\n")
        self.terminal(NEEDS_YOU_HOOK_PLATFORM="darwin", WEZTERM_PANE="12",
                      NEEDS_YOU_AGENT_LINK="Py=vscode://ms-python.python/x")
        calls = self.calls()
        self.assertEqual(len(calls), 3)
        self.assertEqual(self.links(calls[2]), [])


def usage_line(total, model="claude-opus-5", sidechain=False, cache=True):
    u = ({"input_tokens": 10, "cache_read_input_tokens": total - 1010, "cache_creation_input_tokens": 1000,
          "output_tokens": 999} if cache else {"input_tokens": total, "output_tokens": 5})
    return json.dumps({"type": "assistant", "isSidechain": sidechain,
                       "message": {"model": model, "role": "assistant", "usage": u,
                                   "content": [{"type": "text", "text": "hi"}]}})


class ContextTests(HookHarness):
    def setUp(self):
        super().setUp()
        self.transcript = os.path.join(self.home, "t.jsonl")
        self.write([usage_line(20000)])

    def write(self, lines, filler=0):
        with open(self.transcript, "w") as fh:
            for l in lines[:-1]:
                fh.write(l + "\n")
            # big tool results between messages: the hook only reads the tail
            for _ in range(filler):
                fh.write(json.dumps({"type": "user", "message": {"content": "x" * 10000}}) + "\n")
            fh.write(lines[-1] + "\n")

    def stop(self, **extra):
        return self.run_hook("stop", {"hook_event_name": "Stop", "transcript_path": self.transcript}, **extra)

    def context_calls(self):
        return [c for c in self.calls() if any(str(a).endswith(":context") for a in c)]

    def test_posts_once_over_the_threshold_and_resolves_below(self):
        self.stop()
        self.assertEqual(self.context_calls(), [])
        self.write([usage_line(170000)])
        self.stop()
        argv = self.context_calls()[-1]
        self.assertEqual(argv[0], "add")
        self.assertTrue(self.opt(argv, "--key").endswith(":sess-1234-abcd:context"))
        self.assertEqual(self.opt(argv, "--priority"), "low")
        self.assertEqual(self.opt(argv, "--title"), "Claude's context is 85% full: my-repo")
        body = self.opt(argv, "--body")
        for want in ("170k of its 200k-token context (85%)", "/compact", "/clear"):
            self.assertIn(want, body)
        self.assertEqual(self.marker("sess-1234-abcd.context")["pct"], "85")
        # about the same level: no re-post every turn
        self.write([usage_line(172000)])
        self.stop()
        self.assertEqual(len(self.context_calls()), 1)
        self.write([usage_line(185000)])
        self.stop()
        self.assertEqual(self.opt(self.context_calls()[-1], "--title"), "Claude's context is 92% full: my-repo")
        # after /compact the transcript has a compact boundary: resolved
        self.write([usage_line(185000), json.dumps({"type": "system", "subtype": "compact_boundary"})])
        self.stop()
        self.assertEqual(self.context_calls()[-1][:1], ["resolve"])
        self.assertFalse(os.path.exists(os.path.join(self.state, "sess-1234-abcd.context")))

    def test_reads_only_the_tail_and_skips_subagents(self):
        self.write([usage_line(190000), usage_line(5000, sidechain=True)], filler=40)
        self.stop()
        self.assertEqual(self.opt(self.context_calls()[-1], "--title"), "Claude's context is 95% full: my-repo")

    def test_threshold_and_window_settings(self):
        self.write([usage_line(120000)])
        self.stop(NEEDS_YOU_CONTEXT_ALERT_PCT="50")
        self.assertIn("60% full", self.opt(self.context_calls()[-1], "--title"))
        self.stop(NEEDS_YOU_CONTEXT_ALERT_PCT="50", NEEDS_YOU_CONTEXT_WINDOW="400000")
        self.assertEqual(self.context_calls()[-1][0], "resolve")  # 30% of 400k
        self.stop(NEEDS_YOU_CONTEXT_ALERT_PCT="0")
        self.assertEqual(len(self.context_calls()), 2)

    def test_one_million_models(self):
        self.write([usage_line(300000)])  # more than 200k: must be a 1M window
        self.stop()
        self.assertEqual(self.context_calls(), [])
        self.write([usage_line(850000)])
        self.stop()
        self.assertIn("85% full", self.opt(self.context_calls()[-1], "--title"))
        # a [1m] model from SessionStart (the transcript names the model without it)
        self.run_hook("end", {"hook_event_name": "SessionEnd"})
        self.run_hook("start", {"hook_event_name": "SessionStart", "source": "startup",
                                "model": "claude-opus-5[1m]"})
        self.write([usage_line(170000)])
        self.stop()
        self.assertEqual(self.context_calls()[-1][0], "resolve")  # end resolved it; 17% now: nothing new
        self.assertNotIn("add", [c[0] for c in self.context_calls()[2:]])
        self.stop(ANTHROPIC_MODEL="opus[1m]")
        self.assertEqual(len([c for c in self.context_calls() if c[0] == "add"]), 1)

    def test_unknown_transcript_is_quiet(self):
        self.run_hook("stop", {"hook_event_name": "Stop", "transcript_path": os.path.join(self.home, "nope")})
        with open(self.transcript, "w") as fh:
            fh.write("not json\n{\"type\": \"assistant\", \"message\": {\"usage\": \"x\"}}\n")
        self.stop()
        self.assertEqual(self.calls(), [])

    def test_clear_resolves_the_old_sessions_cards(self):
        self.write([usage_line(170000)])
        self.stop()
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "idle_prompt"})
        ctx_key = self.opt(self.context_calls()[-1], "--key")
        main_key = self.opt(self.last(), "--key")
        # /clear: a new session id in the same Claude process (the test process here)
        self.run_hook("start", {"hook_event_name": "SessionStart", "source": "clear", "session_id": "sess-new"})
        resolved = sorted(c[2] for c in self.calls() if c[0] == "resolve")
        self.assertEqual(resolved, sorted([ctx_key, main_key]))
        self.assertEqual([n for n in os.listdir(self.state) if not n.startswith(".")], [])

    def test_startup_resolves_nothing(self):
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "idle_prompt"})
        self.run_hook("start", {"hook_event_name": "SessionStart", "source": "startup", "session_id": "other"})
        self.assertEqual([c[0] for c in self.calls()], ["add"])

    def test_session_end_resolves_both(self):
        self.write([usage_line(170000)])
        self.stop()
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "idle_prompt"})
        self.run_hook("end", {"hook_event_name": "SessionEnd", "reason": "other"})
        self.assertEqual(sorted(c[0] for c in self.calls()[-2:]), ["resolve", "resolve"])
        self.assertEqual([n for n in os.listdir(self.state) if not n.startswith(".")], [])

    def test_context_card_lease_is_reaped_by_flush(self):
        # the marker carries the lease, so `needs-you flush` resolves it when Claude dies
        self.write([usage_line(170000)])
        self.stop()
        m = self.marker("sess-1234-abcd.context")
        self.assertEqual(m["pid"], str(os.getpid()))
        self.assertTrue(m["key"].startswith("agent:"))
        self.assertTrue(m["start"])


class OwnItemTests(HookHarness):
    """One card for one wait: an agent that posted its own blocker from the session (the
    skill, through the real CLI) gets no extra "Claude is waiting for you" card."""

    def real_cli(self, *args, **env):
        e = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
             "NEEDS_YOU_URLS": "http://127.0.0.1:9", "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_TIMEOUT": "1"}
        e.update(env)
        r = subprocess.run([sys.executable, CLI] + list(args), env=e, capture_output=True, text=True,
                           timeout=60, cwd=self.home)
        self.assertEqual(r.returncode, 0, r.stderr)  # the hub is down: queued, exit 0

    def idle(self, **extra):
        before = len(self.calls())
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "idle_prompt"}, **extra)
        return len(self.calls()) > before

    def test_waiting_card_skipped_while_the_agents_item_is_open(self):
        in_session = {"CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "sess-1234-abcd"}
        self.real_cli("add", "--key", "work:ACME-1:decide", "--title", "Choose A or B", **in_session)
        self.assertFalse(self.idle())
        # agent_needs_input is the same wait; a permission prompt is a different one
        before = len(self.calls())
        self.run_hook("notify", {"hook_event_name": "Notification", "notification_type": "agent_needs_input"})
        self.assertEqual(len(self.calls()), before)
        self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                 "tool_input": {"command": "git push"}})
        self.assertEqual(len(self.calls()), before + 1)
        # another session isn't affected
        self.assertTrue(self.idle(ORCA_TERMINAL_HANDLE="term_0123abcd"))
        self.run_hook("resolve", {"hook_event_name": "UserPromptSubmit"})  # clears the permission card
        self.assertFalse(self.idle())
        # resolved (from anywhere): the waiting card is back
        self.real_cli("resolve", "--key", "work:ACME-1:decide")
        self.assertTrue(self.idle())

    def test_orca_handle_done_expiry_and_session_end(self):
        orca = {"CLAUDECODE": "1", "ORCA_TERMINAL_HANDLE": "term_0123abcd", "CLAUDE_CODE_SESSION_ID": "x"}
        term = {"ORCA_TERMINAL_HANDLE": "term_0123abcd"}
        self.real_cli("add", "--key", "work:ACME-2:x", "--title", "t", **orca)
        self.assertFalse(self.idle(**term))
        self.real_cli("done", "--key", "work:ACME-2:x", "--title", "t", **orca)  # no longer needs anyone
        self.assertTrue(self.idle(**term))
        # expired records don't count
        self.real_cli("add", "--key", "work:ACME-3:x", "--title", "t", "--expires-in", "0.0000001", **orca)
        self.assertTrue(self.idle(**term))
        # SessionEnd forgets the session's records
        self.real_cli("add", "--key", "work:ACME-4:x", "--title", "t", **orca)
        self.assertFalse(self.idle(**term))
        self.run_hook("end", {"hook_event_name": "SessionEnd"}, **term)
        self.assertTrue(self.idle(**term))

    def agent_turn_ended(self, agent, event, data=None, **extra):
        """The agent's card for `event`; True if it posted."""
        before = len(self.calls())
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home, "NEEDS_YOU_BIN": self.cli,
               "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_HOOK_PLATFORM": "linux",
               "NY_HOOK_BG": "1"}  # Gemini: run in the foreground, as its background copy does
        env.update(extra)
        payload = {"session_id": "agent-sess-1", "cwd": self.cwd, "hook_event_name": event}
        payload.update(data or {})
        r = subprocess.run([BASH, HOOK, "notify", agent], input=json.dumps(payload), env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        return len(self.calls()) > before

    def test_other_agents_in_orca_skip_their_turn_ended_card(self):
        # Codex, Gemini CLI and opencode give their commands no session id; in Orca the
        # terminal handle names the session for both the CLI and the hook.
        term = {"ORCA_TERMINAL_HANDLE": "term_0123abcd"}
        permission = {"codex": ("PermissionRequest", {"tool_name": "Bash"}),
                      "opencode": ("PermissionRequest", {"tool_name": "bash"}),
                      "gemini": ("Notification", {"notification_type": "ToolPermission",
                                                  "details": {"type": "exec", "command": "ls"}})}
        for agent, event in (("codex", "Stop"), ("gemini", "AfterAgent"), ("opencode", "Stop")):
            self.assertTrue(self.agent_turn_ended(agent, event, **term), agent)
            self.real_cli("add", "--key", "work:ACME-6:%s" % agent, "--title", "t", **term)
            self.assertFalse(self.agent_turn_ended(agent, event, **term), agent)
            # a permission prompt still posts
            self.assertTrue(self.agent_turn_ended(agent, permission[agent][0], permission[agent][1], **term), agent)
            self.real_cli("resolve", "--key", "work:ACME-6:%s" % agent)
            self.run_hook("resolve", {"hook_event_name": "UserPromptSubmit"}, **term)
            self.assertTrue(self.agent_turn_ended(agent, event, **term), agent)

    def test_other_agents_outside_orca(self):
        # Codex gives its commands $CODEX_SESSION_ID (older: $CODEX_THREAD_ID), the hook's
        # session_id; the opencode plugin sets $NEEDS_YOU_AGENT_SESSION through shell.env.
        for agent, env in (("codex", {"CODEX_SESSION_ID": "agent-sess-1", "CODEX_THREAD_ID": "agent-sess-2"}),
                           ("codex", {"CODEX_THREAD_ID": "agent-sess-1"}),
                           ("opencode", {"NEEDS_YOU_AGENT_SESSION": "agent-sess-1"})):
            key = "work:ACME-7:%s" % agent
            self.assertTrue(self.agent_turn_ended(agent, "Stop"), agent)
            self.real_cli("add", "--key", key, "--title", "t", **env)
            self.assertFalse(self.agent_turn_ended(agent, "Stop"), (agent, env))
            # another session of the same agent isn't affected
            self.assertTrue(self.agent_turn_ended(agent, "Stop", {"session_id": "agent-sess-9"}), agent)
            self.real_cli("resolve", "--key", key)
            self.assertTrue(self.agent_turn_ended(agent, "Stop"), agent)
        # a subagent thread's own id isn't the session's: Codex's hooks name the root session
        self.real_cli("add", "--key", "work:ACME-8:x", "--title", "t",
                      CODEX_SESSION_ID="agent-sess-9", CODEX_THREAD_ID="agent-sess-1")
        self.assertTrue(self.agent_turn_ended("codex", "Stop"))
        self.real_cli("resolve", "--key", "work:ACME-8:x")

    def test_any_connector_can_name_the_session(self):
        # docs/guides/custom-connector.md: NEEDS_YOU_AGENT_SESSION in the agent's commands, a
        # note per item under session-items/<sanitized id>/ with key= and expires=
        self.real_cli("add", "--key", "acme-agent:x:decide", "--title", "t", NEEDS_YOU_AGENT_SESSION="ses 1/a")
        d = os.path.join(self.home, ".local", "state", "needs-you", "session-items", "ses_1_a")
        notes = os.listdir(d)
        self.assertEqual(len(notes), 1)
        with open(os.path.join(d, notes[0])) as fh:
            note = dict(l.rstrip("\n").split("=", 1) for l in fh)
        self.assertEqual(note["key"], "acme-agent:x:decide")
        self.assertGreater(int(note["expires"]), 0)
        self.real_cli("resolve", "--key", "acme-agent:x:decide")
        self.assertFalse(os.path.exists(os.path.join(d, notes[0])))

    def test_gemini_outside_orca_by_process(self):
        # Gemini CLI gives its commands no session id, only GEMINI_CLI=1: the CLI notes the key
        # for the Gemini process (its first ancestor that isn't a shell), which is the process
        # the hook's lease names. Here that's this test process for both.
        self.assertTrue(self.agent_turn_ended("gemini", "AfterAgent"))
        self.real_cli("add", "--key", "work:ACME-9:x", "--title", "t", GEMINI_CLI="1")
        self.assertFalse(self.agent_turn_ended("gemini", "AfterAgent"))
        self.assertTrue(self.agent_turn_ended("gemini", "Notification", {
            "notification_type": "ToolPermission", "details": {"type": "exec", "rootCommand": "ls"}}))
        # a hook under another Gemini process isn't affected
        wrapped = [sys.executable, "-c", "import subprocess, sys; sys.exit(subprocess.run(sys.argv[1:]).returncode)"]
        before = len(self.calls())
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home, "NEEDS_YOU_BIN": self.cli,
               "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_HOOK_PLATFORM": "linux",
               "NY_HOOK_BG": "1"}
        payload = {"session_id": "agent-sess-1", "cwd": self.cwd, "hook_event_name": "AfterAgent"}
        subprocess.run(wrapped + [BASH, HOOK, "notify", "gemini"], input=json.dumps(payload), env=env,
                       capture_output=True, text=True, timeout=30)
        self.assertEqual(len(self.calls()), before + 1)
        # the session ending forgets it
        self.run_hook("end", {"hook_event_name": "SessionEnd"})  # (a Claude session: no effect)
        self.assertFalse(self.agent_turn_ended("gemini", "AfterAgent"))
        self.agent_end("gemini")
        self.assertTrue(self.agent_turn_ended("gemini", "AfterAgent"))
        # outside Gemini nothing is noted for the process
        self.real_cli("add", "--key", "work:ACME-10:x", "--title", "t")
        self.assertTrue(self.agent_turn_ended("gemini", "AfterAgent"))

    @unittest.skipUnless(sys.platform.startswith("linux"), "a process named kimi from a symlink: Linux names it so")
    def test_kimi_outside_orca_by_process(self):
        # Kimi Code's Bash tool gives commands no session id, only TERM=dumb: the CLI notes the
        # key for the kimi process, which the hook's lease names too. A stand-in "kimi" (python
        # under that name) runs both, as the real one does.
        kimi = os.path.join(self.home, "bin", "kimi")
        os.makedirs(os.path.dirname(kimi))
        os.symlink(sys.executable, kimi)
        # One kimi process for the whole session: it reads [mode, payload] lines and runs each.
        driver = (
            "import json, os, subprocess, sys\n"
            "cli, hook = sys.argv[1:3]\n"
            "for line in sys.stdin:\n"
            "    mode, payload = json.loads(line)\n"
            "    if mode.startswith('add'):\n"
            "        env = dict(os.environ, TERM='dumb' if mode == 'add' else 'xterm')\n"
            "        subprocess.run(['/bin/sh', '-c', '\"$0\" \"$1\" add --key work:ACME-11:x --title t',"
            " os.environ['PY'], cli], env=env, stdin=subprocess.DEVNULL, capture_output=True)\n"
            "    else:\n"
            "        subprocess.run(['bash', hook, mode, 'kimi'], input=payload.encode(), capture_output=True)\n"
            "    print('done', flush=True)\n")
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home, "NEEDS_YOU_BIN": self.cli,
               "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_HOOK_PLATFORM": "linux",
               "NY_HOOK_BG": "1", "NY_KIMI_TURN_WAIT": "0", "PY": sys.executable,
               "NEEDS_YOU_URLS": "http://127.0.0.1:9", "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_TIMEOUT": "1"}
        proc = subprocess.Popen([kimi, "-c", driver, CLI, HOOK], env=env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, text=True, cwd=self.home)
        self.addCleanup(lambda: (proc.stdin.close(), proc.wait(), proc.stdout.close()))

        def under_kimi(mode, event="Stop", **data):
            before = len(self.calls())
            payload = dict({"session_id": "kimi-sess-1", "cwd": self.cwd, "hook_event_name": event}, **data)
            proc.stdin.write(json.dumps([mode, json.dumps(payload)]) + "\n")
            proc.stdin.flush()
            self.assertEqual(proc.stdout.readline().strip(), "done")
            return len(self.calls()) > before

        self.assertTrue(under_kimi("notify"))
        under_kimi("add")
        self.assertFalse(under_kimi("notify"))  # its own card is up: no second one
        # an approval prompt is another thing to act on
        self.assertTrue(under_kimi("notify", "PermissionRequest", tool_name="Bash", tool_input={"command": "ls"}))
        # the session ending forgets it
        under_kimi("end", "SessionEnd")
        self.assertTrue(under_kimi("notify"))
        # a command that isn't Kimi's Bash tool (no TERM=dumb) notes nothing for the process
        under_kimi("add-plain")
        self.assertTrue(under_kimi("notify"))

    def agent_end(self, agent):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home, "NEEDS_YOU_BIN": self.cli,
               "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1", "NY_HOOK_BG": "1"}
        payload = {"session_id": "agent-sess-1", "cwd": self.cwd, "hook_event_name": "SessionEnd"}
        r = subprocess.run([BASH, HOOK, "end", agent], input=json.dumps(payload), env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)

    def test_outside_claude_nothing_is_recorded(self):
        self.real_cli("add", "--key", "work:ACME-5:x", "--title", "t", CLAUDE_CODE_SESSION_ID="sess-1234-abcd")
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local", "state", "needs-you", "session-items")))
        self.real_cli("add", "--key", "work:ACME-5:x", "--title", "t", CLAUDECODE="1", CLAUDE_CODE_SESSION_ID="..")
        self.assertTrue(self.idle())


class GrokTests(HookHarness):
    """Grok Build runs the Claude hooks from ~/.claude/settings.json. It sets GROK_HOOK_EVENT
    and sends notificationType (no notification_type): the hook must post as Grok, not as a
    generic "Claude needs you", and must not hold up Grok (it waits for its hooks)."""

    GROK = {"GROK_HOOK_EVENT": "notification", "GROK_SESSION_ID": "grok-sess-1", "NY_HOOK_BG": "1"}

    def grok(self, mode, data, **extra):
        env = dict(self.GROK)
        env.update(extra)
        payload = {"session_id": "grok-sess-1", "sessionId": "grok-sess-1"}
        payload.update(data)
        return self.run_hook(mode, payload, **env)

    def test_idle_and_permission_cards(self):
        self.grok("notify", {"hook_event_name": "Notification", "hookEventName": "notification",
                             "notificationType": "idle_prompt", "message": "waiting", "level": "info"})
        argv = self.last()
        self.assertEqual(self.opt(argv, "--title"), "Grok finished: my-repo")
        self.assertEqual(self.opt(argv, "--agent"), "grok")
        self.assertTrue(self.opt(argv, "--key").endswith(":grok-sess-1"))
        self.grok("notify", {"hook_event_name": "Notification", "notificationType": "permission_prompt"})
        self.assertEqual(self.opt(self.last(), "--title"), "Grok needs permission: my-repo")
        self.assertEqual(self.marker("grok-sess-1")["kind"], "permission")
        # the turn-ended (idle) card follows NEEDS_YOU_AGENT_TURN_CARDS like the other agents'
        n = len(self.calls())
        self.grok("notify", {"hook_event_name": "Notification", "notificationType": "idle_prompt"},
                  NEEDS_YOU_AGENT_TURN_CARDS="0")
        self.assertEqual(len(self.calls()), n)
        self.grok("notify", {"hook_event_name": "StopFailure", "error_type": "rate_limit"})
        self.assertEqual(self.opt(self.last(), "--title"), "Grok stopped on an error: my-repo")

    def test_stop_resolves_without_the_claude_context_check(self):
        self.grok("notify", {"hook_event_name": "Notification", "notificationType": "permission_prompt"})
        transcript = os.path.join(self.home, "updates.jsonl")
        with open(transcript, "w") as fh:  # what a Claude context check would read as 95% full
            fh.write(json.dumps({"type": "assistant", "message": {"model": "m", "usage": {"input_tokens": 190000}}}) + "\n")
        self.grok("stop", {"hook_event_name": "Stop", "transcript_path": transcript}, GROK_HOOK_EVENT="stop")
        self.assertEqual([c[0] for c in self.calls()], ["add", "resolve"])

    def test_returns_at_once_and_posts_in_the_background(self):
        env = dict(self.GROK, NY_HOOK_BG=None)
        r = self.grok("notify", {"hook_event_name": "Notification", "notificationType": "idle_prompt"}, **env)
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        import time
        deadline = time.time() + 10
        while time.time() < deadline and not self.calls():
            time.sleep(0.05)
        self.assertEqual(self.opt(self.last(), "--agent"), "grok")


if __name__ == "__main__":
    unittest.main()
