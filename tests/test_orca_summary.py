"""`needs-you orca`: the read-only summary of Orca's worktrees for agents, against a fake
`orca` on PATH that serves canned `worktree ps --json` and `environment list --json`.
Temporary HOME; nothing is posted and the outbox is never touched."""
from __future__ import annotations

import json
import os
import sys
import textwrap

from test_cli import CliTestCase

FAKE_ORCA = textwrap.dedent('''\
    #!%s
    import json, os, sys
    d = os.environ["FAKE_ORCA_DIR"]
    args = sys.argv[1:]
    with open(os.path.join(d, "calls.jsonl"), "a") as fh:
        fh.write(json.dumps(args) + "\\n")
    env = args[args.index("--environment") + 1] if "--environment" in args else "local"
    if os.path.exists(os.path.join(d, "fail-" + env)):
        sys.stderr.write("orca: no runtime for %%s\\n" %% env)
        sys.exit(1)
    if args[:2] == ["environment", "list"]:
        name = "environments.json"
    elif args[:2] == ["worktree", "ps"]:
        name = "ps-%%s.json" %% env
    else:
        sys.exit(2)
    with open(os.path.join(d, name)) as fh:
        sys.stdout.write(fh.read())
''') % sys.executable

ROW = {"workspaceKind": "git", "worktreeId": "repo1::/home/u/src/app", "repoId": "repo1", "hostId": "local",
       "terminalPlatform": "linux", "repo": "app", "path": "/home/u/src/app", "branch": "main",
       "isArchived": False, "isMainWorktree": True, "displayName": "app", "workspaceStatus": "in-progress",
       "lastActivityAt": 1791450000000, "linkedPR": None, "comment": "secret plan", "unread": False,
       "liveTerminalCount": 1, "preview": "$ export TOKEN=abc", "status": "active", "agents": []}


def ps(rows, hosts=("local",), omitted=(), truncated=False):
    return {"id": "local", "ok": True, "result": {"worktrees": rows, "hostScope": {
        "hostIds": list(hosts), "omittedHostIds": list(omitted)}, "totalCount": len(rows), "truncated": truncated},
        "_meta": {"runtimeId": "local"}}


class OrcaSummary(CliTestCase):
    def setUp(self):
        super().setUp()
        self.odir = os.path.join(self.tmp, "orca")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.odir)
        os.makedirs(self.bin)
        with open(os.path.join(self.bin, "orca"), "w") as fh:
            fh.write(FAKE_ORCA)
        os.chmod(os.path.join(self.bin, "orca"), 0o755)
        self.write("environments.json", {"ok": True, "result": {"environments": []}})

    def write(self, name, data):
        with open(os.path.join(self.odir, name), "w") as fh:
            fh.write(data if isinstance(data, str) else json.dumps(data))

    def orca(self, *args, path=None):
        return self.run_cli("orca", *args, extra_env={"PATH": path or (self.bin + ":/usr/bin:/bin"),
                                                      "FAKE_ORCA_DIR": self.odir})

    def calls(self):
        with open(os.path.join(self.odir, "calls.jsonl")) as fh:
            return [json.loads(line) for line in fh]

    def test_plain_lines_and_json(self):
        feature = dict(ROW, branch="feature-x", displayName="Feature X", isMainWorktree=False, unread=True,
                       liveTerminalCount=2, agents=[{"kind": "claude"}], linkedPR={"number": 42, "url": "https://x"},
                       workspaceStatus="in-review", status="inactive")
        archived = dict(ROW, branch="old", displayName="old", isArchived=True)
        self.write("ps-local.json", ps([ROW, feature, archived]))
        r = self.orca()
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertEqual(lines[0], "local  app (main)  in-progress · active · 1 terminal")
        self.assertEqual(lines[1], "local  Feature X (feature-x)  in-review · inactive · 2 terminals · 1 agent · "
                                   "unread · PR #42")
        self.assertEqual(lines[2], "scope local: local")
        self.assertEqual(len(lines), 3)  # the archived row is left out
        for never in ("secret plan", "TOKEN", "/home/u", "https://x"):
            self.assertNotIn(never, r.stdout)
        self.assertEqual(self.calls(), [["worktree", "ps", "--json"]])

        r = self.orca("--json", "--archived", "--limit", "5")
        d = json.loads(r.stdout)
        self.assertTrue(d["ok"])
        self.assertEqual([w["branch"] for w in d["worktrees"]], ["main", "feature-x", "old"])
        self.assertEqual(d["worktrees"][1], {
            "environment": "", "host": "local", "name": "Feature X", "branch": "feature-x", "repo": "app",
            "workspace_status": "in-review", "status": "inactive", "live_terminals": 2, "unread": True,
            "agents": 1, "pr": 42, "last_activity": "2026-10-08T09:00:00Z"})
        self.assertNotIn("preview", r.stdout)
        self.assertEqual(self.calls()[-1], ["worktree", "ps", "--limit", "5", "--json"])

    def test_untrusted_text_is_one_clean_line(self):
        evil = dict(ROW, displayName="x\x1b]8;;https://evil.example/\x07click‮\nme" + "y" * 200,
                    branch="b​c", hostId={"no": "dict"}, liveTerminalCount="3", lastActivityAt=True,
                    linkedPR="https://evil.example/pr", unknownField={"nested": [1, 2]})
        self.write("ps-local.json", ps([evil, "not a row", None]))
        r = self.orca()
        self.assertEqual(r.returncode, 0, r.stderr)
        line = r.stdout.splitlines()[0]
        for bad in ("\x1b", "\x07", "‮", "​", "\n"):
            self.assertNotIn(bad, line)
        self.assertIn("…", line)
        self.assertIn("0 terminals", line)
        self.assertNotIn("PR #", line)
        self.assertTrue(line.startswith("?  x ]8;;https://evil.example/ click me"), line)
        d = json.loads(self.orca("--json").stdout)
        self.assertEqual(len(d["worktrees"]), 1)
        self.assertEqual(d["worktrees"][0]["host"], "")
        self.assertLessEqual(len(d["worktrees"][0]["name"]), 60)

    def test_environments(self):
        self.write("ps-local.json", ps([ROW]))
        self.write("ps-My Devbox.json", ps([dict(ROW, hostId="devbox-host", branch="dev", displayName="dev")],
                                           hosts=("devbox-host",), omitted=("laptop",), truncated=True))
        self.write("environments.json", {"ok": True, "result": {"environments": [
            {"name": "My Devbox"}, {"name": "bad;name"}, "My Devbox", {"id": "gone"}]}})
        open(os.path.join(self.odir, "fail-gone"), "w").close()
        r = self.orca("--all")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("My Devbox/devbox-host  dev  in-progress", r.stdout)
        self.assertIn("scope My Devbox: devbox-host; not covered: laptop; more rows than shown (--limit)", r.stdout)
        self.assertIn("gone: orca worktree ps exited 1: orca: no runtime for gone", r.stderr)
        envs = [c[c.index("--environment") + 1] if "--environment" in c else "" for c in self.calls()
                if c[:2] == ["worktree", "ps"]]
        self.assertEqual(envs, ["", "My Devbox", "gone"])  # "bad;name" is never passed on

        r = self.orca("--environment", "My Devbox", "--json")
        d = json.loads(r.stdout)
        self.assertEqual([w["environment"] for w in d["worktrees"]], ["My Devbox"])
        self.assertEqual(self.orca("--environment", "-x;rm").returncode, 2)

    def test_orca_missing_or_failing(self):
        r = self.orca(path="/usr/bin:/bin")
        self.assertEqual(r.returncode, 1)
        self.assertIn("orca is not on PATH", r.stderr)
        self.assertEqual(json.loads(self.orca("--json", path="/usr/bin:/bin").stdout)["ok"], False)
        open(os.path.join(self.odir, "fail-local"), "w").close()
        r = self.orca()
        self.assertEqual(r.returncode, 1)
        self.assertIn("orca worktree ps exited 1", r.stderr)
        os.remove(os.path.join(self.odir, "fail-local"))
        self.write("ps-local.json", "garbage")
        self.assertEqual(self.orca().returncode, 1)
        self.write("ps-local.json", {"ok": False, "error": {"message": "runtime not running"}})
        r = self.orca()
        self.assertIn("runtime not running", r.stderr)
        self.write("ps-local.json", ps([]))
        r = self.orca()
        self.assertEqual(r.returncode, 0)
        self.assertIn("no worktrees", r.stdout)

    def test_never_touches_the_outbox_or_a_hub(self):
        self.write("ps-local.json", ps([ROW]))
        r = self.run_cli("orca", urls=[self.dead], extra_env={"PATH": self.bin + ":/usr/bin:/bin",
                                                               "FAKE_ORCA_DIR": self.odir})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.queued(), [])


if __name__ == "__main__":
    import unittest
    unittest.main()
