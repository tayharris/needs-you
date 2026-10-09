"""needs-you hub conformance suite (API v1, docs/API.md): black-box over HTTP, stdlib only.

Every hub implementation must pass it (ADR 0004, 0012). It talks to a running hub and never
imports one. Run it against a throwaway hub: it writes items, mints tokens and pairs a fake
peer (all cleaned up at the end, but it is still traffic).

    NEEDS_YOU_CONFORMANCE_URL=http://127.0.0.1:8765 \\
    NEEDS_YOU_CONFORMANCE_OWNER=<an owner token on it> \\
    python3 -m unittest discover -s protocol/conformance -v

Optional:
    NEEDS_YOU_CONFORMANCE_PEER_SECRET  the hub's replication secret: enables the /v1/replicate
                                       cases (last writer wins, the same-key merge)
    NEEDS_YOU_CONFORMANCE_URL_B        a second hub peered with the first: enables the
                                       cross-hub cases (writes and answers reach it)
    NEEDS_YOU_CONFORMANCE_MAX_OPEN     the hub's max_open_per_token (default 60)
    NEEDS_YOU_CONFORMANCE_WAIT         seconds to wait for replication (default 20)

No token makes more than about 80 requests (Senders), so a hub's per-token rate limit on
POST /v1/items (120 a minute is typical) is never what a case measures. The volume guard
posts max_open + 3 items with one token: keep NEEDS_YOU_CONFORMANCE_MAX_OPEN under the hub's
rate limit. Replication (/v1/replicate) is peer traffic and must not be rate-limited as posts.

Without NEEDS_YOU_CONFORMANCE_URL every test is skipped. tests/test_conformance.py starts two
peered hubs and runs this suite against them, so CI runs it on every change.
"""
from __future__ import annotations

import json
import os
import secrets
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class Env:
    url = ""
    url_b = ""
    owner = ""
    peer_secret = ""
    max_open = 60
    wait = 20.0
    run = ""        # a random tag for this run's keys and names
    sender = ""
    reader = ""
    minted: List[str] = []   # token ids to revoke at the end
    hub_id = ""


def setUpModule() -> None:
    Env.url = (os.environ.get("NEEDS_YOU_CONFORMANCE_URL") or "").rstrip("/")
    Env.url_b = (os.environ.get("NEEDS_YOU_CONFORMANCE_URL_B") or "").rstrip("/")
    Env.owner = os.environ.get("NEEDS_YOU_CONFORMANCE_OWNER") or ""
    Env.peer_secret = os.environ.get("NEEDS_YOU_CONFORMANCE_PEER_SECRET") or ""
    Env.max_open = int(os.environ.get("NEEDS_YOU_CONFORMANCE_MAX_OPEN") or 60)
    Env.wait = float(os.environ.get("NEEDS_YOU_CONFORMANCE_WAIT") or 20)
    Env.run = "cf" + secrets.token_hex(4)
    Env.minted = []
    if not Env.url:
        return
    if not Env.owner:
        raise unittest.SkipTest("NEEDS_YOU_CONFORMANCE_OWNER is required with NEEDS_YOU_CONFORMANCE_URL")
    Env.hub_id = call("GET", "/v1/health")[1]["hub_id"]
    Env.sender = mint("sender")
    Env.reader = mint("reader")


def tearDownModule() -> None:
    if not Env.url:
        return
    for tid in Env.minted:
        call("DELETE", "/v1/tokens/" + tid, Env.owner)


# -- helpers -----------------------------------------------------------------

def call(method: str, path: str, token: Optional[str] = None, body: Any = None, url: Optional[str] = None,
         raw: Optional[bytes] = None, timeout: float = 10.0,
         headers: Optional[Dict[str, str]] = None) -> Tuple[int, Any]:
    data = raw if raw is not None else (json.dumps(body).encode("utf-8") if body is not None else None)
    req = urllib.request.Request((url or Env.url) + path, data=data, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with OPENER.open(req, timeout=timeout) as resp:
            text = resp.read().decode("utf-8")
            return resp.status, (json.loads(text) if text.strip() else None)
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8")
        try:
            return e.code, json.loads(text) if text.strip() else None
        except ValueError:
            return e.code, text


def mint(role: str, url: Optional[str] = None) -> str:
    """A fresh token of `role` through an invite (the only token API a hub must have)."""
    status, inv = call("POST", "/v1/invites", Env.owner, {"name": Env.run + "-" + role, "role": role,
                                                          "uses": 1, "ttl_hours": 1}, url=url)
    assert status == 201, (status, inv)
    status, red = call("POST", "/v1/invites/redeem", None, {"code": inv["code"], "host": "conformance"}, url=url)
    assert status == 200, (status, red)
    for t in call("GET", "/v1/tokens", red["token"] if role == "owner" else Env.owner, url=url)[1]["tokens"]:
        if t["name"] == red["name"]:
            Env.minted.append(t["id"])
    return red["token"]


class Senders:
    """Fresh sender tokens, each used for at most `per_token` requests: a hub may rate-limit
    one token's posts (for example 120 a minute), and the suite must stay under any such
    limit. Use for loops that post many items."""

    def __init__(self, per_token: int = 40) -> None:
        self.per_token = per_token
        self.used = per_token
        self.token = ""

    def next(self) -> str:
        if self.used >= self.per_token:
            self.token, self.used = mint("sender"), 0
        self.used += 1
        return self.token


def key(name: str) -> str:
    return "%s:%s" % (Env.run, name)


def post(body: Dict[str, Any], token: Optional[str] = None) -> Tuple[int, Any]:
    return call("POST", "/v1/items", token or Env.sender, body)


def item(item_id: str, url: Optional[str] = None) -> Tuple[int, Any]:
    return call("GET", "/v1/items/" + item_id, Env.reader, url=url)


def wait_until(pred, timeout: Optional[float] = None) -> bool:
    deadline = time.time() + (Env.wait if timeout is None else timeout)
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(0.1)
    return bool(pred())


def parse_ts(s: str) -> float:
    """RFC 3339 with three fractional digits and Z (what hubs emit) -> epoch seconds."""
    import calendar
    head, frac = s[:-1].split(".")
    return calendar.timegm(time.strptime(head, "%Y-%m-%dT%H:%M:%S")) + int(frac) / 1000.0


def fmt_ts(t: float) -> str:
    ms = int(round(t * 1000))
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms // 1000)) + ".%03dZ" % (ms % 1000)


_CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def ulid(ms: int) -> str:
    value = (ms & ((1 << 48) - 1)) << 80 | secrets.randbits(80)
    return "".join(_CROCKFORD[(value >> (5 * i)) & 31] for i in reversed(range(26)))


class HubCase(unittest.TestCase):
    def setUp(self) -> None:
        if not Env.url:
            self.skipTest("set NEEDS_YOU_CONFORMANCE_URL (and _OWNER) to run the conformance suite")

    def assertError(self, resp: Tuple[int, Any], status: int, code: Optional[str] = None,
                    field: Optional[str] = None) -> None:
        got, body = resp
        self.assertEqual(got, status, body)
        self.assertIsInstance(body, dict, body)
        self.assertIn("error", body)
        self.assertIsInstance(body.get("message"), str)
        if code:
            self.assertEqual(body["error"], code, body)
        if field:
            self.assertEqual(body.get("field"), field, body)


# -- conventions, health, roles ----------------------------------------------

class Health(HubCase):
    def test_health_without_and_with_a_token(self):
        status, body = call("GET", "/v1/health")
        self.assertEqual(status, 200)
        self.assertIs(body["ok"], True)
        self.assertEqual(body["api"], "v1")
        for k in ("hub_id", "version", "time"):
            self.assertIsInstance(body[k], str)
        self.assertRegex(body["time"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$")
        for k in ("db_bytes", "items", "open_items", "live_invites", "outbox_pending"):
            self.assertIsInstance(body["stats"][k], int, k)
        self.assertNotIn("token", body)
        status, body = call("GET", "/v1/health", Env.reader)
        self.assertEqual(body["token"]["role"], "reader")
        self.assertIsInstance(body["peers"], list)
        status, body = call("GET", "/v1/health", "ny_not-a-real-token-at-all")
        self.assertEqual(status, 200)
        self.assertIsNone(body["token"])

    def test_unknown_endpoint_and_bad_host(self):
        self.assertError(call("GET", "/v1/nope", Env.reader), 404, "not_found")
        req = urllib.request.Request(Env.url + "/v1/health")
        req.add_header("Host", "rebind.attacker.example")
        try:
            OPENER.open(req, timeout=10)
            self.fail("a foreign Host header was answered")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 421)


class Roles(HubCase):
    def test_who_may_call_what(self):
        body = {"key": key("roles"), "title": "roles"}
        self.assertError(call("POST", "/v1/items", None, body), 401, "unauthorized")
        self.assertError(call("POST", "/v1/items", "ny_unknown-token-0123456789", body), 401, "unauthorized")
        self.assertError(call("POST", "/v1/items", Env.reader, body), 403, "forbidden")
        self.assertError(call("GET", "/v1/items", Env.sender), 403, "forbidden")
        self.assertError(call("GET", "/v1/stream", Env.sender), 403, "forbidden")
        self.assertError(call("POST", "/v1/invites", Env.reader, {"name": "x"}), 403, "forbidden")
        self.assertError(call("GET", "/v1/tokens", Env.reader), 403, "forbidden")
        self.assertError(call("GET", "/v1/peers", Env.reader), 403, "forbidden")
        self.assertEqual(call("GET", "/v1/items", Env.reader)[0], 200)
        self.assertEqual(call("GET", "/v1/items", Env.owner)[0], 200)


# -- validation ---------------------------------------------------------------

OK = {"title": "Decide the thing"}


def _with(**kw: Any) -> Dict[str, Any]:
    d = dict(OK)
    d.update(kw)
    return d


VALIDATION = [
    # (case, body, field) -> 400 invalid naming `field`
    ("title missing", {"key": "x"}, "title"),
    ("title blank", _with(title="   "), "title"),
    ("title 101", _with(title="x" * 101), "title"),
    ("title newline", _with(title="a\nb"), "title"),
    ("title bidi override", _with(title="a\u202eb"), "title"),
    ("title not a string", _with(title=5), "title"),
    ("body 2001", _with(body="b" * 2001), "body"),
    ("body NUL", _with(body="a\x00b"), "body"),
    ("key 201", _with(key="k" * 201), "key"),
    ("key space", _with(key="a b"), "key"),
    ("key empty", _with(key=""), "key"),
    ("context", _with(context="home"), "context"),
    ("kind", _with(kind="alert"), "kind"),
    ("priority", _with(priority="high"), "priority"),
    ("status is refused", _with(status="open"), "status"),
    ("status null too", _with(status=None), "status"),
    ("links not a list", _with(links="https://a.example"), "links"),
    ("seven links", _with(links=[{"label": "l", "url": "https://a.example/%d" % i} for i in range(7)]), "links"),
    ("http link", _with(links=[{"label": "l", "url": "http://a.example"}]), "links[0].url"),
    ("javascript link", _with(links=[{"label": "l", "url": "javascript:alert(1)"}]), "links[0].url"),
    ("label 81", _with(links=[{"label": "l" * 81, "url": "https://a.example"}]), "links[0].label"),
    ("eleven steps", _with(steps=[{"text": "s"}] * 11), "steps"),
    ("step text missing", _with(steps=[{"done": False}]), "steps[0].text"),
    ("step done not bool", _with(steps=[{"text": "s", "done": "yes"}]), "steps[0].done"),
    ("step bad link", _with(steps=[{"text": "s", "link": {"label": "l", "url": "ftp://x"}}]), "steps[0].link.url"),
    ("source not object", _with(source="me"), "source"),
    ("source.agent 101", _with(source={"agent": "a" * 101}), "source.agent"),
    ("expires_at", _with(expires_at="tomorrow"), "expires_at"),
    ("question no items", _with(question={"items": []}), "question.items"),
    ("question text missing", _with(question={"items": [{"options": []}]}), "question.items[0].text"),
    ("question nine options", _with(question={"items": [{"text": "q", "options": [{"label": str(i)} for i in range(9)]}]}),
     "question.items[0].options"),
    ("answerable without options", _with(question={"items": [{"text": "q"}], "answerable": True}), "question.answerable"),
]


class Validation(HubCase):
    def test_table(self):
        for name, body, field in VALIDATION:
            with self.subTest(name):
                self.assertError(post(body), 400, "invalid", field)

    def test_bad_json_and_bodies(self):
        self.assertError(call("POST", "/v1/items", Env.sender, raw=b"{not json"), 400, "invalid")
        self.assertError(call("POST", "/v1/items", Env.sender, raw=b'["a"]'), 400, "invalid")
        self.assertError(call("POST", "/v1/items", Env.sender, raw=b'{"title": "\\ud800"}'), 400, "invalid")
        self.assertError(call("POST", "/v1/items", Env.sender, raw=b"x" * (64 * 1024 + 1)), 413, "too_large")

    def test_link_allow_list_matches_the_shared_cases(self):
        """tests/fixtures/link_cases.json: what every hub (and the Mac app) must decide."""
        path = os.path.join(HERE, "..", "..", "tests", "fixtures", "link_cases.json")
        if not os.path.exists(path):
            self.skipTest("link_cases.json not found next to this suite")
        with open(path, encoding="utf-8") as fh:
            cases = json.load(fh)["cases"]
        pool = Senders()
        for i, case in enumerate(cases):
            with self.subTest(url=case["url"]):
                status, body = post({"key": key("link-%d" % i), "title": "link case",
                                     "links": [{"label": "l", "url": case["url"]}]}, pool.next())
                self.assertEqual(status in (200, 201), case["allowed"], (status, body))
                if status in (200, 201):
                    call("POST", "/v1/items/resolve", pool.next(), {"id": body["id"]})

    def test_normalised_output(self):
        status, body = post({"key": key("norm"), "title": "  Trim me  ", "context": "PERSONAL", "kind": "Info",
                             "priority": "LOW", "body": None, "steps": [{"text": "one"}],
                             "question": {"items": [{"text": "Pick", "options": [{"label": "A"}]}]}})
        self.assertEqual(status, 201, body)
        self.assertEqual((body["title"], body["context"], body["kind"], body["priority"]),
                         ("Trim me", "personal", "info", "low"))
        self.assertIsNone(body["body"])
        self.assertEqual(body["steps"], [{"text": "one", "done": False}])
        self.assertEqual(body["question"]["items"][0]["options"], [{"label": "A", "description": ""}])
        self.assertIs(body["question"]["answerable"], False)
        self.assertIsNotNone(body["expires_at"])  # info: default expiry
        self.assertEqual(len(body["id"]), 26)
        call("POST", "/v1/items/resolve", Env.sender, {"id": body["id"]})


# -- upsert, dedupe, resolve, patch --------------------------------------------

class Upsert(HubCase):
    def test_same_key_updates_in_place(self):
        k = key("upsert")
        s1, a = post({"key": k, "title": "first"})
        self.assertEqual(s1, 201)
        self.assertEqual((a["created"], a["changed"], a["status"], a["key"]), (True, True, "open", k))
        s2, b = post({"key": k, "title": "first", "links": [{"label": "x", "url": "https://a.example"}]})
        self.assertEqual(s2, 200)
        self.assertEqual(b["id"], a["id"])
        self.assertEqual((b["created"], b["changed"]), (False, False))
        self.assertGreater(b["updated_at"], a["updated_at"])
        self.assertEqual(b["content_updated_at"], a["content_updated_at"])
        s3, c = post({"key": k, "title": "second"})
        self.assertEqual((s3, c["changed"]), (200, True))
        self.assertGreater(c["content_updated_at"], a["content_updated_at"])
        self.assertEqual(c["links"], [])  # a re-post is the full view
        call("POST", "/v1/items/resolve", Env.sender, {"key": k})
        s4, d = post({"key": k, "title": "again"})
        self.assertEqual(s4, 201)
        self.assertNotEqual(d["id"], a["id"])
        call("POST", "/v1/items/resolve", Env.sender, {"key": k})

    def test_no_key_never_dedupes(self):
        _, a = post({"title": "keyless"})
        _, b = post({"title": "keyless"})
        self.assertNotEqual(a["id"], b["id"])
        self.assertEqual(a["key"], a["id"])
        for i in (a, b):
            call("POST", "/v1/items/resolve", Env.sender, {"id": i["id"]})


class Resolve(HubCase):
    def test_by_key_and_id_idempotent(self):
        k = key("resolve")
        _, a = post({"key": k, "title": "to resolve"})
        status, body = call("POST", "/v1/items/resolve", Env.sender, {"key": "  " + k + " "})
        self.assertEqual(status, 200)
        self.assertEqual(body["resolved"], 1)
        self.assertEqual(body["items"][0]["status"], "resolved")
        self.assertEqual(call("POST", "/v1/items/resolve", Env.sender, {"key": k})[1], {"resolved": 0, "items": []})
        _, b = post({"key": k, "title": "by id"})
        self.assertEqual(call("POST", "/v1/items/resolve", Env.sender, {"id": b["id"]})[1]["resolved"], 1)
        self.assertError(call("POST", "/v1/items/resolve", Env.sender, {}), 400, "invalid")
        self.assertError(call("POST", "/v1/items/resolve", Env.sender, {"key": k, "id": b["id"]}), 400, "invalid")
        self.assertError(call("POST", "/v1/items/resolve", Env.sender, {"key": 5}), 400, "invalid")


class Patch(HubCase):
    def test_dismiss_and_seen(self):
        _, a = post({"key": key("patch"), "title": "patch me"})
        status, b = call("PATCH", "/v1/items/" + a["id"], Env.reader, {"seen_at": "2026-10-06T17:04:05Z"})
        self.assertEqual(status, 200)
        self.assertEqual(b["seen_at"], "2026-10-06T17:04:05.000Z")
        self.assertEqual(b["content_updated_at"], a["content_updated_at"])
        status, c = call("PATCH", "/v1/items/" + a["id"], Env.reader, {"status": "dismissed"})
        self.assertEqual((status, c["status"]), (200, "dismissed"))
        self.assertError(call("PATCH", "/v1/items/" + a["id"], Env.reader, {"status": "open"}), 400, "invalid")
        self.assertError(call("PATCH", "/v1/items/" + a["id"], Env.reader, {}), 400, "invalid")
        self.assertError(call("PATCH", "/v1/items/01NOSUCHITEM0000000000000", Env.reader, {"status": "resolved"}),
                         404, "not_found")
        self.assertError(item("01NOSUCHITEM0000000000000"), 404, "not_found")


# -- listing and paging ------------------------------------------------------------

class Paging(HubCase):
    def test_full_poll_cursor_and_since(self):
        ids = [post({"key": key("page-%d" % i), "title": "page %d" % i})[1]["id"] for i in range(5)]
        seen: Dict[str, Dict[str, Any]] = {}
        status, page = call("GET", "/v1/items?status=open&limit=2", Env.reader)
        self.assertEqual(status, 200)
        self.assertLessEqual(len(page["items"]), 2)
        self.assertTrue(page["more"])
        self.assertEqual(page["hub_id"], Env.hub_id)
        for i in page["items"]:
            seen[i["id"]] = i
        for _ in range(1000):
            if not page["more"]:
                break
            q = urllib.parse.urlencode({"cursor": page["next"], "limit": 2})
            page = call("GET", "/v1/items?" + q, Env.reader)[1]
            self.assertLessEqual(len(page["items"]), 2)
            for i in page["items"]:
                seen[i["id"]] = i
        self.assertTrue(set(ids) <= set(seen), "a full poll paged by cursor missed items")
        nxt, since = page["next"], page["server_time"]
        call("POST", "/v1/items/resolve", Env.sender, {"id": ids[0]})
        q = urllib.parse.urlencode({"cursor": nxt, "since": since})
        status, delta = call("GET", "/v1/items?" + q, Env.reader)
        self.assertEqual(status, 200)
        got = {i["id"]: i for i in delta["items"]}
        self.assertIn(ids[0], got)
        self.assertEqual(got[ids[0]]["status"], "resolved")
        # `since` alone works too (clients that don't know `next`)
        status, delta = call("GET", "/v1/items?" + urllib.parse.urlencode({"since": since}), Env.reader)
        self.assertIn(ids[0], {i["id"] for i in delta["items"]})
        self.assertError(call("GET", "/v1/items?cursor=garbage", Env.reader), 400, "invalid", "cursor")
        for i in ids[1:]:
            call("POST", "/v1/items/resolve", Env.sender, {"id": i})

    def test_status_filters(self):
        _, a = post({"key": key("filter"), "title": "filter"})
        call("PATCH", "/v1/items/" + a["id"], Env.reader, {"status": "dismissed"})
        dismissed = call("GET", "/v1/items?status=dismissed&limit=2000", Env.reader)[1]["items"]
        self.assertIn(a["id"], {i["id"] for i in dismissed})
        open_ = call("GET", "/v1/items?status=open&limit=2000", Env.reader)[1]["items"]
        self.assertNotIn(a["id"], {i["id"] for i in open_})
        self.assertError(call("GET", "/v1/items?status=nope", Env.reader), 400, "invalid")


# -- the volume guard --------------------------------------------------------------

class VolumeGuard(HubCase):
    def test_too_many_open_per_token(self):
        tok = mint("sender")
        made = []
        try:
            for i in range(Env.max_open):
                status, body = post({"key": key("vol-%d" % i), "title": "volume %d" % i}, tok)
                self.assertEqual(status, 201, body)
                made.append(body["id"])
            self.assertError(post({"key": key("vol-over"), "title": "one too many"}, tok), 429, "too_many_open")
            # updates to an open key are not new items: still allowed
            self.assertEqual(post({"key": key("vol-0"), "title": "volume 0 again"}, tok)[0], 200)
        finally:
            pool = Senders()  # any sender may resolve; spread the requests (rate limits)
            for i in made:
                call("POST", "/v1/items/resolve", pool.next(), {"id": i})
        self.assertEqual(post({"key": key("vol-after"), "title": "room again"}, tok)[0], 201)
        call("POST", "/v1/items/resolve", tok, {"key": key("vol-after")})


# -- answers (ADR 0009) ------------------------------------------------------------

def _question(**kw: Any) -> Dict[str, Any]:
    q = {"id": "q1", "items": [{"text": "Ship it?", "options": [{"label": "Yes"}, {"label": "No"}]}],
         "answerable": True}
    q.update(kw)
    return q


class Answers(HubCase):
    def test_answer_then_read_back(self):
        k = key("answer")
        _, a = post({"key": k, "title": "a question", "question": _question()})
        path = "/v1/items/%s/answer" % a["id"]
        good = {"question_id": "q1", "content_updated_at": a["content_updated_at"], "answers": [{"selected": ["Yes"]}]}
        self.assertError(call("POST", path, Env.sender, good), 403, "forbidden")
        self.assertEqual(call("GET", "/v1/items/answer?" + urllib.parse.urlencode({"key": k, "wait": 0}), Env.sender)[0], 204)
        self.assertError(call("POST", path, Env.reader, dict(good, question_id="other")), 409, "question_changed")
        self.assertError(call("POST", path, Env.reader, dict(good, answers=[{"selected": ["Maybe"]}])), 400, "invalid")
        status, b = call("POST", path, Env.reader, good)
        self.assertEqual(status, 200, b)
        self.assertEqual(b["answer"], [{"selected": ["Yes"]}])
        self.assertEqual(b["status"], "open")
        self.assertError(call("POST", path, Env.reader, good), 409, "already_answered")
        status, got = call("GET", "/v1/items/answer?" + urllib.parse.urlencode({"key": k, "wait": 0}), Env.sender)
        self.assertEqual(status, 200, got)
        self.assertEqual((got["id"], got["answers"]), (a["id"], [{"selected": ["Yes"]}]))
        other = mint("sender")
        self.assertError(call("GET", "/v1/items/answer?" + urllib.parse.urlencode({"key": k, "wait": 0}), other),
                         404, "not_found")
        call("POST", "/v1/items/resolve", Env.sender, {"key": k})

    def test_free_text_answer(self):
        k = key("other")
        q = _question(items=[{"text": "Ship it?", "allow_other": True, "options": [{"label": "Yes"}, {"label": "No"}]},
                             {"text": "Release name?", "allow_other": True}])
        _, a = post({"key": k, "title": "a question", "question": q})
        self.assertEqual([it.get("allow_other") for it in a["question"]["items"]], [True, True])
        path = "/v1/items/%s/answer" % a["id"]
        good = {"question_id": "q1", "content_updated_at": a["content_updated_at"],
                "answers": [{"selected": [], "text": "After the demo"}, {"text": " Otter "}]}
        self.assertError(call("POST", path, Env.reader, dict(good, answers=[
            {"selected": ["Yes"], "text": "After the demo"}, {"text": "Otter"}])), 400, "invalid")
        self.assertError(call("POST", path, Env.reader, dict(good, answers=[
            {"text": "two\nlines"}, {"text": "Otter"}])), 400, "invalid")
        # Typed words only from an owner token (ADR 0009 rule 7): a reader picks options.
        self.assertError(call("POST", path, Env.reader, good), 403, "forbidden")
        status, b = call("POST", path, Env.owner, good)
        self.assertEqual(status, 200, b)
        want = [{"selected": [], "text": "After the demo"}, {"selected": [], "text": "Otter"}]
        self.assertEqual(b["answer"], want)
        status, got = call("GET", "/v1/items/answer?" + urllib.parse.urlencode({"key": k, "wait": 0}), Env.sender)
        self.assertEqual((status, got["answers"]), (200, want))
        _, ro = post({"key": key("no-other"), "title": "no other", "question": _question()})
        self.assertError(call("POST", "/v1/items/%s/answer" % ro["id"], Env.reader, {
            "question_id": "q1", "content_updated_at": ro["content_updated_at"],
            "answers": [{"selected": [], "text": "Maybe"}]}), 400, "invalid")
        for item in (a, ro):
            call("POST", "/v1/items/resolve", Env.sender, {"id": item["id"]})

    def test_not_answerable(self):
        _, a = post({"key": key("ro-question"), "title": "read-only",
                     "question": {"items": [{"text": "q", "options": [{"label": "A"}]}]}})
        self.assertError(call("POST", "/v1/items/%s/answer" % a["id"], Env.reader, {
            "question_id": None, "content_updated_at": a["content_updated_at"], "answers": [{"selected": ["A"]}]}),
            409, "not_answerable")
        call("POST", "/v1/items/resolve", Env.sender, {"id": a["id"]})


# -- invites -------------------------------------------------------------------------

class Invites(HubCase):
    def test_create_list_redeem_revoke(self):
        status, inv = call("POST", "/v1/invites", Env.owner, {"name": Env.run + "-inv", "uses": 2, "ttl_hours": 1})
        self.assertEqual(status, 201, inv)
        self.assertTrue(inv["code"].startswith("nyi_"))
        self.assertEqual(inv["role"], "sender")
        listed = {i["id"]: i for i in call("GET", "/v1/invites", Env.owner)[1]["invites"]}
        self.assertEqual(listed[inv["id"]]["left"], 2)
        self.assertNotIn("code", listed[inv["id"]])
        for bad, field in (({"name": "bad name"}, "name"), ({"name": "x", "role": "admin"}, "role"),
                           ({"name": "x", "uses": 0}, "uses"), ({"name": "x", "ttl_hours": 0}, "ttl_hours")):
            self.assertError(call("POST", "/v1/invites", Env.owner, bad), 400, "invalid", field)
        status, red = call("POST", "/v1/invites/redeem", None, {"code": inv["code"], "host": "conf box"})
        self.assertEqual(status, 200, red)
        self.assertTrue(red["token"].startswith("ny_"))
        self.assertEqual(red["hub_id"], Env.hub_id)
        self.assertIsInstance(red["hub_urls"], list)
        self.assertTrue(red["name"].startswith(Env.run + "-inv-conf"))
        for t in call("GET", "/v1/tokens", Env.owner)[1]["tokens"]:
            if t["name"] == red["name"]:
                Env.minted.append(t["id"])
        self.assertEqual(call("DELETE", "/v1/invites/" + inv["id"], Env.owner)[0], 200)
        self.assertError(call("POST", "/v1/invites/redeem", None, {"code": inv["code"], "host": "x"}), 404, "not_found")
        self.assertError(call("POST", "/v1/invites/redeem", None, {"code": "nyi_nothing", "host": "x"}), 404, "not_found")


class PeerInvites(HubCase):
    """ADR 0012: a peer invite pairs another hub; its secret is shown once, then removable."""

    def test_pair_a_fake_peer_and_remove_it(self):
        status, inv = call("POST", "/v1/invites", Env.owner, {"name": Env.run + "-peer", "role": "peer"})
        self.assertEqual(status, 201, inv)
        self.assertEqual((inv["role"], inv["uses"]), ("peer", 1))
        self.assertNotIn("mac_url", inv)
        self.assertIn("--join", inv["install_command"])
        self.assertError(call("POST", "/v1/invites", Env.owner, {"name": "x", "role": "peer", "uses": 2}),
                         400, "invalid", "uses")
        self.assertError(call("POST", "/v1/invites/redeem", None, {"code": inv["code"], "host": "x"}),
                         400, "invalid", "peer")
        fake = {"url": "http://127.0.0.1:9", "hub_id": Env.run + "-peer", "schema": 1000}
        self.assertError(call("POST", "/v1/invites/redeem", None, {"code": inv["code"], "peer": dict(fake, hub_id=Env.hub_id)}),
                         409, "self")
        self.assertError(call("POST", "/v1/invites/redeem", None, {"code": inv["code"], "peer": dict(fake, schema=0)}),
                         409, "peer_outdated")
        self.assertError(call("POST", "/v1/invites/redeem", None, {"code": inv["code"], "peer": dict(fake, url="ftp://x")}),
                         400, "invalid", "peer.url")
        self.assertError(call("POST", "/v1/invites/redeem", None,
                              {"code": inv["code"], "peer": dict(fake, url="http://intranet.example.com:8765")}),
                         400, "invalid", "peer.url")  # plain http only on the tailnet or loopback
        status, red = call("POST", "/v1/invites/redeem", None, {"code": inv["code"], "host": "x", "peer": fake})
        self.assertEqual(status, 200, red)
        self.assertEqual((red["role"], red["hub_id"]), ("peer", Env.hub_id))
        self.assertGreaterEqual(len(red["peer_secret"]), 16)
        self.assertIn("http://127.0.0.1:9", red["hub_urls"])
        self.assertTrue(red["link_id"].startswith("pl_"))
        changes = "/v1/replicate/changes?after=0&limit=1"
        link = {"X-Needs-You-Peer-Link": red["link_id"]}
        self.assertEqual(call("GET", changes, red["peer_secret"], headers=link)[0], 200)
        # a link's secret is good only with its own link id, never alone or with another id
        self.assertError(call("GET", changes, red["peer_secret"]), 401, "unauthorized")
        self.assertError(call("GET", changes, red["peer_secret"], headers={"X-Needs-You-Peer-Link": "pl_" + "x" * 16}),
                         401, "unauthorized")
        if Env.peer_secret:  # nor is the mesh secret good for a link
            self.assertError(call("GET", changes, Env.peer_secret, headers=link), 401, "unauthorized")
        peers = call("GET", "/v1/peers", Env.owner)[1]["peers"]
        mine = [p for p in peers if p["hub_id"] == fake["hub_id"]]
        self.assertEqual([(p["url"], p["source"]) for p in mine], [("http://127.0.0.1:9", "invite")])
        self.assertNotIn(red["peer_secret"], json.dumps(peers))
        self.assertNotIn(red["peer_secret"], json.dumps(call("GET", "/v1/health", Env.owner)[1]))
        # another peer invite can't take that link over by naming its URL or hub id, and spends nothing
        status, inv2 = call("POST", "/v1/invites", Env.owner, {"name": Env.run + "-peer2", "role": "peer"})
        self.assertEqual(status, 201, inv2)
        for clash in (dict(fake, hub_id=Env.run + "-other"), dict(fake, url="http://127.0.0.2:9")):
            self.assertError(call("POST", "/v1/invites/redeem", None, {"code": inv2["code"], "peer": clash}),
                             409, "conflict")
        self.assertEqual(call("GET", changes, red["peer_secret"], headers=link)[0], 200)
        self.assertEqual(call("DELETE", "/v1/invites/" + inv2["id"], Env.owner)[0], 200)
        status, gone = call("DELETE", "/v1/peers/" + fake["hub_id"], Env.owner)
        self.assertEqual(status, 200, gone)
        self.assertNotIn(fake["hub_id"], [p["hub_id"] for p in call("GET", "/v1/peers", Env.owner)[1]["peers"]])
        self.assertIn(call("GET", changes, red["peer_secret"], headers=link)[0], (401, 404))
        self.assertError(call("DELETE", "/v1/peers/" + fake["hub_id"], Env.owner), 404, "not_found")


# -- status records ------------------------------------------------------------

def status_body(pct: int = 51, expires_in: float = 600) -> Dict[str, Any]:
    now = time.time()
    return {"type": "usage", "label": "Claude",
            "usage": {"provider": "claude", "account": Env.run,
                      "windows": [{"name": "5h", "used_pct": pct, "resets_at": fmt_ts(now + 1800)},
                                  {"name": "7d", "used_pct": 12}]},
            "expires_at": fmt_ts(now + expires_in)}


class Statuses(HubCase):
    """Status records (ADR 0011): keyed per token, expiring, never items, ETag on the list."""

    def mine(self) -> List[Dict[str, Any]]:
        status, page = call("GET", "/v1/status", Env.reader)
        self.assertEqual(status, 200, page)
        return [s for s in page["statuses"] if s["key"].startswith(Env.run)]

    def test_set_list_clear(self):
        k = key("usage")
        sender = mint("sender")
        status, rec = call("PUT", "/v1/status/" + k, sender, status_body())
        self.assertEqual(status, 200, rec)
        for f in ("id", "key", "type", "label", "usage", "source", "created_at", "updated_at", "expires_at"):
            self.assertIn(f, rec)
        self.assertEqual(rec["usage"]["windows"][0]["used_pct"], 51)
        self.assertEqual([s["id"] for s in self.mine()], [rec["id"]])
        _, items = call("GET", "/v1/items?status=open", Env.reader)
        self.assertNotIn(k, [i["key"] for i in items["items"]])  # never an item
        self.assertError(call("PUT", "/v1/status/" + k, sender, status_body(60)), 429, "too_fast")
        self.assertEqual(call("DELETE", "/v1/status/" + k, sender), (200, {"ok": True, "cleared": True}))
        self.assertEqual(self.mine(), [])
        self.assertEqual(call("DELETE", "/v1/status/" + k, sender)[1]["cleared"], False)

    def test_roles_and_validation(self):
        k = key("v")
        self.assertError(call("PUT", "/v1/status/" + k, Env.reader, status_body()), 403, "forbidden")
        self.assertError(call("GET", "/v1/status", Env.sender), 403, "forbidden")
        sender = mint("sender")
        bad = status_body()
        bad["usage"]["account"] = "me@example.com"
        self.assertError(call("PUT", "/v1/status/" + k, sender, bad), 400, "invalid", "usage.account")
        self.assertError(call("PUT", "/v1/status/" + k, sender, dict(status_body(), expires_at=None)),
                         400, "invalid", "expires_at")
        self.assertError(call("PUT", "/v1/status/" + k, sender, dict(status_body(), label="nyp_" + "s" * 20)),
                         400, "secret_in_text", "label")

    def test_etag(self):
        req = urllib.request.Request(Env.url + "/v1/status", headers={"Authorization": "Bearer " + Env.reader})
        with OPENER.open(req, timeout=10) as resp:
            tag = resp.headers.get("ETag")
        self.assertTrue(tag)
        req.add_header("If-None-Match", tag)
        try:
            with OPENER.open(req, timeout=10) as resp:
                code = resp.status
        except urllib.error.HTTPError as e:
            code = e.code
        self.assertEqual(code, 304)


# -- replication (needs the peer secret) -------------------------------------------

class Replication(HubCase):
    def setUp(self) -> None:
        super().setUp()
        if not Env.peer_secret:
            self.skipTest("set NEEDS_YOU_CONFORMANCE_PEER_SECRET for the replication cases")

    def record(self, item_id: str) -> Dict[str, Any]:
        """The hub's own replication record for an item, from its change feed."""
        after, found = 0, None
        for _ in range(10000):
            status, page = call("GET", "/v1/replicate/changes?after=%d&limit=2000" % after, Env.peer_secret)
            self.assertEqual(status, 200, page)
            for r in page["items"]:
                if r["id"] == item_id:
                    found = r
            if not page["more"]:
                break
            after = page["next_after"]
        self.assertIsNotNone(found, "item not in /v1/replicate/changes")
        return dict(found)

    def push(self, items: List[Dict[str, Any]], from_hub: str = "conformance-peer") -> Tuple[int, Any]:
        return call("POST", "/v1/replicate", Env.peer_secret, {"from_hub": from_hub, "items": items, "tokens": []})

    def test_changes_feed_shape_and_auth(self):
        status, page = call("GET", "/v1/replicate/changes?after=0&limit=5", Env.peer_secret)
        self.assertEqual(status, 200)
        for k in ("hub_id", "epoch", "max_seq", "next_after", "more", "items", "tokens", "invites", "statuses"):
            self.assertIn(k, page)
        self.assertNotIn("peer", [i["role"] for i in page["invites"]])
        self.assertError(call("GET", "/v1/replicate/changes?after=0", "wrong-secret-0123456789"), 401, "unauthorized")
        self.assertError(self.push([], from_hub=Env.hub_id), 409, "self")

    def test_last_writer_wins(self):
        _, a = post({"key": key("lww"), "title": "local"})
        rec = self.record(a["id"])
        newer = dict(rec, title="from a peer", updated_by="conformance-peer",
                     updated_at=fmt_ts(parse_ts(rec["updated_at"]) + 60),
                     content_updated_at=fmt_ts(parse_ts(rec["updated_at"]) + 60))
        status, body = self.push([newer])
        self.assertEqual((status, body["applied"]), (200, 1), body)
        self.assertEqual(item(a["id"])[1]["title"], "from a peer")
        older = dict(rec, title="stale", updated_by="conformance-peer",
                     updated_at=fmt_ts(parse_ts(rec["updated_at"]) - 60))
        self.assertEqual(self.push([older])[1]["applied"], 0)
        self.assertEqual(self.push([newer])[1]["applied"], 0)  # idempotent
        self.assertEqual(item(a["id"])[1]["title"], "from a peer")
        # an unreadable item is skipped, not the batch
        status, body = self.push([dict(newer, id=ulid(int(time.time() * 1000)), status="exploded")])
        self.assertEqual(status, 200)
        self.assertEqual(len(body["skipped"]), 1)
        call("POST", "/v1/items/resolve", Env.sender, {"id": a["id"]})

    def test_an_answer_outlives_a_concurrent_repost(self):
        """An answer to the same question from the same token survives LWW both ways (API.md,
        Replication): a newer record without it keeps it, an older one with it gives it."""
        _, a = post({"key": key("ans-race"), "title": "asks", "question": _question()})
        rec = self.record(a["id"])
        good = {"question_id": "q1", "content_updated_at": a["content_updated_at"], "answers": [{"selected": ["Yes"]}]}
        self.assertEqual(call("POST", "/v1/items/%s/answer" % a["id"], Env.reader, good)[0], 200)
        later = parse_ts(self.record(a["id"])["updated_at"]) + 60
        repost = dict(rec, title="asks again", answer=None, answered_at=None, answered_by=None,
                      updated_by="conformance-peer", updated_at=fmt_ts(later), content_updated_at=fmt_ts(later))
        self.assertEqual(self.push([repost])[1]["applied"], 1)
        got = item(a["id"])[1]
        self.assertEqual((got["title"], got["answer"]), ("asks again", [{"selected": ["Yes"]}]))
        # another question clears it
        other = dict(repost, question=_question(id="q2"), updated_at=fmt_ts(later + 1),
                     content_updated_at=fmt_ts(later + 1))
        self.assertEqual(self.push([other])[1]["applied"], 1)
        self.assertIsNone(item(a["id"])[1]["answer"])
        call("POST", "/v1/items/resolve", Env.sender, {"id": a["id"]})
        # an older record carrying an answer the hub lacks: taken, with a newer version
        _, b = post({"key": key("ans-late"), "title": "asks", "question": _question()})
        rec = self.record(b["id"])
        older = dict(rec, answer=[{"selected": ["No"]}], answered_by="mac", updated_by="conformance-peer",
                     answered_at=rec["updated_at"], updated_at=fmt_ts(parse_ts(rec["updated_at"]) - 60))
        self.assertEqual(self.push([older])[1]["applied"], 1)
        got = item(b["id"])[1]
        self.assertEqual(got["answer"], [{"selected": ["No"]}])
        self.assertGreater(parse_ts(got["updated_at"]), parse_ts(rec["updated_at"]))
        call("POST", "/v1/items/resolve", Env.sender, {"id": b["id"]})

    def test_tombstones(self):
        """Short retention (ADR 0012): a closed item's text-free tombstone replicates and closes
        the item; one that is open isn't taken; an equal version with text never restores it."""
        _, a = post({"key": key("tomb"), "title": "has text", "body": "b"})
        self.assertIs(a["tombstone"], False)
        rec = self.record(a["id"])
        newer = parse_ts(rec["updated_at"]) + 60
        tomb = dict(rec, status="resolved", tombstone=True, title="", body=None, links=[], steps=[],
                    question=None, answer=None, source={}, updated_by="conformance-peer",
                    updated_at=fmt_ts(newer))
        status, body = self.push([dict(tomb, status="open")])
        self.assertEqual((status, len(body["skipped"])), (200, 1))  # a tombstone must be closed
        status, body = self.push([tomb])
        self.assertEqual((status, body["applied"]), (200, 1), body)
        got = item(a["id"])[1]
        self.assertEqual((got["status"], got["tombstone"], got["title"], got["body"], got["links"], got["steps"]),
                         ("resolved", True, "", None, [], []))
        self.assertEqual(got["key"], key("tomb"))
        full = dict(rec, status="resolved", updated_by="conformance-peer", updated_at=fmt_ts(newer))
        self.assertEqual(self.push([full])[1]["applied"], 0)  # same version: the text stays gone
        self.assertEqual(item(a["id"])[1]["title"], "")

    def test_same_key_merge_lowest_id_wins(self):
        k = key("merge")
        _, a = post({"key": k, "title": "minted here"})
        rec = self.record(a["id"])
        now = parse_ts(rec["updated_at"])
        rival = dict(rec, id=ulid(int((parse_ts(rec["created_at"]) - 5) * 1000)), title="minted elsewhere",
                     origin_hub="conformance-peer", updated_by="conformance-peer",
                     created_at=fmt_ts(parse_ts(rec["created_at"]) - 5),
                     updated_at=fmt_ts(now + 1), content_updated_at=fmt_ts(now + 1))
        self.assertLess(rival["id"], a["id"])
        status, body = self.push([rival])
        self.assertEqual(status, 200, body)
        loser = item(a["id"])[1]
        winner = item(rival["id"])[1]
        self.assertEqual((loser["status"], loser["superseded_by"]), ("resolved", rival["id"]))
        self.assertEqual(winner["status"], "open")
        self.assertEqual(winner["title"], "minted elsewhere")  # the freshest content
        status, again = post({"key": k, "title": "re-post"})
        self.assertEqual((status, again["id"]), (200, rival["id"]))  # upserts into the winner
        call("POST", "/v1/items/resolve", Env.sender, {"key": k})


class CrossHub(HubCase):
    def setUp(self) -> None:
        super().setUp()
        if not Env.url_b:
            self.skipTest("set NEEDS_YOU_CONFORMANCE_URL_B (a hub peered with the first) for cross-hub cases")

    def test_writes_tokens_and_answers_reach_the_peer(self):
        self.assertTrue(wait_until(lambda: call("GET", "/v1/health", Env.reader, url=Env.url_b)[1].get("token")),
                        "tokens didn't replicate")
        k = key("cross")
        _, a = post({"key": k, "title": "posted on A", "question": _question(id=None)})
        self.assertTrue(wait_until(lambda: item(a["id"], url=Env.url_b)[0] == 200), "item didn't replicate")
        status, b = call("POST", "/v1/items/%s/answer" % a["id"], Env.reader, {
            "question_id": None, "content_updated_at": a["content_updated_at"], "answers": [{"selected": ["No"]}]},
            url=Env.url_b)
        self.assertEqual(status, 200, b)

        def answered() -> bool:
            s, got = call("GET", "/v1/items/answer?" + urllib.parse.urlencode({"key": k, "wait": 0}), Env.sender)
            return s == 200 and got["answers"] == [{"selected": ["No"]}]
        self.assertTrue(wait_until(answered), "the answer didn't replicate back")
        call("POST", "/v1/items/resolve", Env.sender, {"key": k}, url=Env.url_b)
        self.assertTrue(wait_until(lambda: item(a["id"])[1]["status"] == "resolved"), "resolve didn't replicate")

    def test_statuses_reach_the_peer(self):
        k = key("status-cross")
        sender = mint("sender")
        self.assertTrue(wait_until(lambda: call("GET", "/v1/health", sender, url=Env.url_b)[1].get("token")),
                        "tokens didn't replicate")
        status, rec = call("PUT", "/v1/status/" + k, sender, status_body(33))
        self.assertEqual(status, 200, rec)

        def seen() -> bool:
            s, page = call("GET", "/v1/status", Env.reader, url=Env.url_b)
            return s == 200 and rec["id"] in [x["id"] for x in page["statuses"]]
        self.assertTrue(wait_until(seen), "the status didn't replicate")
        call("DELETE", "/v1/status/" + k, sender)
        self.assertTrue(wait_until(lambda: not seen()), "the clear didn't replicate")


if __name__ == "__main__":
    unittest.main()
