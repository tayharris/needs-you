"""docs/guides/custom-connector.md: the field facts match the hub, the documented CLI flags
exist, and the page's examples (the curl post, the shell hook, the webhook relay, the
notification command, the local test hub) run against a real hub and exit 0.

Every example runs with a temporary HOME holding its own env file, so the real
~/.config/needs-you is never read or written.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from typing import Dict, List, Optional

from support import CLI, OPENER, ROOT, HubTestCase, free_port, hubmod, request, wait_until

GUIDE = os.path.join(ROOT, "docs", "guides", "custom-connector.md")
BASH = shutil.which("bash") or "/bin/bash"
CURL = shutil.which("curl")


def read_guide() -> str:
    with open(GUIDE, encoding="utf-8") as fh:
        return fh.read()


def blocks() -> Dict[str, str]:
    """The fenced code block after each `<!-- test:NAME -->` marker, by NAME."""
    out = {}
    for m in re.finditer(r"<!-- test:([\w.-]+) -->\n```[a-z]*\n(.*?)\n```\n", read_guide(), re.S):
        out[m.group(1)] = m.group(2) + "\n"
    return out


def flags_in(text: str) -> List[str]:
    return sorted(set(re.findall(r"`(--[a-z][a-z-]*)", text)))


class GuideMatchesHub(unittest.TestCase):
    """The numbers and value lists in the guide come from the hub's constants."""

    def setUp(self):
        self.text = read_guide()

    def has(self, s: str) -> None:
        self.assertIn(s, self.text, "custom-connector.md should say %r (from the hub's constants)" % s)

    def test_limits(self):
        h = hubmod
        self.has("1–%d characters; one line" % h.MAX_TITLE)
        self.has("at most %d characters from" % h.MAX_KEY)
        self.has("at most {:,} characters; markdown".format(h.MAX_BODY))
        self.has("at most %d `{\"label\", \"url\"}` objects" % h.MAX_LINKS)
        self.has("`label` 1–%d characters, `url` 1–{:,} characters".format(h.MAX_LINK_URL) % h.MAX_LINK_LABEL)
        self.has("at most %d step objects" % h.MAX_STEPS)
        self.has("1–%d characters, one line, inline markdown" % h.MAX_STEP_TEXT)
        self.has("each a string of at most %d characters" % h.MAX_SOURCE_FIELD)
        self.has("at most %d KiB" % (h.MAX_REQUEST_BYTES // 1024))
        self.has("Body over %d KiB" % (h.MAX_REQUEST_BYTES // 1024))
        self.has("already has %d open items" % h.DEFAULT_MAX_OPEN_PER_TOKEN)
        self.has("now + %d h" % h.DEFAULT_EXPIRY_HOURS)

    def test_value_lists(self):
        def one_of(values):
            quoted = ["`%s`" % v for v in values]
            return ", ".join(quoted[:-1]) + " or " + quoted[-1]
        self.has(one_of(hubmod.KINDS) + " (any case)")
        self.has(one_of(hubmod.PRIORITIES) + " (any case)")
        self.has(one_of(hubmod.CONTEXTS) + " (any case)")
        self.has(", ".join("`%s`" % s for s in hubmod.LINK_SCHEMES) + ". Everything else is a 400")

    def test_key_characters(self):
        # The guide spells the class out as `A-Z a-z 0-9 . _ : - / @ # + =`; if the hub's
        # pattern changes, change the guide (and docs/API.md) with it.
        self.assertEqual(hubmod.KEY_RE.pattern, r"^[A-Za-z0-9._:/@#+=-]+$")
        self.has("`A-Z a-z 0-9 . _ : - / @ # + =`")

    def test_documented_behaviour(self):
        v = hubmod.validate_item_input
        out = v({"title": " t ", "kind": "DONE", "priority": "Urgent", "context": "PERSONAL",
                 "key": None, "body": None, "links": None, "steps": None, "source": None,
                 "expires_at": None, "made_up": 1})
        self.assertEqual((out["title"], out["kind"], out["priority"], out["context"], out["key"]),
                         ("t", "done", "urgent", "personal", None))
        for bad, field in (({"title": "t", "key": ""}, "key"), ({"title": "t", "status": None}, "status"),
                           ({"title": "a\tb"}, "title"),
                           ({"title": "t", "steps": [{"text": "a", "done": "yes"}]}, "steps[0].done")):
            with self.assertRaises(hubmod.ApiError) as cm:
                v(bad)
            self.assertEqual((cm.exception.status, cm.exception.field), (400, field))
        v({"title": "t", "body": "line\n\ttab", "expires_at": 1999999999})
        v({"title": "t", "expires_at": "2026-10-08T17:00:00+02:00"})

    def test_cli_flags_exist(self):
        def help_of(*cmd):
            r = subprocess.run([sys.executable, CLI] + list(cmd) + ["--help"], capture_output=True, text=True,
                               timeout=30, env={"PATH": os.environ.get("PATH", ""), "HOME": tempfile.gettempdir()})
            return r.stdout
        section = self.text.split("### `POST /v1/items` (sender token)", 1)[1].split("### Errors", 1)[0]
        known = help_of("add") + help_of("resolve") + help_of("--json")
        for flag in flags_in(section):
            self.assertIn(flag, known, "the guide documents %s, which the CLI doesn't have" % flag)

    def test_every_example_is_marked(self):
        self.assertEqual(sorted(blocks()), ["acme-needs-you.sh", "curl-post", "local-hub",
                                            "needs-you-notify.sh", "needs-you-relay.py"])


class Examples(HubTestCase):
    def setUp(self):
        super().setUp()
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(self.home, ".config", "needs-you"))
        self.write_env(self.hub.url)
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        os.symlink(CLI, os.path.join(self.bin, "needs-you"))
        self.blocks = blocks()

    def write_env(self, url: str) -> None:
        path = os.path.join(self.home, ".config", "needs-you", "env")
        with open(path, "w") as fh:
            fh.write("NEEDS_YOU_URLS=%s\nNEEDS_YOU_URL=%s\nNEEDS_YOU_TOKEN=%s\nNEEDS_YOU_TIMEOUT=1\n"
                     % (url, url, self.sender))
        os.chmod(path, 0o600)

    def env(self, **extra: str) -> Dict[str, str]:
        e = {"PATH": self.bin + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home}
        e.update(extra)
        return e

    def script(self, name: str) -> str:
        path = os.path.join(self.tmp, name)
        with open(path, "w") as fh:
            fh.write(self.blocks[name])
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        return path

    def items(self) -> List[dict]:
        return request("GET", self.hub.url + "/v1/items?status=all", self.reader)[1]["items"]

    def item(self, key: str, status: Optional[str] = None) -> Optional[dict]:
        found = {}

        def check():
            for it in self.items():
                if it["key"] == key and (status is None or it["status"] == status):
                    found["it"] = it
                    return True
            return False
        wait_until(check, timeout=15)
        return found.get("it")

    def run_script(self, path: str, stdin: str = "", cwd: Optional[str] = None, args=(), **env: str):
        start = time.time()
        r = subprocess.run([BASH, path] + list(args), input=stdin, capture_output=True, text=True,
                           timeout=30, env=self.env(**env), cwd=cwd or self.tmp)
        return r, time.time() - start

    # -- the curl post ------------------------------------------------------

    def test_curl_post_payload_is_valid(self):
        payload = re.search(r"--data-binary '(.*?)'", self.blocks["curl-post"], re.S).group(1)
        status, out = request("POST", self.hub.url + "/v1/items", self.sender, json.loads(payload))
        self.assertEqual(status, 201, out)
        self.assertEqual((out["priority"], out["links"][0]["url"]), ("urgent", "https://ci.example.com/runs/812"))

    @unittest.skipUnless(CURL, "needs curl")
    def test_curl_post_runs(self):
        r = subprocess.run([BASH, "-c", self.blocks["curl-post"]], capture_output=True, text=True,
                           timeout=30, env=self.env())
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(self.sender, r.stdout + r.stderr)
        self.assertEqual(json.loads(r.stdout)["key"], "acme-ci:deploy:approval")

    # -- example (a): the shell hook ------------------------------------------

    def test_hook_posts_updates_and_resolves(self):
        hook = self.script("acme-needs-you.sh")
        app = os.path.join(self.tmp, "src", "app")
        ev = {"session_id": "3f9c:2a/x", "cwd": app, "tool": "git push --force origin main"}
        r, took = self.run_script(hook, json.dumps(dict(ev, event="permission_request")))
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.assertLess(took, 5)
        key = None

        def posted():
            nonlocal key
            for i in self.items():
                if i["key"].startswith("acme-agent:") and i["key"].endswith(":3f9c_2a_x:waiting"):
                    key = i["key"]
                    return True
            return False
        self.assertTrue(wait_until(posted))
        it = self.item(key)
        self.assertEqual(it["title"], "acme-agent wants to run git: app")  # first word only
        self.assertEqual((it["kind"], it["priority"], it["source"]["agent"], it["source"]["project"]),
                         ("needs", "normal", "acme-agent", "app"))
        self.assertIsNotNone(it["expires_at"])

        self.run_script(hook, json.dumps(dict(ev, event="waiting_for_input")))
        self.assertTrue(wait_until(lambda: self.item(key)["title"] == "acme-agent is waiting for you: app"))
        self.assertEqual(len([i for i in self.items() if i["key"] == key]), 1)  # one card, updated

        self.run_script(hook, json.dumps(dict(ev, event="tool_started")))  # ignored
        time.sleep(0.5)
        self.assertEqual(self.item(key)["status"], "open")
        self.run_script(hook, json.dumps({"event": "user_prompt", "session_id": ev["session_id"]}))
        self.assertIsNotNone(self.item(key, "resolved"))

    def test_hook_hostile_text_still_posts(self):
        hook = self.script("acme-needs-you.sh")
        ev = {"event": "error", "session_id": "s1", "cwd": "/tmp/" + "p" * 200 + "‮\x01",
              "tool": "--evil\x07"}
        r, _ = self.run_script(hook, json.dumps(ev))
        self.assertEqual(r.returncode, 0)
        self.assertTrue(wait_until(lambda: any(i["key"].endswith(":s1:waiting") for i in self.items())))

    def test_hook_never_fails(self):
        hook = self.script("acme-needs-you.sh")
        for stdin in ("", "not json", "[1, 2]", '{"event": "permission_request"}'):
            r, _ = self.run_script(hook, stdin)
            self.assertEqual((r.returncode, r.stdout), (0, ""), stdin)
        self.write_env("http://127.0.0.1:%d" % free_port())  # no hub there
        r, took = self.run_script(hook, json.dumps({"event": "error", "session_id": "down", "cwd": "/x"}))
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        self.assertLess(took, 5)
        outbox = os.path.join(self.home, ".local", "state", "needs-you", "outbox")
        self.assertTrue(wait_until(lambda: os.path.isdir(outbox) and any(
            n.endswith(".json") for n in os.listdir(outbox))), "the post should queue in the outbox")

    # -- example (b): the webhook relay --------------------------------------

    def start_relay(self) -> str:
        path = os.path.join(self.tmp, "needs-you-relay.py")
        with open(path, "w") as fh:
            fh.write(self.blocks["needs-you-relay.py"])
        port = free_port()
        proc = subprocess.Popen([sys.executable, path], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL,
                                env=self.env(NEEDS_YOU_RELAY_SECRET="relay-test-secret",
                                             NEEDS_YOU_RELAY_PORT=str(port)))
        self.addCleanup(proc.wait, 10)
        self.addCleanup(proc.terminate)

        def up():
            try:
                socket.create_connection(("127.0.0.1", port), 0.2).close()
                return True
            except OSError:
                return False
        self.assertTrue(wait_until(up, 10))
        return "http://127.0.0.1:%d/" % port

    def hook(self, url: str, body, secret: Optional[str] = "relay-test-secret") -> int:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method="POST")
        if secret is not None:
            req.add_header("X-Relay-Secret", secret)
        try:
            with OPENER.open(req, timeout=5) as resp:
                return resp.status
        except urllib.error.HTTPError as e:
            return e.code

    def test_relay(self):
        url = self.start_relay()
        self.assertEqual(self.hook(url, {"event": "run.failed"}, secret=None), 401)
        self.assertEqual(self.hook(url, {"event": "run.failed"}, secret="wrong"), 401)
        self.assertEqual(self.hook(url, b"not json"), 400)
        self.assertEqual(self.hook(url, [1]), 400)

        run = "https://ci.example.com/runs/812"
        self.assertEqual(self.hook(url, {"event": "approval.requested", "pipeline": "app",
                                         "url": run, "summary": "Staging is green."}), 202)
        it = self.item("acme-ci:app:approval")
        self.assertIsNotNone(it)
        self.assertEqual((it["title"], it["priority"], it["links"]),
                         ("Approve the app deploy", "urgent", [{"label": "Run", "url": run}]))
        self.assertEqual(self.hook(url, {"event": "approval.approved", "pipeline": "app"}), 202)
        self.assertIsNotNone(self.item("acme-ci:app:approval", "resolved"))

        # A URL the hub refuses (a space): the card still posts, without the link.
        self.hook(url, {"event": "run.failed", "pipeline": "nightly", "url": "https://ci.example.com/a b"})
        it = self.item("acme-ci:nightly:failed")
        self.assertIsNotNone(it)
        self.assertEqual((it["title"], it["links"]), ("nightly failed", []))
        self.hook(url, {"event": "run.started", "pipeline": "nightly"})  # ignored
        self.hook(url, {"event": "run.succeeded", "pipeline": "nightly"})
        self.assertIsNotNone(self.item("acme-ci:nightly:failed", "resolved"))

    # -- example (c): the notification command -------------------------------

    def test_notify_command(self):
        notify = self.script("needs-you-notify.sh")
        work = os.path.join(self.tmp, "my-repo")
        os.makedirs(work)
        for _ in range(2):
            r, took = self.run_script(notify, cwd=work, args=["aider"])
            self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
            self.assertLess(took, 5)
        self.assertTrue(wait_until(lambda: any(i["key"].startswith("aider:") for i in self.items())))
        time.sleep(0.5)
        cards = [i for i in self.items() if i["key"].startswith("aider:")]
        self.assertEqual(len(cards), 1, "the second wait updates the same card")
        self.assertEqual(cards[0]["title"], "aider is waiting for you: my-repo")
        self.assertRegex(cards[0]["key"], r"^aider:[A-Za-z0-9._-]+:[0-9]+:waiting$")
        self.assertIsNotNone(cards[0]["expires_at"])

        self.write_env("http://127.0.0.1:%d" % free_port())
        r, took = self.run_script(notify, cwd=work)
        self.assertEqual(r.returncode, 0)
        self.assertLess(took, 5)

    # -- section 5: the local test hub ----------------------------------------

    def test_local_hub_block(self):
        port = free_port()
        ny_test = os.path.join(self.tmp, "ny-test")
        os.makedirs(ny_test)
        block = self.blocks["local-hub"].replace("18765", str(port))
        block = block.replace("export NY_TEST=$(mktemp -d)", "export NY_TEST=%s" % ny_test)
        block += 'echo $! > "$NY_TEST/hub.pid"\n'
        out_path = os.path.join(self.tmp, "block.out")
        with open(out_path, "w") as out:  # files, not pipes: the hub it starts keeps them open
            r = subprocess.run([BASH, "-c", block], stdin=subprocess.DEVNULL, stdout=out, stderr=out,
                               timeout=60, cwd=ROOT,
                               env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home})
        with open(os.path.join(ny_test, "hub.pid")) as fh:
            pid = int(fh.read())
        self.addCleanup(self._kill, pid)
        with open(out_path) as fh:
            output = fh.read()
        self.assertEqual(r.returncode, 0, output)
        with open(os.path.join(ny_test, "sender")) as fh:
            sender = fh.read().strip()
        self.assertTrue(sender.startswith("ny_"))
        self.assertNotIn(sender, output, "the block never prints the token")
        env_file = os.path.join(ny_test, "home", ".config", "needs-you", "env")
        self.assertEqual(stat.S_IMODE(os.stat(env_file).st_mode), 0o600)
        with open(os.path.join(ny_test, "reader")) as fh:
            reader = fh.read().strip()
        test_env = {"PATH": os.environ.get("PATH", ""), "HOME": os.path.join(ny_test, "home")}
        r = subprocess.run([sys.executable, CLI, "add", "--key", "t:1", "--title", "local hub"],
                           capture_output=True, text=True, timeout=30, env=test_env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("created", r.stdout)
        items = request("GET", "http://127.0.0.1:%d/v1/items" % port, reader)[1]["items"]
        self.assertEqual([i["title"] for i in items], ["local hub"])

    @staticmethod
    def _kill(pid: int) -> None:
        try:
            os.kill(pid, 15)
        except OSError:
            pass


if __name__ == "__main__":
    unittest.main()
