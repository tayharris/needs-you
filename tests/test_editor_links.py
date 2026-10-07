"""Security audit #14: vscode:// and cursor:// links reach every editor extension's URI
handler, so the hub (and the Mac app's LinkPolicy, same regex) allow only the file,
vscode-remote (ssh-remote+, tunnel+) and Claude Code session shapes; orca:// is gone."""
from __future__ import annotations

import json
import unittest

from support import PEER_SECRET, HubTestCase, hubmod, request  # noqa: E402

ApiError = hubmod.ApiError

ALLOWED = [
    # what the Claude Code hook writes (tests/test_hook_events.py) and the docs show
    "vscode://file/home/dev/x.py",
    "vscode://file/Users/me/My%20Project",
    "vscode://file/Users/me/repo/src/app.py:12",
    "vscode://file/Users/me/repo/src/app.py:12:3",
    "vscode://file/Users/jos%C3%A9/repo/",
    "vscode://file/",
    "cursor://file/x",
    "VSCODE://file/home/dev/x.py",          # the scheme is case-insensitive
    "Cursor://file/home/dev/x.py",
    "vscode://vscode-remote/ssh-remote+devbox/home/me/repo",
    "vscode://vscode-remote/ssh-remote+devbox",
    "vscode://vscode-remote/ssh-remote+hub-a.example.ts.net/srv/app",
    "vscode://vscode-remote/ssh-remote+me@devbox/home/me",
    "vscode://vscode-remote/ssh-remote+cafe/x",      # hex, but not a '{'-encoded JSON spec
    "cursor://vscode-remote/ssh-remote+devbox/home/me/repo",
    "vscode://vscode-remote/tunnel+my-box/home/me",
    "vscode://anthropic.claude-code/open?session=sess-1234-abcd",
    "vscode://anthropic.claude-code/open?session=0f8e6c4a-1b2c-4d5e-8f90-123456789abc",
    "cursor://anthropic.claude-code/open?session=0f8e6c4a-1b2c-4d5e-8f90-123456789abc",
]

REFUSED = [
    # other authorities: extension handlers, settings
    "vscode://settings/editor.fontSize",
    "vscode://ms-python.python/run?x=1",
    "vscode://vscode.git/clone?url=https://evil.example/r.git",
    "vscode://ms-vscode-remote.remote-ssh/x",
    "vscode://github.remotehub/open?url=x",
    "cursor://anysphere.cursor-retrieval/x",
    "orca://skills/share/abc123",                     # orca:// dropped entirely
    "ORCA://skills/share/abc123",
    # authority case and encoding tricks
    "vscode://File/x",
    "vscode://FILE/x",
    "vscode://Anthropic.Claude-Code/open?session=sess-1234-abcd",
    "vscode://anthropic%2Eclaude-code/open?session=sess-1234-abcd",
    "vscode://%66ile/x",
    "vscode://VSCODE-REMOTE/ssh-remote+devbox/x",
    "vscode://vscode-remote/SSH-REMOTE+devbox/x",
    # userinfo, ports, missing or doubled slashes
    "vscode://u@file/x",
    "vscode://user:pw@file/x",
    "vscode://evil.example@file/x",
    "vscode://file@evil.example/x",
    "vscode://file:80/x",
    "vscode:file/x",
    "vscode:/file/x",
    "vscode:///file/x",
    "vscode://file//server/share",
    "vscode://file",
    "vscode://file\\x",
    "vscode://file/x\\y",
    # queries and fragments on file links
    "vscode://file/x?windowId=_blank",
    "vscode://file/x#L1",
    "vscode://file/x?",
    # escaped control characters, broken escapes
    "vscode://file/x%0a",
    "vscode://file/x%0D%0A",
    "vscode://file/x%00",
    "vscode://file/x%1b",
    "vscode://file/x%7F",
    "vscode://file/x%2",
    "vscode://file/x%zz",
    # remote: option injection, JSON host specs, other remote kinds, queries
    "vscode://vscode-remote/ssh-remote+-oProxyCommand=touch%20x/",
    "vscode://vscode-remote/ssh-remote+%2DoProxyCommand=x/",
    "vscode://vscode-remote/ssh-remote+.hidden/x",
    "vscode://vscode-remote/ssh-remote+7b22686f73744e616d65223a222d6f78227d/x",
    "vscode://vscode-remote/ssh-remote+7B22686F73744E616D65223A2278227D",
    "vscode://vscode-remote/ssh-remote+dev%62ox/x",
    "vscode://vscode-remote/ssh-remote+-x@devbox/x",
    "vscode://vscode-remote/ssh-remote+/x",
    "vscode://vscode-remote/wsl+Ubuntu/home/me",
    "vscode://vscode-remote/dev-container+7b7d/x",
    "vscode://vscode-remote/attached-container+7b7d/x",
    "vscode://vscode-remote/codespaces+x/x",
    "vscode://vscode-remote/ssh-remote+devbox/x?windowId=_blank",
    "vscode://vscode-remote/ssh-remote+devbox/x#f",
    "vscode://vscode-remote/ssh-remote+devbox//etc",
    "vscode://vscode-remote/ssh-remote+devbox:22/x",
    "vscode://vscode-remote/",
    # the Claude link: only /open with exactly one session parameter
    "vscode://anthropic.claude-code/open?prompt=rm%20-rf",
    "vscode://anthropic.claude-code/open?session=sess-1234-abcd&prompt=x",
    "vscode://anthropic.claude-code/open?prompt=x&session=sess-1234-abcd",
    "vscode://anthropic.claude-code/open?session=sess-1234-abcd#x",
    "vscode://anthropic.claude-code/open?session=short",
    "vscode://anthropic.claude-code/open?session=sess_1234_abcd",
    "vscode://anthropic.claude-code/open?session=sess%2D1234-abcd",
    "vscode://anthropic.claude-code/open",
    "vscode://anthropic.claude-code/new?session=sess-1234-abcd",
    "vscode://anthropic.claude-code/open/?session=sess-1234-abcd",
    "vscode://anthropic.claude-code/open?Session=sess-1234-abcd",
    "vscode://anthropic.claude-code:1/open?session=sess-1234-abcd",
    # whitespace or invisible characters are refused before the shape check
    "vscode://file/x y",
    "vscode://file/x​y",
]


def item(url):
    return {"key": "work:SEC-14:x", "title": "t", "links": [{"label": "L", "url": url}]}


class EditorLinkShapes(unittest.TestCase):
    def test_allowed(self):
        for url in ALLOWED:
            with self.subTest(url):
                self.assertTrue(hubmod.link_allowed(url))
                hubmod.validate_item_input(item(url))

    def test_refused(self):
        for url in REFUSED:
            with self.subTest(url):
                self.assertFalse(hubmod.link_allowed(url))
                with self.assertRaises(ApiError) as cm:
                    hubmod.validate_item_input(item(url))
                self.assertEqual(cm.exception.status, 400)
                self.assertEqual(cm.exception.field, "links[0].url")

    def test_step_links_follow_the_same_rule(self):
        hubmod.validate_item_input({"key": "work:x:y", "title": "t",
                                    "steps": [{"text": "open", "link": {"label": "o", "url": ALLOWED[0]}}]})
        with self.assertRaises(ApiError):
            hubmod.validate_item_input({"key": "work:x:y", "title": "t", "steps": [
                {"text": "open", "link": {"label": "o", "url": "vscode://settings/x"}}]})

    def test_error_names_the_allowed_shapes(self):
        with self.assertRaises(ApiError) as cm:
            hubmod.validate_item_input(item("vscode://ms-python.python/x"))
        self.assertIn("vscode://file/", str(cm.exception))
        self.assertIn("anthropic.claude-code/open?session=", str(cm.exception))

    def test_orca_scheme_is_gone(self):
        self.assertNotIn("orca", hubmod.LINK_SCHEMES)
        # the Orca jump still goes through the app's own action
        self.assertTrue(hubmod.link_allowed("needsyou://orca/terminal?handle=term_ab12cd34"))

    def test_other_schemes_unchanged(self):
        for url in ("https://a.example/x", "slack://channel?team=T&id=C", "figma://file/x",
                    "msteams://l/x", "discord://x", "linear://acme/issue/ACME-12"):
            with self.subTest(url):
                self.assertTrue(hubmod.link_allowed(url))


class ReplicatedEditorLinks(HubTestCase):
    def test_replicated_items_lose_refused_editor_links(self):
        hub = self.make_hub("hub-a", maintenance_seconds=0)
        now = hubmod.fmt_ts(hub.store.now_ms())
        rec = {"id": hubmod.new_ulid(), "key": "work:x:y", "context": "work", "kind": "needs",
               "priority": "normal", "title": "t", "status": "open",
               "created_at": now, "updated_at": now,
               "links": [{"label": "a", "url": "vscode://ms-python.python/x"},
                         {"label": "b", "url": "vscode://file/home/me/x.py"},
                         {"label": "c", "url": "orca://skills/share/x"},
                         {"label": "d", "url": "vscode://anthropic.claude-code/open?session=sess-1234-abcd&prompt=x"}],
               "steps": [{"text": "s1", "link": {"label": "x", "url": "cursor://settings/x"}},
                         {"text": "s2", "link": {"label": "y", "url": "cursor://file/x"}}]}
        st, body = request("POST", hub.url + "/v1/replicate", PEER_SECRET,
                           {"from_hub": "hub-z", "items": [rec]})
        self.assertEqual(st, 200, body)
        got = hub.store.get_item(rec["id"])
        self.assertEqual(json.loads(got["links"]), [{"label": "b", "url": "vscode://file/home/me/x.py"}])
        steps = json.loads(got["steps"])
        self.assertNotIn("link", steps[0])
        self.assertEqual(steps[1]["link"]["url"], "cursor://file/x")


class HookLinksStillPass(unittest.TestCase):
    """Every editor link the repo's senders write must still be accepted."""

    def test_hook_shapes(self):
        cwd = "/Users/me/My Project"
        from urllib.parse import quote
        for url in ("vscode://file" + quote(cwd),
                    "vscode://vscode-remote/ssh-remote+devbox" + quote(cwd),
                    "vscode://anthropic.claude-code/open?session=sess-1234-abcd",
                    "cursor://file" + quote(cwd),
                    "vscode://vscode-remote/ssh-remote+%s%s" % (quote("devbox", safe=""), quote(cwd)),
                    "vscode://file/home/dev/acme-api"):   # the Mac demo fixture
            with self.subTest(url):
                self.assertTrue(hubmod.link_allowed(url))


if __name__ == "__main__":
    unittest.main()
