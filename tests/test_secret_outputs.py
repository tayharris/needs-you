"""Hard rule 3, end to end: tokens (ny_), invite codes (nyi_) and peer secrets (nyp_) appear in
no log, listing, error message or file, only in the one answer that mints each.

Two real hub processes (access log on) pair with a peer invite, a sender joins with an invite,
items replicate, and every failure path a secret can reach is poked with a real secret. Then
every output (hub logs, admin output, API answers, CLI output, files on disk) is searched for
each secret's value and for anything shaped like one."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

from support import CLI, OPENER, ROOT, free_port, hubmod, request, wait_until

HUB = os.path.join(ROOT, "hub", "needs_you_hub.py")
ADMIN = os.path.join(ROOT, "hub", "needs_you_admin.py")
# Anything shaped like one of our secrets (their alphabet is URL-safe base64).
SHAPE = re.compile(r"(?<![A-Za-z0-9])ny[ip]?_[A-Za-z0-9_-]{16,}")


def get_text(url, token=None, headers=None):
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with OPENER.open(req, timeout=5) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def raw_request(method, url, token=None, body=None, headers=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with OPENER.open(req, timeout=5) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


class SecretOutputs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="needs-you-secrets-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.procs = []
        self.outputs = []  # (where, text): everything that must hold no secret

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()

    def saw(self, where, text):
        self.outputs.append((where, text))
        return text

    # -- processes ------------------------------------------------------------

    def start_hub(self, name):
        d = os.path.join(self.tmp, name)
        os.makedirs(d, mode=0o700)
        port = free_port()
        conf = os.path.join(d, "hub.json")
        with open(conf, "w") as fh:
            json.dump({"bind": ["127.0.0.1"], "port": port, "db": os.path.join(d, "hub.db"),
                       "hub_id": name, "public_url": "http://127.0.0.1:%d" % port, "peers": [],
                       "anti_entropy_seconds": 0.5, "outbox_poll_seconds": 0.1,
                       "retry_base_seconds": 0.05, "retry_max_seconds": 0.3,
                       "maintenance_seconds": 1}, fh)
        log = open(os.path.join(d, "hub.log"), "wb")
        self.addCleanup(log.close)
        p = subprocess.Popen([sys.executable, HUB, "--config", conf], stdin=subprocess.DEVNULL,
                             stdout=log, stderr=subprocess.STDOUT)
        self.procs.append(p)
        url = "http://127.0.0.1:%d" % port

        def up():
            try:
                return get_text(url + "/v1/health")[0] == 200
            except OSError:
                return p.poll() is not None  # it exited: the assert below says so
        self.assertTrue(wait_until(up) and p.poll() is None, "hub %s didn't start" % name)
        return {"name": name, "dir": d, "conf": conf, "url": url, "log": os.path.join(d, "hub.log")}

    def admin(self, hub, *argv, stdin="", mint=False):
        """needs-you-admin; its output is checked unless `mint` (the one answer that shows a secret)."""
        r = subprocess.run([sys.executable, ADMIN, "--config", hub["conf"]] + list(argv), input=stdin,
                           capture_output=True, text=True, timeout=60)
        if not mint:
            self.saw("admin %s stdout" % " ".join(argv), r.stdout)
        self.saw("admin %s stderr" % " ".join(argv), r.stderr)
        return r

    def cli(self, home, *argv, env=None):
        e = {k: v for k, v in os.environ.items() if not k.startswith("NEEDS_YOU_")}
        e.update({"HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"),
                  "XDG_STATE_HOME": os.path.join(home, ".local", "state"), "NEEDS_YOU_GH": "none",
                  "NEEDS_YOU_TIMEOUT": "2"})
        e.update(env or {})
        r = subprocess.run([sys.executable, CLI] + list(argv), stdin=subprocess.DEVNULL, capture_output=True,
                           text=True, timeout=60, env=e)
        self.saw("needs-you %s" % " ".join(argv), r.stdout + r.stderr)
        return r

    # -- the check ------------------------------------------------------------

    def assert_no_secrets(self, secrets):
        found = []
        for where, text in self.outputs:
            where = SHAPE.sub(lambda m: m.group(0)[:6] + "...", where)
            for label, value in secrets.items():
                if value in text:
                    found.append("%s (%s...) in %s" % (label, value[:6], where))
            m = SHAPE.search(text)
            if m and not any(v in text for v in secrets.values()):
                found.append("something shaped like a secret (%s...) in %s" % (m.group(0)[:6], where))
        self.assertEqual(found, [])

    def files_under(self, d):
        for base, _dirs, files in os.walk(d):
            for n in files:
                yield os.path.join(base, n)

    def test_no_secret_in_any_output(self):
        a = self.start_hub("hub-a")
        b = self.start_hub("hub-b")
        secrets = {}

        # The owner token: printed once by `token add` (not checked: that's its one showing).
        r = self.admin(a, "token", "add", "me", "--role", "owner", mint=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        owner = r.stdout.strip()
        self.assertTrue(owner.startswith("ny_"))
        secrets["owner token"] = owner

        # A sender invite and its redeem (each answer is the code's or token's one showing).
        st, inv = request("POST", a["url"] + "/v1/invites", owner, {"name": "box", "role": "sender", "uses": 1})
        self.assertEqual(st, 201, inv)
        secrets["sender invite code"] = inv["code"]
        st, red = request("POST", a["url"] + "/v1/invites/redeem", None, {"code": inv["code"], "host": "devbox"})
        self.assertEqual(st, 200, red)
        sender = red["token"]
        secrets["sender token"] = sender

        # A peer invite from the admin tool (its output is the code's one showing), redeemed by
        # hub-b's admin tool from stdin.
        r = self.admin(a, "invite", "create", "hub-b", "--role", "peer", mint=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        link = re.search(r"https?://\S+/join/nyi_[A-Za-z0-9_-]+", r.stdout).group(0)
        secrets["peer invite code"] = link.rsplit("/", 1)[1]
        r = self.admin(b, "peer", "join", "-", stdin=link + "\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        secrets["peer secret"] = self.peer_secret(b)
        link_id = self.link_id(b)

        # Replication works both ways with the pair's secret.
        st, _ = request("POST", a["url"] + "/v1/items", sender,
                        {"key": "acme:deploy", "title": "Approve the deploy"})
        self.assertEqual(st, 201)
        _st, red_b = request("POST", a["url"] + "/v1/invites/redeem", None, {"code": inv["code"], "host": "x"})
        self.assertTrue(wait_until(lambda: request("GET", b["url"] + "/v1/items", owner)[0] == 200
                                   and request("GET", b["url"] + "/v1/items", owner)[1].get("items")),
                        "the item didn't replicate to hub-b")

        # Every failure a secret can reach, with a real secret in the request.
        wrong = "ny_" + "A" * 43
        self.saw("revoked-shape token", raw_request("GET", a["url"] + "/v1/items", wrong)[1])
        self.saw("sender on an owner endpoint", raw_request("GET", a["url"] + "/v1/tokens", sender)[1])
        self.saw("sender invite on a reader endpoint", raw_request("GET", a["url"] + "/v1/items", inv["code"])[1])
        self.saw("peer secret as a token", raw_request("GET", a["url"] + "/v1/items", secrets["peer secret"])[1])
        self.saw("owner token as a peer secret",
                 raw_request("GET", a["url"] + "/v1/replicate/changes?after=0", owner)[1])
        self.saw("peer secret with another link id",
                 raw_request("GET", a["url"] + "/v1/replicate/changes?after=0", secrets["peer secret"],
                             headers={hubmod.PEER_LINK_HEADER: "pl_someoneelse01"})[1])
        self.saw("peer secret as a link id",
                 raw_request("GET", a["url"] + "/v1/replicate/changes?after=0", secrets["peer secret"],
                             headers={hubmod.PEER_LINK_HEADER: secrets["peer secret"]})[1])
        self.saw("spent invite redeemed again", json.dumps(red_b))
        self.saw("spent peer invite redeemed again",
                 raw_request("POST", a["url"] + "/v1/invites/redeem", None,
                             {"code": secrets["peer invite code"], "host": "x",
                              "peer": {"url": "http://127.0.0.1:1", "hub_id": "hub-z",
                                       "schema": hubmod.SCHEMA_VERSION}})[1])
        self.saw("sender invite used as a peer invite",
                 raw_request("POST", a["url"] + "/v1/invites/redeem", None,
                             {"code": inv["code"], "host": "x", "peer": {"url": 1}})[1])
        self.saw("token as an invite code", raw_request("POST", a["url"] + "/v1/invites/redeem", None,
                                                        {"code": owner, "host": "x"})[1])
        self.saw("token in a query string", get_text(a["url"] + "/v1/items?token=" + sender)[1])
        self.saw("token in a path", get_text(a["url"] + "/v1/items/" + sender, owner)[1])
        self.saw("revoke a token named by its secret",
                 raw_request("DELETE", a["url"] + "/v1/tokens/" + sender, owner)[1])
        self.saw("revoke an invite named by its code",
                 raw_request("DELETE", a["url"] + "/v1/invites/" + inv["code"], owner)[1])
        self.saw("remove a peer named by its secret",
                 raw_request("DELETE", a["url"] + "/v1/peers/" + secrets["peer secret"], owner)[1])
        self.saw("item key that is a token", raw_request("POST", a["url"] + "/v1/items", sender,
                                                         {"key": sender + "!", "title": "x"})[1])
        # A join page names its own code (whoever reads it has the link); nothing else.
        for label, code in (("sender", inv["code"]), ("peer", secrets["peer invite code"])):
            for suffix in ("", "/install.sh"):
                text = get_text(a["url"] + "/join/" + code + suffix)[1]
                self.saw("%s join page%s" % (label, suffix), text.replace(code, "<its code>"))
        self.saw("admin token revoke by secret", self.admin(a, "token", "revoke", sender).stdout)
        self.saw("admin invite revoke by code", self.admin(a, "invite", "revoke", inv["code"]).stdout)
        self.saw("admin peer remove by secret", self.admin(a, "peer", "remove", secrets["peer secret"]).stdout)
        self.saw("admin peer join, spent", self.admin(b, "peer", "join", "-", stdin=link + "\n").stdout)

        # Every listing, on both hubs, with every kind of credential.
        for h in (a, b):
            for path in ("/v1/health", "/v1/tokens", "/v1/invites?all=1", "/v1/peers", "/v1/items",
                         "/v1/items?status=all"):
                self.saw("%s GET %s" % (h["name"], path), get_text(h["url"] + path, owner)[1])
            self.saw("%s GET /v1/health (sender)" % h["name"], get_text(h["url"] + "/v1/health", sender)[1])
            self.saw("%s GET /v1/health (no token)" % h["name"], get_text(h["url"] + "/v1/health")[1])
            for argv in (("token", "list"), ("token", "list", "--json"), ("invite", "list", "--all"),
                         ("invite", "list", "--all", "--json"), ("peer", "list"), ("peer", "list", "--json")):
                self.admin(h, *argv)
        self.saw("hub-a changes feed (as the peer)",
                 get_text(a["url"] + "/v1/replicate/changes?after=0&limit=1000", secrets["peer secret"],
                          {hubmod.PEER_LINK_HEADER: link_id})[1])

        # A sender machine: the CLI with the redeemed token, its hub up and then down.
        home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(home, ".config", "needs-you"), mode=0o700)
        with open(os.path.join(home, ".config", "needs-you", "env"), "w") as fh:
            fh.write("NEEDS_YOU_URLS=%s\nNEEDS_YOU_TOKEN=%s\n" % (b["url"], owner))
        self.cli(home, "--version")
        self.cli(home, "health")
        self.cli(home, "doctor")
        self.cli(home, "post", "--key", "acme:ci", "--title", "CI failed")
        self.cli(home, "resolve", "--key", "acme:ci")
        self.cli(home, "post", "--key", "acme:x", "--title", "x", env={"NEEDS_YOU_URLS": "http://127.0.0.1:1"})
        self.cli(home, "health", env={"NEEDS_YOU_URLS": "http://127.0.0.1:1"})
        self.cli(home, "update", "--check")

        # Let maintenance run once, then stop the hubs so their logs are complete.
        time.sleep(1.5)
        for p in self.procs:
            p.terminate()
            p.wait(timeout=10)
        for h in (a, b):
            with open(h["log"], "r", encoding="utf-8", errors="replace") as fh:
                self.saw("%s log" % h["name"], fh.read())

        # Files: the CLI's state (outbox, update state) and the hubs' directories. A hub's
        # database keeps its own peer secret by design (it has to send it); nothing else.
        env_file = os.path.join(home, ".config", "needs-you", "env")
        for path in self.files_under(home):
            if path != env_file:
                with open(path, "rb") as fh:
                    self.saw(path, fh.read().decode("utf-8", "replace"))
        for h in (a, b):
            for path in self.files_under(h["dir"]):
                with open(path, "rb") as fh:
                    data = fh.read().decode("latin-1")
                if os.path.basename(path).startswith("hub.db"):
                    data = data.replace(secrets["peer secret"], "<the pair's secret>")
                self.saw(path, data)

        self.assert_no_secrets(secrets)

    def peer_secret(self, hub):
        store = hubmod.Store(os.path.join(hub["dir"], "hub.db"), hub["name"], [])
        try:
            return store.peer_links()[0]["secret"]
        finally:
            store.close()

    def link_id(self, hub):
        store = hubmod.Store(os.path.join(hub["dir"], "hub.db"), hub["name"], [])
        try:
            return store.peer_links()[0]["link_id"]
        finally:
            store.close()


if __name__ == "__main__":
    unittest.main()
