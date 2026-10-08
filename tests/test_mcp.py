"""integrations/mcp/needs_you_mcp.py: the stdio MCP server that wraps the CLI."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import unittest

from support import CLI, ROOT
from test_cli import CliTestCase

SERVER = os.path.join(ROOT, "integrations", "mcp", "needs_you_mcp.py")
MINIMAL_PATH = "/usr/bin:/bin"


def load_server():
    loader = importlib.machinery.SourceFileLoader("needs_you_mcp", SERVER)
    spec = importlib.util.spec_from_loader("needs_you_mcp", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def rpc(mid, method, params=None):
    msg = {"jsonrpc": "2.0", "id": mid, "method": method}
    if params is not None:
        msg["params"] = params
    return msg


INIT = rpc(0, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                             "clientInfo": {"name": "Claude Code", "version": "2.0"}})
INITIALIZED = {"jsonrpc": "2.0", "method": "notifications/initialized"}


def call(mid, name, arguments=None):
    return rpc(mid, "tools/call", {"name": name, "arguments": arguments or {}})


class McpTestCase(CliTestCase):
    def setUp(self):
        super().setUp()
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)

    def env(self, urls=None, token=None, extra=None):
        env = {"HOME": self.home, "PATH": MINIMAL_PATH, "NEEDS_YOU_TIMEOUT": "1", "NEEDS_YOU_HOST": "testbox",
               "NEEDS_YOU_GH": "none", "NEEDS_YOU_CLI": CLI}
        if urls:
            env["NEEDS_YOU_URLS"] = ",".join(urls)
        if token:
            env["NEEDS_YOU_TOKEN"] = token
        env.update(extra or {})
        return env

    def session(self, *messages, urls=None, token=None, extra=None, server=SERVER, raw=None):
        """Run the server over a whole session; returns ({id: response}, process result)."""
        lines = [json.dumps(m) for m in (INIT, INITIALIZED) + messages]
        stdin = "\n".join(lines + ([raw] if raw else [])) + "\n"
        r = subprocess.run([sys.executable, server], input=stdin, capture_output=True, text=True, timeout=120,
                           env=self.env(urls, token, extra), cwd=self.tmp)
        out = [json.loads(line) for line in r.stdout.splitlines()]
        return out, r

    def by_id(self, out):
        return {m.get("id"): m for m in out}

    def tool(self, response):
        self.assertIn("result", response, response)
        res = response["result"]
        return res["isError"], res["content"][0]["text"], res.get("structuredContent")


class Protocol(McpTestCase):
    def test_handshake_and_tools(self):
        out, r = self.session(rpc(1, "tools/list"), rpc(2, "ping"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, "")
        self.assertEqual(len(out), 3)  # the notification got no answer
        res = self.by_id(out)
        init = res[0]["result"]
        self.assertEqual(init["protocolVersion"], "2025-06-18")
        self.assertEqual(init["serverInfo"]["name"], "needs-you")
        self.assertIn("tools", init["capabilities"])
        self.assertIn("progress updates", init["instructions"])
        tools = {t["name"]: t for t in res[1]["result"]["tools"]}
        self.assertEqual(sorted(tools), ["needs_you_add", "needs_you_doctor", "needs_you_resolve"])
        self.assertEqual(tools["needs_you_add"]["inputSchema"]["required"], ["key", "title"])
        for want in ("progress updates", "stable", "secrets", "needs_you_resolve"):
            self.assertIn(want, tools["needs_you_add"]["description"])
        self.assertEqual(res[2]["result"], {})

    def test_version_negotiation(self):
        for asked, want in (("2024-11-05", "2024-11-05"), ("2099-01-01", "2025-06-18"), (None, "2025-06-18")):
            with self.subTest(asked=asked):
                server = load_server().Server()
                got = server.handle(rpc(1, "initialize", {"protocolVersion": asked}))
                self.assertEqual(got["result"]["protocolVersion"], want)

    def test_errors(self):
        out, r = self.session(rpc(1, "resources/list"), call(2, "needs_you_list"),
                              {"jsonrpc": "2.0", "id": 3}, {"id": 4, "method": "ping"},
                              {"jsonrpc": "2.0", "id": 99, "result": {}}, raw="{not json")
        self.assertEqual(r.returncode, 0, r.stderr)
        res = self.by_id(out)
        self.assertEqual(res[1]["error"]["code"], -32601)
        self.assertEqual(res[2]["error"]["code"], -32602)
        self.assertEqual(res[3]["error"]["code"], -32600)
        self.assertEqual(res[4]["error"]["code"], -32600)
        self.assertNotIn(99, res)  # a response from the client is not answered
        self.assertEqual(res[None]["error"]["code"], -32700)
        server = load_server().Server()
        self.assertEqual(server.handle([rpc(1, "ping")])["error"]["code"], -32600)

    def test_deeply_nested_line_is_a_parse_error(self):
        # Scan 2026-10-08: json.loads raised RecursionError (not a ValueError) and the server
        # exited, so the agent lost its tools for the rest of the session.
        import io
        inp = io.BytesIO(b"[" * 200000 + b"\n" + json.dumps(rpc(7, "ping")).encode() + b"\n")
        out = io.BytesIO()
        self.assertEqual(load_server().serve(inp, out), 0)
        res = self.by_id([json.loads(l) for l in out.getvalue().splitlines()])
        self.assertEqual(res[None]["error"]["code"], -32700)
        self.assertEqual(res[7]["result"], {})

    def test_exits_cleanly_on_sigterm(self):
        p = subprocess.Popen([sys.executable, SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env=self.env())
        p.stdin.write((json.dumps(INIT) + "\n").encode())
        p.stdin.flush()
        self.assertIn(b'"protocolVersion"', p.stdout.readline())
        p.send_signal(signal.SIGTERM)
        self.assertEqual(p.wait(timeout=10), 0)
        self.assertEqual(p.stderr.read(), b"")
        p.stdin.close()
        p.stdout.close()
        p.stderr.close()

    def test_version_matches(self):
        with open(os.path.join(ROOT, "VERSION")) as fh:
            self.assertEqual(load_server().VERSION, fh.read().strip())


class Tools(McpTestCase):
    def test_add_update_resolve(self):
        body = '-x "quoted" $(not a command)\nline two'
        args = {"key": "work:ACME-1:deploy", "title": "ACME-1: approve the deploy", "body": body,
                "priority": "urgent", "context": "personal", "project": "app",
                "links": [{"label": "PR #42", "url": "https://github.com/example/app/pull/42/files"},
                          {"label": "a=b", "url": "https://example.com/x?y=1"}],
                "steps": [{"text": "Approve in the PR", "link": {"label": "Approve", "url": "https://example.com/a"}},
                          {"text": "Watch the rollout", "done": True}],
                "expires_in_hours": 3}
        out, r = self.session(call(1, "needs_you_add", args), call(2, "needs_you_add", args),
                              call(3, "needs_you_resolve", {"key": "work:ACME-1:deploy"}),
                              call(4, "needs_you_resolve", {"key": "work:ACME-1:deploy"}),
                              urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        res = self.by_id(out)
        err, text, data = self.tool(res[1])
        self.assertFalse(err, text)
        self.assertEqual((data["state"], data["queued"], data["key"]), ("created", False, "work:ACME-1:deploy"))
        self.assertEqual(json.loads(text), data)
        self.assertEqual(self.tool(res[2])[2]["state"], "unchanged")
        self.assertEqual(self.tool(res[3])[2]["resolved"], 1)
        self.assertEqual(self.tool(res[4])[2]["resolved"], 0)
        item = self.items(self.hub, self.reader)[0]
        self.assertEqual(item["status"], "resolved")
        self.assertEqual(item["body"], body)
        self.assertEqual((item["priority"], item["context"], item["kind"]), ("urgent", "personal", "needs"))
        self.assertEqual(item["links"], [{"label": "PR #42", "url": "https://github.com/example/app/pull/42/files"},
                                         {"label": "a-b", "url": "https://example.com/x?y=1"}])
        self.assertEqual([s["text"] for s in item["steps"]], ["Approve in the PR", "Watch the rollout"])
        self.assertEqual(item["steps"][0]["link"]["label"], "Approve")
        self.assertTrue(item["steps"][1]["done"])
        self.assertEqual(item["source"], {"host": "testbox", "agent": "mcp:Claude-Code", "project": "app"})
        self.assertIsNotNone(item["expires_at"])

    def test_done_kind(self):
        out, r = self.session(call(1, "needs_you_add", {"key": "work:import:last", "title": "Import finished",
                                                        "kind": "done"}),
                              urls=[self.hub.url], token=self.sender)
        self.assertFalse(self.tool(self.by_id(out)[1])[0])
        self.assertEqual(self.items(self.hub, self.reader)[0]["kind"], "done")

    def test_hub_down_queues(self):
        out, r = self.session(call(1, "needs_you_add", {"key": "work:x:y", "title": "Decide"}),
                              call(2, "needs_you_resolve", {"key": "work:x:y"}),
                              urls=[self.dead], token=self.sender)
        res = self.by_id(out)
        for mid in (1, 2):
            err, text, data = self.tool(res[mid])
            self.assertFalse(err, text)
            self.assertTrue(data["queued"])
            self.assertIn("Don't retry", data["message"])
        self.assertEqual(len(self.queued()), 2)

    def test_refusals_are_tool_errors(self):
        cases = [({"key": "k", "title": "t", "links": [{"label": "x", "url": "http://insecure.example.com"}]}, "url"),
                 ({"key": "k", "title": "x" * 101}, "title"),
                 ({"title": "no key"}, "key is required"),
                 ({"key": "k", "title": "t", "priority": "asap"}, "priority must be one of"),
                 ({"key": "k", "title": "t", "links": [{"url": "https://x"}]}, "links[0]"),
                 ({"key": "k", "title": "t", "steps": [{"text": "s"}] * 11}, "at most 10"),
                 ({"key": "k", "title": "t", "expires_in_hours": -1}, "expires_in_hours")]
        out, r = self.session(*[call(i, "needs_you_add", a) for i, (a, _) in enumerate(cases, 1)],
                              rpc(50, "tools/call", {"name": "needs_you_add", "arguments": "nope"}),
                              urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        res = self.by_id(out)
        for i, (_, want) in enumerate(cases, 1):
            with self.subTest(want=want):
                err, text, data = self.tool(res[i])
                self.assertTrue(err)
                self.assertIn(want, text)
                self.assertIsNone(data)
        self.assertTrue(self.tool(res[50])[0])
        self.assertEqual(self.items(self.hub, self.reader), [])

    def test_doctor(self):
        out, r = self.session(call(1, "needs_you_doctor"), urls=[self.hub.url], token=self.sender)
        err, text, data = self.tool(self.by_id(out)[1])
        self.assertFalse(err, text)
        checks = {c["check"]: c for c in data["checks"]}
        self.assertEqual(checks["hub 1"]["status"], "OK")
        self.assertEqual(self.items(self.hub, self.reader), [])  # doctor never posts

    def test_token_never_in_output(self):
        bogus = "ny_" + "S3cretTokenValue" * 3
        for urls, token in (([self.hub.url], self.sender), ([self.hub.url], bogus), ([self.dead], bogus)):
            out, r = self.session(call(1, "needs_you_add", {"key": "k", "title": "t"}),
                                  call(2, "needs_you_resolve", {"key": "k"}), call(3, "needs_you_doctor"),
                                  urls=urls, token=token)
            self.assertNotIn(token, r.stdout + r.stderr)
            self.assertNotIn(token[3:15], r.stdout + r.stderr)

    def test_redact(self):
        mod = load_server()
        self.assertEqual(mod.redact("token ny_abcdefghijklmnop and nyi_ABCDEFGHIJ, Bearer abc.def-ghi_jkl"),
                         "token ny_[redacted] and nyi_[redacted], Bearer [redacted]")
        self.assertEqual(mod.redact("work:ny_1:x ny_"), "work:ny_1:x ny_")

    def test_no_cli(self):
        d = os.path.join(self.tmp, "alone")
        os.makedirs(d)
        server = os.path.join(d, "needs_you_mcp.py")
        shutil.copy(SERVER, server)
        out, r = self.session(call(1, "needs_you_add", {"key": "k", "title": "t"}), call(2, "needs_you_doctor"),
                              server=server, extra={"NEEDS_YOU_CLI": ""})
        self.assertEqual(r.returncode, 0, r.stderr)
        for mid in (1, 2):
            err, text, data = self.tool(self.by_id(out)[mid])
            self.assertTrue(err)
            self.assertIn("isn't installed", text)
            self.assertIn("Connect a machine", text)

    def test_cli_next_to_the_server(self):
        d = os.path.join(self.tmp, "bin")
        os.makedirs(d)
        shutil.copy(SERVER, os.path.join(d, "needs-you-mcp"))
        shutil.copy(CLI, os.path.join(d, "needs-you"))
        out, r = self.session(call(1, "needs_you_add", {"key": "k", "title": "t"}),
                              server=os.path.join(d, "needs-you-mcp"), extra={"NEEDS_YOU_CLI": ""},
                              urls=[self.hub.url], token=self.sender)
        self.assertFalse(self.tool(self.by_id(out)[1])[0])
        self.assertEqual(len(self.items(self.hub, self.reader)), 1)

    def test_one_card_per_wait_note(self):
        """Inside a Claude Code session the CLI notes the key, as when it's run from the shell."""
        state = os.path.join(self.home, ".local", "state", "needs-you", "session-items")
        out, r = self.session(call(1, "needs_you_add", {"key": "work:x:wait", "title": "Decide"}),
                              urls=[self.hub.url], token=self.sender,
                              extra={"CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "sess-1234"})
        self.assertFalse(self.tool(self.by_id(out)[1])[0])
        self.assertEqual(os.listdir(state), ["sess-1234"])
        out, r = self.session(call(1, "needs_you_resolve", {"key": "work:x:wait"}),
                              urls=[self.hub.url], token=self.sender)
        sess = os.path.join(state, "sess-1234")
        self.assertEqual(os.listdir(sess) if os.path.isdir(sess) else [], [])  # the resolve forgot it


if __name__ == "__main__":
    unittest.main()
