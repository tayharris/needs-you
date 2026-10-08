"""ADR 0009 B3: answering Claude Code's AskUserQuestion from the card.

Claude Code runs a synchronous PermissionRequest hook (matcher AskUserQuestion) in `ask` mode.
It posts the question card, answerable when the card can show the question whole, waits for
the person's click (`needs-you answer-wait`) and prints Claude's decision:
{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow",
"updatedInput": {<tool_input>, "answers": {"<question text>": "<label>[, <label>]"}}}}}.
Measured live (Claude Code 2.1.294): the dialog shows while the hook waits, an answer printed
by the hook is taken, and one given in the terminal first wins (the hook isn't killed; its
later output is ignored), so the hook stops waiting once the card is resolved.

Nothing is printed on a timeout, an error, an answer that doesn't fit, or when answering is
off. Temporary HOME, a fake or test-hub CLI; never the real ~/.claude.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

from hook_case import fixture, has_opt, opt, posted_item
from support import CLI, ROOT, HubTestCase, request, wait_until

BASH = shutil.which("bash") or "/bin/bash"
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
HOOKS_JSON = os.path.join(ROOT, "integrations", "claude-code", "hooks.json")

# Logs its argv. `answer-wait` prints $FAKE_ANSWER (with {QID} replaced by the question id of
# the last `add`) and exits $FAKE_WAIT_RC.
FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys
log = os.environ["FAKE_CLI_LOG"]
with open(log, "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:2] == ["answer-wait"]:
    qid = ""
    for line in open(log):
        argv = json.loads(line)
        for a in argv:
            if a.startswith("--question-json="):
                qid = json.loads(a[len("--question-json="):]).get("id", "")
    sys.stdout.write(os.environ.get("FAKE_ANSWER", "").replace("{QID}", qid))
    sys.exit(int(os.environ.get("FAKE_WAIT_RC") or 0))
"""

QUESTIONS = fixture("claude-ask-user-question.json")["tool_input"]


def answer(*sel, qid="{QID}"):
    return json.dumps({"id": "01ITEM", "key": "k", "status": "open", "question_id": qid,
                       "answers": [{"selected": list(s)} for s in sel],
                       "answered_at": "2026-10-08T10:00:00.000Z", "answered_by": "mac"})


class AskMode(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-ccans-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.cli = os.path.join(self.home, "fake-needs-you")
        with open(self.cli, "w") as fh:
            fh.write(FAKE_CLI)
        os.chmod(self.cli, 0o755)
        self.log = os.path.join(self.home, "calls.log")
        self.cwd = os.path.join(self.home, "src", "my-repo")
        os.makedirs(self.cwd)
        self.state = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks")

    def ask(self, tool_input=None, tool="AskUserQuestion", ans="", rc=0, **extra):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_BIN": self.cli, "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1",
               "NEEDS_YOU_HOOK_PLATFORM": "linux", "FAKE_ANSWER": ans, "FAKE_WAIT_RC": str(rc)}
        env.update(extra)
        env = {k: v for k, v in env.items() if v is not None}
        payload = {"session_id": "sess-1234-abcd", "cwd": self.cwd, "hook_event_name": "PermissionRequest",
                   "tool_name": tool, "tool_input": QUESTIONS if tool_input is None else tool_input,
                   "permission_mode": "default"}
        r = subprocess.run([BASH, HOOK, "ask"], input=json.dumps(payload), env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stderr, "")
        return r.stdout

    def calls(self):
        try:
            with open(self.log) as fh:
                return [json.loads(l) for l in fh]
        except OSError:
            return []

    def adds(self):
        return [c for c in self.calls() if c[0] == "add"]

    def waits(self):
        return [c for c in self.calls() if c[0] == "answer-wait"]

    def marker(self):
        with open(os.path.join(self.state, "sess-1234-abcd")) as fh:
            return dict(l.rstrip("\n").split("=", 1) for l in fh)

    def test_an_answer_from_the_card_is_claudes_answer(self):
        out = self.ask(ans=answer(["SQLite"], ["Export", "Auth"]))
        decision = json.loads(out)
        self.assertEqual(decision, {"hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {"behavior": "allow", "updatedInput": dict(QUESTIONS, answers={
                "Which database should we use?": "SQLite",
                "Which features?": "Auth, Export"})}}})  # in the options' order
        self.assertEqual(out.count("\n"), 1)  # the decision only
        add = self.adds()[-1]
        item = posted_item(add)  # the hub would take it
        q = item["question"]
        self.assertTrue(q["answerable"])
        self.assertIn("expires_at", q)
        self.assertTrue(re.match(r"^claude-[0-9a-f]{16,}$", q["id"]), q["id"])
        self.assertIn("Pick here or answer in Claude.", opt(add, "--body"))
        self.assertEqual(self.waits(), [["answer-wait", "--key", opt(add, "--key"), "--timeout", "600"]])
        self.assertEqual(self.marker()["kind"], "permission")  # Notification permission_prompt keeps it

    def test_each_question_gets_its_own_id(self):
        self.ask(ans=answer(["SQLite"], ["Auth"]))
        self.ask(ans=answer(["SQLite"], ["Auth"]))
        ids = [json.loads(opt(a, "--question-json"))["id"] for a in self.adds()]
        self.assertEqual(len(set(ids)), 2)

    def test_the_answer_timeout_is_passed_on(self):
        self.ask(NEEDS_YOU_ANSWER_TIMEOUT="45", ans=answer(["SQLite"], ["Auth"]))
        self.assertEqual(self.waits()[-1][-2:], ["--timeout", "45"])
        self.ask(NEEDS_YOU_ANSWER_TIMEOUT="99999", ans=answer(["SQLite"], ["Auth"]))
        self.assertEqual(self.waits()[-1][-2:], ["--timeout", "3600"])

    def test_nothing_is_answered_without_a_good_answer(self):
        bad = [
            answer(["MySQL"], ["Auth"]),                  # not an offered label
            answer(["SQLite", "Postgres"], ["Auth"]),     # two for a single choice
            answer(["SQLite"]),                           # one question short
            answer(["SQLite"], ["Auth"], ["Export"]),     # one too many
            answer(["SQLite"], []),                       # nothing picked
            answer(["SQLite"], ["Auth", "Auth"]),         # a repeat
            answer(["SQLite"], ["Auth"], qid="claude-0000000000000000"),  # another question
            answer(["SQLite"], ["Auth"], qid=None),
            "not json", "", "[]", '{"answers": "SQLite"}',
            '{"question_id": "{QID}", "answers": [{"selected": "SQLite"}, {"selected": ["Auth"]}]}',
        ]
        for a in bad:
            with self.subTest(answer=a):
                self.assertEqual(self.ask(ans=a), "")
        # The CLI's other outcomes: timeout (3), none will come (4), setup problems (2).
        for rc in (2, 3, 4, 1):
            with self.subTest(rc=rc):
                self.assertEqual(self.ask(ans=answer(["SQLite"], ["Auth"]), rc=rc), "")

    def read_only(self, tool_input=None, **extra):
        if os.path.exists(self.log):
            os.remove(self.log)
        out = self.ask(tool_input, ans=answer(["SQLite"], ["Auth"]), **extra)
        self.assertEqual(out, "")
        self.assertEqual(self.waits(), [])
        add = self.adds()[-1]
        q = json.loads(opt(add, "--question-json")) if has_opt(add, "--question-json") else {}
        self.assertFalse(q.get("answerable"))
        return add

    def test_answering_off(self):
        for extra in ({"NEEDS_YOU_ANSWER_TIMEOUT": "0"}, {"NEEDS_YOU_ANSWER_TIMEOUT": "off"},
                      {"NEEDS_YOU_AGENT_QUESTIONS": "0"}):
            with self.subTest(**extra):
                add = self.read_only(**extra)
                self.assertNotIn("Pick here", opt(add, "--body"))
        # NEEDS_YOU_AGENT_QUESTIONS=0: the plain card, no question text at all
        self.assertEqual(opt(add, "--title"), "Claude asked you a question: my-repo")

    def test_questions_the_card_cant_answer_exactly_stay_read_only(self):
        def qs(*items):
            return {"questions": list(items)}

        def q(text, labels, multi=False):
            return {"question": text, "header": "H", "multiSelect": multi,
                    "options": [{"label": l, "description": ""} for l in labels]}
        cases = {
            "same question twice": qs(q("Which?", ["A", "B"]), q("Which?", ["C", "D"])),
            "multi-select label with a comma": qs(q("Which?", ["A, B", "C"], multi=True)),
            "five questions": qs(*[q("Q%d?" % i, ["A", "B"]) for i in range(5)]),
            "nine options": qs(q("Which?", ["L%d" % i for i in range(9)])),
            "a label the card would cut": qs(q("Which?", ["x" * 90, "B"])),
            "a label it would redact": qs(q("Which?", ["sk-ant-api03-SECRETSECRETSECRET", "B"])),
            "a repeated label": qs(q("Which?", ["A", "A"])),
            "no options": qs(q("Which?", [])),
            "an option that isn't an object": {"questions": [{"question": "Which?", "options": ["A", "B"]}]},
            "a question without text": {"questions": [{"header": "H", "options": [{"label": "A"}]}]},
        }
        for name, ti in cases.items():
            with self.subTest(name):
                self.read_only(ti)

    def test_a_single_choice_label_may_hold_a_comma(self):
        ti = {"questions": [{"question": "Where?", "header": "Place", "multiSelect": False,
                             "options": [{"label": "Paris, France"}, {"label": "Rome"}]}]}
        out = self.ask(ti, ans=answer(["Paris, France"]))
        self.assertEqual(json.loads(out)["hookSpecificOutput"]["decision"]["updatedInput"]["answers"],
                         {"Where?": "Paris, France"})

    def test_other_input_fields_are_kept(self):
        ti = dict(QUESTIONS, metadata={"source": "x"})
        out = self.ask(ti, ans=answer(["Postgres"], ["Search"]))
        self.assertEqual(json.loads(out)["hookSpecificOutput"]["decision"]["updatedInput"]["metadata"],
                         {"source": "x"})

    def test_only_claudes_ask_user_question(self):
        # A plan, a command: never answered here (and the notify entry posts their cards).
        for tool, ti in (("ExitPlanMode", {"plan": "1. do it"}), ("Bash", {"command": "ls"})):
            with self.subTest(tool=tool):
                self.assertEqual(self.ask(ti, tool=tool, ans=answer(["SQLite"], ["Auth"])), "")
                self.assertEqual(self.calls(), [])
        # Grok runs the Claude hooks too; it has no AskUserQuestion of its own.
        self.assertEqual(self.ask(ans=answer(["SQLite"], ["Auth"]), GROK_HOOK_EVENT="PermissionRequest"), "")
        self.assertEqual(self.calls(), [])
        # Not opted in: nothing at all, and Claude's own dialog is untouched.
        self.assertEqual(self.ask(ans=answer(["SQLite"], ["Auth"]), NEEDS_YOU_AGENT_ALERTS="0"), "")
        self.assertEqual(self.calls(), [])

    def test_a_cli_or_hub_that_refuses_the_question_field_waits_for_nothing(self):
        old = os.path.join(self.home, "old-needs-you")
        with open(old, "w") as fh:
            fh.write("#!/usr/bin/env python3\nimport json, os, sys\n"
                     "with open(os.environ['FAKE_CLI_LOG'], 'a') as fh:\n"
                     "    fh.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                     "sys.exit(2 if any(a.startswith('--question-json') for a in sys.argv) else 0)\n")
        os.chmod(old, 0o755)
        self.assertEqual(self.ask(ans=answer(["SQLite"], ["Auth"]), NEEDS_YOU_BIN=old), "")
        self.assertEqual(self.waits(), [])
        self.assertTrue(has_opt(self.adds()[-1], "--steps-json"))  # the choices as steps instead

    def test_no_post_no_wait(self):
        failing = os.path.join(self.home, "down-needs-you")
        with open(failing, "w") as fh:
            fh.write("#!/bin/sh\necho \"$@\" >> \"$FAKE_CLI_LOG\"\nexit 1\n")
        os.chmod(failing, 0o755)
        self.assertEqual(self.ask(ans=answer(["SQLite"], ["Auth"]), NEEDS_YOU_BIN=failing), "")
        self.assertFalse(os.path.exists(os.path.join(self.state, "sess-1234-abcd")))


class HooksJson(unittest.TestCase):
    def test_ask_user_question_has_its_own_waiting_entry(self):
        with open(HOOKS_JSON) as fh:
            groups = json.load(fh)["hooks"]["PermissionRequest"]
        notify = [g for g in groups if g["hooks"][0]["command"].endswith(" notify")]
        ask = [g for g in groups if g["hooks"][0]["command"].endswith(" ask")]
        self.assertEqual((len(notify), len(ask), len(groups)), (1, 1, 2))
        # Claude Code tests a matcher that isn't a plain name list as a JavaScript RegExp
        # against the tool name; Python's re reads this one the same way.
        m = notify[0]["matcher"]
        for tool in ("Bash", "Edit", "ExitPlanMode", "mcp__x__y", "AskUserQuestions", "XAskUserQuestion"):
            self.assertTrue(re.search(m, tool), tool)
        self.assertIsNone(re.search(m, "AskUserQuestion"))
        self.assertTrue(notify[0]["hooks"][0]["async"])
        self.assertEqual(ask[0]["matcher"], "AskUserQuestion")
        h = ask[0]["hooks"][0]
        self.assertFalse(h.get("async", False))  # Claude reads its decision
        self.assertGreater(h["timeout"], 3600)  # past the longest NEEDS_YOU_ANSWER_TIMEOUT


class Upgrade(unittest.TestCase):
    """An install from before B3 (one PermissionRequest entry, every tool, async) becomes the
    two entries; the person's own hooks stay; uninstall puts the file back as it was."""

    def test_old_entry_is_replaced_and_uninstall_restores(self):
        tmp = tempfile.mkdtemp(prefix="ny-ccans-up-")
        self.addCleanup(shutil.rmtree, tmp, True)
        settings = os.path.join(tmp, "claude", "settings.json")
        os.makedirs(os.path.dirname(settings))
        mine = {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/my-guard"}]}
        old = {"hooks": [{"type": "command", "command": '"%s/claude/hooks/needs-you-hook.sh" notify' % tmp,
                          "async": True, "timeout": 30}]}
        original = json.dumps({"model": "x", "hooks": {"PermissionRequest": [mine]}}, indent=2) + "\n"
        with open(settings, "w") as fh:
            fh.write(original)
        installer = os.path.join(ROOT, "integrations", "claude-code", "install-hooks.sh")
        env = {"HOME": tmp, "PATH": os.environ.get("PATH", "")}

        def run(*args):
            r = subprocess.run([BASH, installer, "--settings", settings] + list(args), env=env,
                               capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

        run()
        with open(settings) as fh:
            doc = json.load(fh)
        doc["hooks"]["PermissionRequest"].insert(1, old)  # as a pre-B3 install left it
        with open(settings, "w") as fh:
            json.dump(doc, fh, indent=2)
        run()
        with open(settings) as fh:
            groups = json.load(fh)["hooks"]["PermissionRequest"]
        self.assertEqual(groups[0], mine)
        self.assertEqual([g.get("matcher") for g in groups[1:]], ["^(?!AskUserQuestion$)", "AskUserQuestion"])
        self.assertEqual([g["hooks"][0]["command"].split()[-1] for g in groups[1:]], ["notify", "ask"])
        run("--uninstall")
        with open(settings) as fh:
            self.assertEqual(json.load(fh), json.loads(original))


class EndToEnd(HubTestCase):
    """The real CLI against a test hub: a click answers Claude; a terminal answer (PostToolUse
    resolves the card) ends the wait at once."""

    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        self.cwd = os.path.join(self.home, "src", "my-repo")
        os.makedirs(self.cwd)
        self.hub = self.make_hub("hub-a", peers=[])
        self.sender, self.reader = self.tokens(self.hub)

    def env(self):
        return {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_BIN": CLI,
                "NEEDS_YOU_URLS": self.hub.url, "NEEDS_YOU_TOKEN": self.sender, "NEEDS_YOU_TIMEOUT": "2",
                "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_HOOK_PLATFORM": "linux"}

    def payload(self, event, **more):
        p = {"session_id": "e2e-sess", "cwd": self.cwd, "hook_event_name": event}
        p.update(more)
        return json.dumps(p)

    def start_ask(self):
        path = os.path.join(self.tmp, "ask.json")
        with open(path, "w") as fh:
            fh.write(self.payload("PermissionRequest", tool_name="AskUserQuestion", tool_input=QUESTIONS))
        with open(path) as stdin:
            proc = subprocess.Popen([BASH, HOOK, "ask"], stdin=stdin, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, env=self.env(), text=True, start_new_session=True)

        def stop():
            try:
                os.killpg(proc.pid, signal.SIGKILL)  # the hook and its CLI
            except OSError:
                pass
            proc.communicate()
        self.addCleanup(stop)
        return proc

    def item(self):
        _, body = request("GET", self.hub.url + "/v1/items?status=all", self.reader)
        got = [i for i in body["items"] if i["key"].endswith(":e2e-sess")]
        return got[0] if got else None

    def waiting(self):
        it = self.item()
        return it is not None and (it.get("question") or {}).get("answerable") is True

    def test_a_click_answers_claude(self):
        proc = self.start_ask()
        self.assertTrue(wait_until(self.waiting, timeout=15))
        it = self.item()
        st, body = request("POST", self.hub.url + "/v1/items/%s/answer" % it["id"], self.reader, {
            "question_id": it["question"]["id"], "content_updated_at": it["content_updated_at"],
            "answers": [{"selected": ["Postgres"]}, {"selected": ["Search", "Auth"]}]})
        self.assertEqual(st, 200, body)
        out, err = proc.communicate(timeout=30)
        self.assertEqual((proc.returncode, err), (0, ""))
        self.assertEqual(json.loads(out)["hookSpecificOutput"]["decision"]["updatedInput"]["answers"],
                         {"Which database should we use?": "Postgres", "Which features?": "Auth, Search"})

    def test_an_answer_in_the_terminal_ends_the_wait(self):
        proc = self.start_ask()
        self.assertTrue(wait_until(self.waiting, timeout=15))
        t0 = time.time()
        # Claude took the terminal's answer: PostToolUse for AskUserQuestion runs `resolve`.
        r = subprocess.run([BASH, HOOK, "resolve"], input=self.payload(
            "PostToolUse", tool_name="AskUserQuestion", tool_input=QUESTIONS),
            env=self.env(), capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        out, err = proc.communicate(timeout=30)
        self.assertLess(time.time() - t0, 10)
        self.assertEqual((proc.returncode, out, err), (0, "", ""))
        self.assertEqual(self.item()["status"], "resolved")


if __name__ == "__main__":
    unittest.main()
