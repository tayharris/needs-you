"""A base for tests that run the shared needs-you-hook.sh in one agent's mode against a fake
needs-you CLI (which logs its argv) in a temporary HOME. The real ~/.claude, ~/.cursor,
~/Documents/Cline, ~/.aider*, ~/.config and the crontab are never touched."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest

from support import ROOT, wait_until

BASH = shutil.which("bash") or "/bin/bash"
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
REAL_HOME = os.path.expanduser("~")

FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
"""

SECRET = "sk-test-SECRET-0123456789"


def opt(argv, name):
    for i, a in enumerate(argv):
        if a.startswith(name + "="):
            return a[len(name) + 1:]
        if a == name:
            return argv[i + 1]
    raise ValueError(name)


def has_opt(argv, name):
    try:
        opt(argv, name)
        return True
    except (ValueError, IndexError):
        return False


class HookCase(unittest.TestCase):
    AGENT = ""

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-%s-" % self.AGENT)
        self.addCleanup(shutil.rmtree, self.home, True)
        self.assertNotEqual(self.home, REAL_HOME)
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
               "NEEDS_YOU_HOOK_PLATFORM": "linux", "NY_TURN_WAIT": "0"}
        env.update(extra)
        return env

    def run_hook(self, args, payload, cwd=None, **extra):
        """Run the hook with `args` (mode, agent, ...) and the payload as stdin (a dict is sent as
        JSON). Returns the CompletedProcess; the hook must exit 0 within 5 seconds (2 s was
        too tight on a loaded CI Mac; 5 s still catches a hook that waits instead of returning)."""
        started = time.time()
        stdin = payload if isinstance(payload, str) else json.dumps(payload)
        r = subprocess.run([BASH, HOOK] + list(args), input=stdin, env=self.env(**extra),
                           capture_output=True, text=True, timeout=30, cwd=cwd or self.cwd)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, "")
        self.assertLess(time.time() - started, 5)
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

    def marker(self, sid):
        return os.path.join(self.state, sid)

    def wait_marker(self, sid, present=True):
        self.assertTrue(wait_until(lambda: os.path.exists(self.marker(sid)) == present, timeout=10),
                        "marker %s %s" % (sid, "missing" if present else "still there"))

    def read_marker(self, sid):
        with open(self.marker(sid)) as fh:
            return dict(l.rstrip("\n").split("=", 1) for l in fh if "=" in l)

    def gone_pid(self):
        p = subprocess.Popen(["true"])
        p.wait()
        return str(p.pid)


FIXTURES = os.path.join(ROOT, "tests", "fixtures", "questions")


def fixture(name):
    """A captured (or source-derived) question payload from tests/fixtures/questions."""
    with open(os.path.join(FIXTURES, name)) as fh:
        return json.load(fh)


def posted_item(argv):
    """The item a hook's `needs-you add` argv would post, checked by the hub's own validation
    (title, body and step limits, no control characters). Returns the normalised fields."""
    from support import hubmod
    item = {"title": opt(argv, "--title"), "body": opt(argv, "--body"), "kind": "needs"}
    if has_opt(argv, "--steps-json"):
        item["steps"] = json.loads(opt(argv, "--steps-json"))
    if has_opt(argv, "--question-json"):
        item["question"] = json.loads(opt(argv, "--question-json"))
    return hubmod.validate_item_input(item)


def step_texts(argv):
    return [s["text"] for s in posted_item(argv)["steps"]]


def choice_texts(argv):
    """A question card's choices as "Header: Label — description" (the header only when
    there are several questions), from its `question` field as the hub would store it."""
    q = posted_item(argv)["question"]
    out = []
    for item in q["items"] if q else []:
        prefix = item["header"] + ": " if len(q["items"]) > 1 and item["header"] else ""
        for o in item["options"]:
            out.append(prefix + o["label"] + (" — " + o["description"] if o["description"] else ""))
    return out
