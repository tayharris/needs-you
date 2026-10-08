"""Rollout and updates, hub side (docs/roadmap/rollout-updates.md): /dl/manifest.json, the
Orca snippet on /dl, the version stamps, and each sender's reported versions in
GET /v1/tokens (X-Needs-You-Client, stored per token on this hub only)."""
from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import unittest
import urllib.error
import urllib.request

from support import OPENER, ROOT, FakeClock, HubTestCase, hubmod, request


def raw_get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with OPENER.open(req, timeout=5) as resp:
        return resp.status, resp.read()


def call(method, url, token, client=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if client is not None:
        req.add_header("X-Needs-You-Client", client)
    with OPENER.open(req, timeout=5) as resp:
        return resp.status, json.loads(resp.read() or b"{}")


class ParseClientHeader(unittest.TestCase):
    def test_table(self):
        p = hubmod.parse_client_header
        cases = [
            ("cli=0.1.1; hook=0.1.1; skill=none; orca=none",
             {"cli": "0.1.1", "hook": "0.1.1", "skill": "none", "orca": "none"}),
            ("cli=0.2.0", {"cli": "0.2.0"}),
            ("CLI=0.2.0;hook=unknown", {"cli": "0.2.0", "hook": "unknown"}),
            ("cli=0.2.0; future=1.0.0", {"cli": "0.2.0"}),       # unknown names ignored
            ("cli=0.2.0; cli=9.9.9", {"cli": "0.2.0"}),          # first wins
            ("cli=0.2; hook=<script>", {}),                        # bad values dropped
            ("cli=0.2.0-beta", {}),
            ("cli 0.2.0", {}),
            ("", {}),
            (None, {}),
            ("cli=0.2.0;" + "x" * 300, {}),                        # too long: all dropped
        ]
        for raw, want in cases:
            self.assertEqual(p(raw), want, raw)


class VersionStamps(unittest.TestCase):
    def test_every_sender_file_carries_the_version(self):
        with open(os.path.join(ROOT, "VERSION")) as fh:
            v = fh.read().strip()
        for name, (rel, _ctype) in hubmod.DOWNLOADS.items():
            if name == "install-hooks.sh" or name in hubmod.SERVER_DOWNLOADS:
                continue  # run once by the installer and `update`, never kept; or a server's file
            with open(os.path.join(ROOT, rel), "rb") as fh:
                self.assertEqual(hubmod.file_version(fh.read()), v, rel)

    def test_hooks_json_stamp_is_outside_hooks(self):
        with open(os.path.join(ROOT, "integrations", "claude-code", "hooks.json")) as fh:
            data = json.load(fh)
        self.assertIn("_needs_you_version", data)
        self.assertNotIn("_needs_you_version", data["hooks"])

    def test_skill_frontmatter_stays_first(self):
        with open(os.path.join(ROOT, "integrations", "claude-code", "skill", "needs-you", "SKILL.md")) as fh:
            self.assertTrue(fh.read().startswith("---\nname: needs-you\n"))


class Manifest(HubTestCase):
    def setUp(self):
        super().setUp()
        self.hub = self.make_hub(install_dir=ROOT)

    def test_manifest_matches_the_files(self):
        status, body = request("GET", self.hub.url + "/dl/manifest.json")
        self.assertEqual(status, 200)
        self.assertEqual(body["version"], hubmod.VERSION)
        self.assertEqual(sorted(body["files"]), sorted(hubmod.DOWNLOADS))
        for name, entry in body["files"].items():
            status, data = raw_get(self.hub.url + "/dl/" + name)
            self.assertEqual(status, 200)
            self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest(), name)
            self.assertEqual(entry["size"], len(data), name)
        self.assertEqual(body["files"]["needs-you"]["version"], hubmod.VERSION)
        self.assertEqual(body["files"]["orca-snippet.md"]["version"], hubmod.VERSION)
        self.assertNotIn("version", body["files"]["install-hooks.sh"])

    def test_orca_snippet_is_downloadable(self):
        status, data = raw_get(self.hub.url + "/dl/orca-snippet.md")
        self.assertEqual(status, 200)
        with open(os.path.join(ROOT, "integrations", "orca", "snippet.md"), "rb") as fh:
            self.assertEqual(data, fh.read())

    def test_missing_files_are_left_out(self):
        hub = self.make_hub("hub-empty", install_dir=self.tmp)
        status, body = request("GET", hub.url + "/dl/manifest.json")
        self.assertEqual(status, 200)
        self.assertEqual(body["files"], {})
        self.assertEqual(request("GET", hub.url + "/dl/nope.sh")[0], 404)


class ClientVersions(HubTestCase):
    def setUp(self):
        super().setUp()
        self.clock = FakeClock()
        self.hub = self.make_hub(clock=self.clock)
        self.sender, _ = self.hub.store.add_token("devbox", "sender")
        self.owner, _ = self.hub.store.add_token("mac", "owner")

    def tokens(self):
        status, body = call("GET", self.hub.url + "/v1/tokens", self.owner)
        self.assertEqual(status, 200)
        return {t["name"]: t for t in body["tokens"]}

    def test_reported_on_post_and_listed(self):
        before = self.tokens()["devbox"]
        self.assertEqual(before["client"], {})
        self.assertIsNone(before["last_seen_at"])
        call("POST", self.hub.url + "/v1/items", self.sender, "cli=0.1.1; hook=0.1.1; skill=none; orca=none",
             {"key": "k", "title": "t"})
        t = self.tokens()["devbox"]
        self.assertEqual(t["client"], {"cli": "0.1.1", "hook": "0.1.1", "skill": "none", "orca": "none"})
        self.assertEqual(t["last_seen_at"], hubmod.fmt_ts(int(self.clock() * 1000)))
        # The owner's own calls aren't recorded (it's the Mac).
        self.assertEqual(self.tokens()["mac"]["client"], {})
        self.assertIsNone(self.tokens()["mac"]["last_seen_at"])

    def test_health_with_token_counts_and_old_clients_keep_versions(self):
        call("GET", self.hub.url + "/v1/health", self.sender, "cli=0.1.0")
        self.assertEqual(self.tokens()["devbox"]["client"], {"cli": "0.1.0"})
        # A request without the header (an old hook calling curl) keeps what was reported.
        self.clock.advance(3600)
        call("GET", self.hub.url + "/v1/health", self.sender)
        t = self.tokens()["devbox"]
        self.assertEqual(t["client"], {"cli": "0.1.0"})
        self.assertEqual(t["last_seen_at"], hubmod.fmt_ts(int(self.clock() * 1000)))

    def test_writes_are_throttled_unless_versions_change(self):
        st = self.hub.store
        self.assertTrue(st.note_client("tok1", {"cli": "0.1.1"}))
        self.assertFalse(st.note_client("tok1", {"cli": "0.1.1"}))
        self.clock.advance(60)
        self.assertFalse(st.note_client("tok1", {}))
        self.assertTrue(st.note_client("tok1", {"cli": "0.2.0"}))      # an update: written at once
        self.clock.advance(hubmod.CLIENT_WRITE_EVERY_MS / 1000 + 1)
        self.assertTrue(st.note_client("tok1", {}))
        self.assertEqual(st.token_clients()["tok1"]["client"], {"cli": "0.2.0"})

    def test_bad_header_never_reaches_the_db(self):
        call("POST", self.hub.url + "/v1/items", self.sender, "cli=$(rm -rf /); hook='x'", {"key": "k", "title": "t"})
        self.assertEqual(self.tokens()["devbox"]["client"], {})
        with self.hub.store.lock:
            dump = "\n".join(self.hub.store.conn.iterdump())
        self.assertNotIn("rm -rf", dump)

    def test_not_replicated(self):
        call("POST", self.hub.url + "/v1/items", self.sender, "cli=0.1.1", {"key": "k", "title": "t"})
        with self.hub.store.lock:
            kinds = {r[0] for r in self.hub.store.conn.execute("SELECT kind FROM outbox")}
            rows = [dict(r) for r in self.hub.store.conn.execute("SELECT * FROM tokens")]
        self.assertLessEqual(kinds, {"item", "token", "invite"})
        self.assertNotIn("client", json.dumps([hubmod.token_wire(r) for r in rows]))


def call_status(method, url, token, client=None, body=None):
    try:
        return call(method, url, token, client, body)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


class RequestUpdate(HubTestCase):
    """POST/DELETE /v1/tokens/<id>/request-update, and `update_requested` in sender responses."""

    def setUp(self):
        super().setUp()
        self.clock = FakeClock()
        self.hub = self.make_hub(clock=self.clock)
        self.sender, self.srec = self.hub.store.add_token("devbox", "sender")
        self.other, _ = self.hub.store.add_token("ci", "sender")
        self.owner, _ = self.hub.store.add_token("mac", "owner")
        self.reader, _ = self.hub.store.add_token("viewer", "reader")
        self.old = "cli=0.0.9; hook=none; skill=none; orca=none"

    def url(self, who="devbox"):
        return self.hub.url + "/v1/tokens/" + who + "/request-update"

    def post_item(self, token=None, client=None):
        return call_status("POST", self.hub.url + "/v1/items", token or self.sender, client or self.old,
                           {"key": "k", "title": "t"})

    def listed(self):
        body = call("GET", self.hub.url + "/v1/tokens", self.owner)[1]
        return {t["name"]: t for t in body["tokens"]}

    def test_owner_only(self):
        for tok in (self.sender, self.reader):
            self.assertEqual(call_status("POST", self.url(), tok)[0], 403)
            self.assertEqual(call_status("DELETE", self.url(), tok)[0], 403)
        self.assertEqual(call_status("POST", self.url(), "ny_nope")[0], 401)
        self.assertEqual(call_status("POST", self.url("nobody"), self.owner)[0], 404)
        status, body = call_status("POST", self.url("mac"), self.owner)
        self.assertEqual((status, body["error"]), (400, "invalid"))  # only senders run the CLI
        self.assertEqual(self.hub.store.update_requests(), {})

    def test_flag_in_sender_responses_until_cleared(self):
        self.post_item()  # reports 0.0.9
        self.assertNotIn("update_requested", self.post_item()[1])
        status, body = call("POST", self.url(self.srec["id"]), self.owner)
        now = hubmod.fmt_ts(int(self.clock() * 1000))
        self.assertEqual(body, {"id": self.srec["id"], "name": "devbox", "update_requested_at": now})
        self.assertEqual(self.listed()["devbox"]["update_requested_at"], now)
        self.assertIsNone(self.listed()["ci"]["update_requested_at"])
        # Every sender response carries it: post, resolve, token-checked health.
        self.assertIs(self.post_item()[1]["update_requested"], True)
        self.assertIs(call("POST", self.hub.url + "/v1/items/resolve", self.sender, self.old, {"key": "k"})[1]["update_requested"], True)
        self.assertIs(call("GET", self.hub.url + "/v1/health", self.sender)[1]["update_requested"], True)
        # Not to other tokens, not on errors, not to the owner.
        self.assertNotIn("update_requested", self.post_item(self.other)[1])
        self.assertNotIn("update_requested", call("GET", self.hub.url + "/v1/tokens", self.owner)[1])
        status, body = call_status("POST", self.hub.url + "/v1/items", self.sender, self.old, {"title": ""})
        self.assertEqual(status, 400)
        self.assertNotIn("update_requested", body)
        # Withdrawn: gone from responses and the list; clearing twice is fine.
        self.assertEqual(call("DELETE", self.url(), self.owner)[1]["update_requested_at"], None)
        self.assertEqual(call("DELETE", self.url(), self.owner)[0], 200)
        self.assertNotIn("update_requested", self.post_item()[1])
        self.assertIsNone(self.listed()["devbox"]["update_requested_at"])

    def test_clears_when_the_reported_cli_changes(self):
        self.post_item()
        call("POST", self.url(), self.owner)
        self.assertIs(self.post_item(client="cli=0.0.9")[1]["update_requested"], True)
        # A request without the header (old hook calling curl) keeps it.
        self.assertIs(call("GET", self.hub.url + "/v1/health", self.sender)[1]["update_requested"], True)
        self.assertNotIn("update_requested", self.post_item(client="cli=0.1.0")[1])
        self.assertIsNone(self.listed()["devbox"]["update_requested_at"])

    def test_unknown_version_adopts_the_first_report(self):
        call("POST", self.url(), self.owner)  # never seen: no baseline
        self.assertIs(call("GET", self.hub.url + "/v1/health", self.sender)[1]["update_requested"], True)
        self.assertIs(self.post_item(client="cli=0.0.9")[1]["update_requested"], True)  # baseline 0.0.9
        self.assertIs(self.post_item(client="cli=0.0.9")[1]["update_requested"], True)
        self.assertNotIn("update_requested", self.post_item(client="cli=0.0.10")[1])

    def test_a_current_machine_clears_at_once(self):
        call("POST", self.url(), self.owner)
        self.assertNotIn("update_requested", self.post_item(client="cli=" + hubmod.VERSION)[1])

    def test_revoked_tokens_lose_requests_and_nothing_replicates(self):
        call("POST", self.url(), self.owner)
        with self.hub.store.lock:
            kinds = {r[0] for r in self.hub.store.conn.execute("SELECT kind FROM outbox")}
        self.assertLessEqual(kinds, {"item", "token", "invite"})
        self.hub.store.revoke_token("devbox")
        self.assertEqual(call_status("POST", self.url(), self.owner)[0], 404)
        self.hub.store.purge()
        self.assertEqual(self.hub.store.update_requests(), {})

    def test_admin_tool(self):
        import io
        from contextlib import redirect_stderr, redirect_stdout
        import needs_you_admin as admin  # hub/ is on sys.path (support.py)
        db = self.hub.store.path
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(admin.main(["--db", db, "--json", "token", "request-update", "devbox"]), 0)
        self.assertEqual(json.loads(out.getvalue())["name"], "devbox")
        self.assertIn(self.srec["id"], self.hub.store.update_requests())
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(admin.main(["--db", db, "token", "clear-update", "devbox"]), 0)
            self.assertEqual(admin.main(["--db", db, "token", "request-update", "nobody"]), 1)
        self.assertEqual(self.hub.store.update_requests(), {})


class Migration(HubTestCase):
    def test_schema_2_database_gains_token_clients(self):
        path = os.path.join(self.tmp, "old.db")
        conn = sqlite3.connect(path)
        for stmt in "".join(hubmod.MIGRATIONS[:2]).split(";"):
            if stmt.strip():
                conn.execute(stmt)
        conn.execute("PRAGMA user_version = 2")
        conn.commit()
        conn.close()
        hub = self.make_hub("hub-old", db=path)
        tok, _ = hub.store.add_token("box", "sender")
        call("GET", hub.url + "/v1/health", tok, "cli=0.1.1")
        self.assertEqual(hub.store.token_clients()[hub.store.token_by_secret(tok)["id"]]["client"], {"cli": "0.1.1"})
        with hub.store.lock:
            self.assertEqual(hub.store.conn.execute("PRAGMA user_version").fetchone()[0], len(hubmod.MIGRATIONS))


if __name__ == "__main__":
    unittest.main()
