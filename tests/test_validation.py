from __future__ import annotations

import unittest

from support import hubmod

ApiError = hubmod.ApiError
OK = {"key": "work:ACME-1:x", "title": "Decide the thing"}


def with_(**kw):
    d = dict(OK)
    d.update(kw)
    return d


def link(url, label="L"):
    return {"label": label, "url": url}


def step(text, **kw):
    d = {"text": text}
    d.update(kw)
    return d


class ValidateItemInput(unittest.TestCase):
    CASES = [
        # (name, payload, expected error substring or None)
        ("minimal", OK, None),
        ("full", with_(context="personal", kind="info", priority="urgent", body="**b**\n- x",
                       links=[link("https://a.b")], source={"agent": "a", "project": "p", "host": "h"},
                       expires_at="2026-10-07T00:00:00Z"), None),
        ("no key is allowed", {"title": "t"}, None),
        ("enum case-insensitive", with_(context="WORK", priority="Low"), None),
        ("title missing", {"key": "k"}, "title is required"),
        ("title blank", with_(title="   "), "title must not be empty"),
        ("title 100 ok", with_(title="x" * 100), None),
        ("title 101", with_(title="x" * 101), "longer than 100"),
        ("title newline", with_(title="a\nb"), "control characters"),
        ("title not string", with_(title=5), "must be a string"),
        ("body 2000 ok", with_(body="b" * 2000), None),
        ("body 2001", with_(body="b" * 2001), "longer than 2000"),
        ("body NUL", with_(body="a\x00b"), "control characters"),
        ("key 200 ok", with_(key="k" * 200), None),
        ("key 201", with_(key="k" * 201), "longer than 200"),
        ("key charset", with_(key="agent:host-1:term_2.x/y@z#1+a=b"), None),
        ("key with space", with_(key="a b"), "key may only contain"),
        ("key with quote", with_(key="a'b"), "key may only contain"),
        ("key unicode", with_(key="caf\u00e9"), "key may only contain"),
        ("bad context", with_(context="home"), "context must be one of"),
        ("bad kind", with_(kind="alert"), "kind must be one of"),
        ("bad priority", with_(priority="high"), "priority must be one of"),
        ("status not settable", with_(status="open"), "status cannot be set"),
        ("links not list", with_(links="https://a"), "links must be a list"),
        ("6 links ok", with_(links=[link("https://a/%d" % i) for i in range(6)]), None),
        ("7 links", with_(links=[link("https://a/%d" % i) for i in range(7)]), "at most 6 links"),
        ("http scheme", with_(links=[link("http://a.b")]), "scheme 'http' is not allowed"),
        ("javascript scheme", with_(links=[link("javascript:alert(1)")]), "not allowed"),
        ("file scheme", with_(links=[link("file:///etc/passwd")]), "not allowed"),
        ("no scheme", with_(links=[link("a.b/c")]), "not allowed"),
        ("scheme case-insensitive", with_(links=[link("HTTPS://a.b")]), None),
        ("app terminal link", with_(links=[link("needsyou://orca/terminal?handle=term_ab12cd34")]), None),
        ("other app link", with_(links=[link("needsyou://connect?hub=x&code=y")]), "not allowed"),
        ("app link other path", with_(links=[link("needsyou://orca/terminalx?handle=t")]), "not allowed"),
        ("orca", with_(links=[link("orca://skills/share/x")]), None),
        ("slack", with_(links=[link("slack://channel?team=T&id=C")]), None),
        ("vscode cursor figma msteams discord",
         with_(links=[link("vscode://file/x"), link("cursor://file/x"), link("figma://file/x"),
                      link("msteams://l/x"), link("discord://x")]), None),
        ("linear", with_(links=[link("linear://acme/issue/ACME-12")]), None),
        ("linear case-insensitive", with_(links=[link("LINEAR://acme/issue/ACME-12")]), None),
        ("linear lookalike", with_(links=[link("linearx://acme/issue/ACME-12")]), "not allowed"),
        ("empty url after scheme", with_(links=[link("https:")]), "empty"),
        ("link label missing", with_(links=[{"url": "https://a"}]), "label is required"),
        ("link label too long", with_(links=[link("https://a", "l" * 81)]), "longer than 80"),
        ("link not object", with_(links=["https://a"]), "must be an object"),
        ("source not object", with_(source="host"), "source must be an object"),
        ("source field too long", with_(source={"agent": "a" * 101}), "longer than 100"),
        ("bad expires_at", with_(expires_at="tomorrow"), "expires_at"),
        ("body not object", ["x"], "JSON object"),
        # steps: a checklist, links checked like item links
        ("steps null", with_(steps=None), None),
        ("steps not list", with_(steps="do it"), "steps must be a list"),
        ("10 steps ok", with_(steps=[step("s%d" % i) for i in range(10)]), None),
        ("11 steps", with_(steps=[step("s%d" % i) for i in range(11)]), "at most 10 steps"),
        ("step not object", with_(steps=["do it"]), "steps[0] must be an object"),
        ("step text missing", with_(steps=[{"done": True}]), "steps[0].text is required"),
        ("step text blank", with_(steps=[step("  ")]), "steps[0].text must not be empty"),
        ("step text 200 ok", with_(steps=[step("x" * 200)]), None),
        ("step text 201", with_(steps=[step("x" * 201)]), "steps[0].text is longer than 200"),
        ("step text newline", with_(steps=[step("a\nb")]), "control characters"),
        ("step done not bool", with_(steps=[step("a", done="yes")]), "steps[0].done must be true or false"),
        ("step link https", with_(steps=[step("a", link=link("https://a.b"))]), None),
        ("step link app terminal",
         with_(steps=[step("a", link=link("needsyou://orca/terminal?handle=term_ab12cd34"))]), None),
        ("step link http", with_(steps=[step("ok"), step("a", link=link("http://a.b"))]),
         "steps[1].link.url scheme 'http' is not allowed"),
        ("step link javascript", with_(steps=[step("a", link=link("javascript:alert(1)"))]), "not allowed"),
        ("step link not object", with_(steps=[step("a", link="https://a.b")]), "steps[0].link must be an object"),
        ("step link label missing", with_(steps=[step("a", link={"url": "https://a"})]),
         "steps[0].link.label is required"),
        ("step link url too long", with_(steps=[step("a", link=link("https://a/" + "x" * 2000))]),
         "longer than 2000"),
    ]

    def test_table(self):
        for name, payload, err in self.CASES:
            with self.subTest(name):
                if err is None:
                    out = hubmod.validate_item_input(payload)
                    self.assertIn(out["context"], hubmod.CONTEXTS)
                    self.assertIn(out["kind"], hubmod.KINDS)
                    self.assertIn(out["priority"], hubmod.PRIORITIES)
                else:
                    with self.assertRaises(ApiError) as cm:
                        hubmod.validate_item_input(payload)
                    self.assertEqual(cm.exception.status, 400)
                    self.assertIn(err, cm.exception.message)

    def test_defaults(self):
        out = hubmod.validate_item_input({"title": " t "})
        self.assertEqual((out["context"], out["kind"], out["priority"]), ("work", "needs", "normal"))
        self.assertEqual(out["title"], "t")
        self.assertEqual(out["links"], [])
        self.assertEqual(out["steps"], [])
        self.assertIsNone(out["key"])

    def test_steps_normalised_and_unknown_fields_ignored(self):
        out = hubmod.validate_item_input(with_(steps=[
            {"text": " Approve the deploy ", "link": {"label": " Deploy ", "url": "https://ci/x",
                                                     "icon": "rocket"},
             "done": True, "id": 7, "due": "soon"},
            {"text": "Tell **the team**", "link": None},
        ]))
        self.assertEqual(out["steps"], [
            {"text": "Approve the deploy", "done": True, "link": {"label": "Deploy", "url": "https://ci/x"}},
            {"text": "Tell **the team**", "done": False},
        ])


class Timestamps(unittest.TestCase):
    CASES = [
        ("2026-10-06T17:04:05Z", 1791306245000),
        ("2026-10-06T17:04:05.123Z", 1791306245123),
        ("2026-10-06T17:04:05.123456Z", 1791306245123),
        ("2026-10-06T17:04:05", 1791306245000),  # no zone = UTC
        ("2026-10-06 17:04:05+00:00", 1791306245000),
        ("2026-10-06T11:04:05-06:00", 1791306245000),
        ("2026-10-06T19:04:05+0200", 1791306245000),
        ("1791306245", 1791306245000),
        (1791306245.5, 1791306245500),
    ]

    def test_parse(self):
        for raw, want in self.CASES:
            with self.subTest(raw):
                self.assertEqual(hubmod.parse_ts(raw), want)

    def test_bad(self):
        for raw in ("", "yesterday", "2026-13-01", True, None, "2026-10-06T17:04"):
            with self.subTest(raw):
                with self.assertRaises((ValueError, TypeError)):
                    hubmod.parse_ts(raw)

    def test_roundtrip_and_sortable(self):
        a, b = 1791306245123, 1791306245124
        self.assertEqual(hubmod.parse_ts(hubmod.fmt_ts(a)), a)
        self.assertLess(hubmod.fmt_ts(a), hubmod.fmt_ts(b))
        self.assertEqual(hubmod.fmt_ts(a), "2026-10-06T17:04:05.123Z")


class Ulid(unittest.TestCase):
    def test_shape_and_order(self):
        a = hubmod.new_ulid(1000)
        b = hubmod.new_ulid(2000)
        self.assertEqual(len(a), 26)
        self.assertTrue(set(a) <= set(hubmod._CROCKFORD))
        self.assertLess(a, b)
        self.assertNotEqual(hubmod.new_ulid(1000), hubmod.new_ulid(1000))


class BindChecks(unittest.TestCase):
    def cfg(self, **kw):
        c = hubmod.load_config(None, {"hub_id": "h"})
        c.update(kw)
        return c

    def test_bind_defaults_to_loopback(self):
        cfg = self.cfg()
        self.assertEqual(cfg["bind"], ["127.0.0.1"])
        hubmod.check_bind(cfg)

    def test_bind_list_and_commas(self):
        self.assertEqual(hubmod.normalise_binds("127.0.0.1, 100.64.1.2"), ["127.0.0.1", "100.64.1.2"])
        self.assertEqual(hubmod.normalise_binds(["127.0.0.1", "[::1]", "127.0.0.1"]), ["127.0.0.1", "::1"])
        hubmod.check_bind(self.cfg(bind=["127.0.0.1", "100.64.1.2"]))
        with self.assertRaises(SystemExit):
            hubmod.check_bind(self.cfg(bind=["127.0.0.1", "0.0.0.0"]))

    def test_any_interface_refused(self):
        for addr in ("0.0.0.0", "::", ""):
            with self.subTest(addr):
                with self.assertRaises(SystemExit):
                    hubmod.check_bind(self.cfg(bind=addr))

    def test_any_interface_allowed_with_flag(self):
        hubmod.check_bind(self.cfg(bind="0.0.0.0", allow_any_interface=True))

    def test_tailnet_ip_ok(self):
        hubmod.check_bind(self.cfg(bind="100.64.1.2"))

    def test_peers_need_secret(self):
        with self.assertRaises(SystemExit):
            hubmod.check_bind(self.cfg(bind="127.0.0.1", peers=["http://x"], peer_secret="short"))


if __name__ == "__main__":
    unittest.main()
