#!/usr/bin/env python3
"""needs-you MCP server: post to the needs-you inbox from any MCP client, no shell needed.

  claude mcp add needs-you -- python3 /path/to/needs_you_mcp.py

Speaks MCP (JSON-RPC 2.0, one message per line) on stdin/stdout and offers three tools:

  needs_you_add      post or update an item     (runs `needs-you --json add`)
  needs_you_resolve  close an item by its key   (runs `needs-you --json resolve`)
  needs_you_doctor   check this machine's setup (runs `needs-you doctor --json`)

Each tool call runs the `needs-you` CLI, so posts get its config (~/.config/needs-you/env),
hub failover and offline outbox. The CLI is found by $NEEDS_YOU_CLI, then next to this file,
then in a needs-you checkout (../../cli/needs-you), then on PATH, then ~/.local/bin/needs-you.

There's no tool to list your open items: a sender token can't read the inbox (see
docs/adr/0008-mcp-server.md). Keep track of the keys you post.

This server never reads the token and redacts anything token-shaped from what it returns.
It exits 0 when stdin closes, and on SIGTERM or Ctrl-C. Logs nothing; stdout is the protocol.

Python 3.9+ standard library only.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
from typing import Any, Dict, List, Optional, Tuple

VERSION = "0.2.0"
SUPPORTED_PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")
CLI_TIMEOUT = 120.0
MAX_LINKS = 6
MAX_STEPS = 10

INSTRUCTIONS = (
    "needs-you is the user's inbox for \"you have to do something\": every item is a card on their Mac "
    "that interrupts them. Post (needs_you_add) only when you are blocked on the user (a decision, an "
    "approval, access you don't have), when something they're waiting on finished (kind done), or when "
    "something broke that they need to know about today. Never for progress updates, things you can find "
    "out or fix yourself, or to test the setup (needs_you_doctor is the test). One card per wait: re-post "
    "the same key to change it, and resolve it (needs_you_resolve) as soon as it's handled. Never put "
    "secrets in an item."
)

ADD_DESCRIPTION = (
    "Post a card to the user's needs-you inbox, or update the open card with the same key. Every card "
    "interrupts the user, so post only when (1) you are blocked on them: a decision between options, an "
    "approval, access you don't have, a one-time exception; (2) something they're waiting on finished "
    "(kind \"done\": an FYI that expires in 24 h); or (3) something broke that they need to know about "
    "today. Never post progress updates (\"started X\", \"still working\"), anything you can find out or "
    "fix yourself, a second card for the same wait, or a test item. Keys are stable and specific, "
    "<context>:<project-or-ticket>:<reason> (e.g. work:ACME-123:deploy-approval), never a timestamp or run "
    "id: the same key updates the card instead of adding one. The title is the action the user has to "
    "take, first, at most 100 characters. The body says why, the options and where the question lives. "
    "Links point where they act, that place first. Several actions in order go in steps, not the body. "
    "Never include secrets, credentials, customer data or code. Resolve the card with needs_you_resolve "
    "once it's handled. Also ask the full question in your reply: the card is a pointer. If no hub "
    "answers, the item is queued and sent later; don't retry."
)

RESOLVE_DESCRIPTION = (
    "Close the user's needs-you card with this key: call it as soon as the blocker clears (they answered, "
    "the ticket moved, the job passed), and before you finish for every card you posted that is no longer "
    "true. Stale cards teach the user to ignore the inbox. Idempotent: resolving a key with nothing open "
    "is fine."
)

DOCTOR_DESCRIPTION = (
    "Check this machine's needs-you setup (config, hubs, token, outbox, hooks): read-only, never posts, "
    "never shows the token. Use it when a post was queued instead of sent or a tool reports a setup "
    "problem, not to test by posting. Each WARN or FAIL check has a hint: one next step to run or to "
    "relay to the user."
)

_LINK_SCHEMA = {
    "type": "object",
    "properties": {
        "label": {"type": "string", "maxLength": 80, "description": "Button text, e.g. \"PR #42\""},
        "url": {"type": "string", "maxLength": 2000,
                "description": "https, slack, vscode, cursor, figma, msteams, discord or linear; "
                               "vscode/cursor only to a file, a Remote-SSH folder or a Claude session"},
    },
    "required": ["label", "url"],
}

TOOLS: List[Dict[str, Any]] = [
    {
        "name": "needs_you_add",
        "title": "Tell the user you need them",
        "description": ADD_DESCRIPTION,
        "inputSchema": {
            "type": "object",
            "properties": {
                "key": {"type": "string", "maxLength": 200,
                        "description": "Stable dedupe key, <context>:<project-or-ticket>:<reason>. "
                                       "Letters, digits and . _ : - / @ # + = only"},
                "title": {"type": "string", "maxLength": 100,
                          "description": "The action, first: \"ACME-123: approve the prod deploy\""},
                "body": {"type": "string", "maxLength": 2000,
                         "description": "Why, the options, where the question lives. Markdown, no HTML"},
                "kind": {"type": "string", "enum": ["needs", "done", "info"], "default": "needs",
                         "description": "needs: blocked on the user; done/info: an FYI that expires in 24 h"},
                "priority": {"type": "string", "enum": ["urgent", "normal", "low"], "default": "normal",
                             "description": "urgent: broken now or someone blocked today (rare); "
                                            "normal: today; low: this week"},
                "context": {"type": "string", "enum": ["work", "personal"],
                            "description": "Default: this machine's NEEDS_YOU_DEFAULT_CONTEXT, else work"},
                "links": {"type": "array", "maxItems": MAX_LINKS, "items": _LINK_SCHEMA,
                          "description": "Where the user acts, that place first"},
                "steps": {"type": "array", "maxItems": MAX_STEPS,
                          "description": "Several things to do in order, as a checklist",
                          "items": {"type": "object", "required": ["text"], "properties": {
                              "text": {"type": "string", "maxLength": 200,
                                       "description": "One imperative line"},
                              "link": _LINK_SCHEMA,
                              "done": {"type": "boolean", "description": "Already done (shows ticked)"}}}},
                "project": {"type": "string", "maxLength": 100, "description": "The project, e.g. a repo name"},
                "expires_in_hours": {"type": "number", "exclusiveMinimum": 0,
                                     "description": "Close it by itself after this long (scheduled senders: "
                                                    "about twice the interval)"},
            },
            "required": ["key", "title"],
        },
    },
    {
        "name": "needs_you_resolve",
        "title": "Close a needs-you card",
        "description": RESOLVE_DESCRIPTION,
        "inputSchema": {
            "type": "object",
            "properties": {"key": {"type": "string", "maxLength": 200, "description": "The key you posted"}},
            "required": ["key"],
        },
    },
    {
        "name": "needs_you_doctor",
        "title": "Check the needs-you setup",
        "description": DOCTOR_DESCRIPTION,
        "inputSchema": {"type": "object", "properties": {}},
    },
]

# Backstop only: the CLI never prints the token. Hub tokens are ny_..., invite codes nyi_...
_SECRET_RE = re.compile(r"\b(nyi?_)[A-Za-z0-9_-]{8,}|(?i:\b(bearer)\s+)[A-Za-z0-9._~+/=-]{8,}")


def redact(text: str) -> str:
    return _SECRET_RE.sub(lambda m: (m.group(1) or (m.group(2) + " ")) + "[redacted]", text)


class ToolError(Exception):
    """A tool call that failed: returned as an isError result, never a crash."""


# ---------------------------------------------------------------------------
# The CLI
# ---------------------------------------------------------------------------

def find_cli() -> Optional[str]:
    here = os.path.dirname(os.path.realpath(__file__))
    candidates = [os.environ.get("NEEDS_YOU_CLI") or "",
                  os.path.join(here, "needs-you"),
                  os.path.join(here, "..", "..", "cli", "needs-you"),
                  shutil.which("needs-you") or "",
                  os.path.join(os.path.expanduser("~"), ".local", "bin", "needs-you")]
    for c in candidates:
        if c and os.path.isfile(c):
            return os.path.abspath(c)
    return None


NOT_SET_UP = ("the needs-you CLI isn't installed on this machine. Tell the user; to set it up they make an "
              "invite in the Mac app (Settings > Connect a machine > Create invite) and run its one-line "
              "installer here, or set NEEDS_YOU_CLI to the CLI's path in this MCP server's environment.")


def run_cli(args: List[str], stdin: str = "") -> Tuple[int, str, str]:
    cli = find_cli()
    if not cli:
        raise ToolError(NOT_SET_UP)
    try:
        # stdin is always a pipe we fill: the CLI must never read the protocol stream.
        r = subprocess.run([sys.executable, cli] + args, input=stdin, capture_output=True, text=True,
                           timeout=CLI_TIMEOUT, env=os.environ.copy())
    except subprocess.TimeoutExpired:
        raise ToolError("the needs-you CLI didn't finish in %d s; run needs_you_doctor" % CLI_TIMEOUT)
    except OSError as e:
        raise ToolError("couldn't run the needs-you CLI (%s): %s" % (cli, e.strerror or e))
    return r.returncode, redact(r.stdout), redact(r.stderr).strip()


def _text(arguments: Dict[str, Any], name: str, required: bool = False) -> Optional[str]:
    v = arguments.get(name)
    if v is None or (v == "" and not required):
        if required:
            raise ToolError("%s is required" % name)
        return None
    if not isinstance(v, str):
        raise ToolError("%s must be a string" % name)
    if required and not v.strip():
        raise ToolError("%s must not be empty" % name)
    return v


def _link(raw: Any, where: str) -> Dict[str, str]:
    if not isinstance(raw, dict) or not isinstance(raw.get("label"), str) or not isinstance(raw.get("url"), str):
        raise ToolError('%s must be {"label": "...", "url": "..."}' % where)
    return {"label": raw["label"], "url": raw["url"]}


def _link_arg(link: Dict[str, str]) -> str:
    """The CLI's --link LABEL=URL splits at the first '=' and takes a label with '://' for a
    bare URL, so neither may be in the label."""
    label = link["label"].replace("=", "-").replace("://", " ").strip() or "Link"
    return "--link=%s=%s" % (label, link["url"])


def _sent(rc: int, out: str, err: str) -> Optional[Dict[str, Any]]:
    """The hub's JSON response, None when the CLI queued the request, ToolError on a refusal."""
    if rc == 2:
        raise ToolError(err or "the hub refused the request")
    if rc != 0:
        raise ToolError("the needs-you CLI failed (exit %d): %s" % (rc, err or "no message"))
    out = out.strip()
    if not out:
        return None
    try:
        parsed = json.loads(out.splitlines()[-1])
    except ValueError:
        return None
    return parsed if isinstance(parsed, dict) else None


def tool_add(arguments: Dict[str, Any], agent: str) -> Dict[str, Any]:
    key = _text(arguments, "key", required=True)
    title = _text(arguments, "title", required=True)
    args = ["--json", "add", "--key=" + str(key), "--title=" + str(title)]
    for name, choices in (("kind", ("needs", "done", "info")), ("priority", ("urgent", "normal", "low")),
                          ("context", ("work", "personal"))):
        v = _text(arguments, name)
        if v is not None:
            if v.lower() not in choices:
                raise ToolError("%s must be one of %s" % (name, ", ".join(choices)))
            args.append("--%s=%s" % (name, v.lower()))
    links = arguments.get("links") or []
    if not isinstance(links, list) or len(links) > MAX_LINKS:
        raise ToolError("links must be a list of at most %d links" % MAX_LINKS)
    for i, raw in enumerate(links):
        args.append(_link_arg(_link(raw, "links[%d]" % i)))
    steps = arguments.get("steps") or []
    if not isinstance(steps, list) or len(steps) > MAX_STEPS:
        raise ToolError("steps must be a list of at most %d steps" % MAX_STEPS)
    if steps:
        clean_steps = []
        for i, raw in enumerate(steps):
            if not isinstance(raw, dict) or not isinstance(raw.get("text"), str):
                raise ToolError('steps[%d] must be {"text": "...", "link": {...}, "done": false}' % i)
            step: Dict[str, Any] = {"text": raw["text"]}
            if raw.get("link") is not None:
                step["link"] = _link(raw["link"], "steps[%d].link" % i)
            if raw.get("done") is not None:
                step["done"] = raw["done"]
            clean_steps.append(step)
        args.append("--steps-json=" + json.dumps(clean_steps))
    project = _text(arguments, "project")
    if project is not None:
        args.append("--project=" + project)
    args.append("--agent=" + agent)
    hours = arguments.get("expires_in_hours")
    if hours is not None:
        if isinstance(hours, bool) or not isinstance(hours, (int, float)) or not hours > 0:
            raise ToolError("expires_in_hours must be a number above 0")
        args.append("--expires-in=%s" % hours)
    body = _text(arguments, "body")
    if body is not None:
        args.append("--body-file=-")
    rc, out, err = run_cli(args, stdin=body or "")
    resp = _sent(rc, out, err)
    if resp is None:
        return {"ok": True, "queued": True, "key": key,
                "message": "No hub answered, so the CLI queued it; it goes out by itself when one does. "
                           "Don't retry." + (" (%s)" % err if err else "")}
    state = "created" if resp.get("created") else ("updated" if resp.get("changed") else "unchanged")
    result = {"ok": True, "queued": False, "state": state, "id": resp.get("id"), "key": resp.get("key", key),
              "status": resp.get("status")}
    if err:
        result["note"] = err
    return result


def tool_resolve(arguments: Dict[str, Any]) -> Dict[str, Any]:
    key = _text(arguments, "key", required=True)
    rc, out, err = run_cli(["--json", "resolve", "--key=" + str(key)])
    resp = _sent(rc, out, err)
    if resp is None:
        return {"ok": True, "queued": True, "key": key,
                "message": "No hub answered, so the CLI queued the resolve; it goes out by itself. Don't retry."}
    n = resp.get("resolved", 0)
    return {"ok": True, "queued": False, "key": key, "resolved": n,
            "message": "resolved" if n else "nothing open with that key (already resolved or expired)"}


def tool_doctor(arguments: Dict[str, Any]) -> Dict[str, Any]:
    rc, out, err = run_cli(["doctor", "--json"])
    try:
        report = json.loads(out)
    except ValueError:
        raise ToolError("needs-you doctor gave no report (exit %d): %s" % (rc, err or out.strip()[:500]))
    if not isinstance(report, dict):
        raise ToolError("needs-you doctor gave no report (exit %d)" % rc)
    return report


# ---------------------------------------------------------------------------
# MCP over stdio
# ---------------------------------------------------------------------------

class Server:
    def __init__(self) -> None:
        self.agent = "mcp"

    def handle(self, msg: Any) -> Optional[Dict[str, Any]]:
        """One JSON-RPC message in, its response out (None for notifications and responses)."""
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0":
            return error(msg.get("id") if isinstance(msg, dict) else None, -32600, "invalid request")
        has_id = "id" in msg
        method = msg.get("method")
        if not isinstance(method, str):
            if "result" in msg or "error" in msg:
                return None  # a response to a request of ours; we send none, so ignore it
            return error(msg.get("id"), -32600, "invalid request")
        if not has_id:
            return None  # a notification (initialized, cancelled, ...): nothing to answer
        mid = msg["id"]
        params = msg.get("params") if isinstance(msg.get("params"), dict) else {}
        try:
            if method == "initialize":
                return result(mid, self.initialize(params))
            if method == "ping":
                return result(mid, {})
            if method == "tools/list":
                return result(mid, {"tools": TOOLS})
            if method == "tools/call":
                return self.call(mid, params)
            return error(mid, -32601, "method not found: %s" % method[:100])
        except Exception as e:  # a bug must not kill the server
            return error(mid, -32603, "internal error: %s" % type(e).__name__)

    def initialize(self, params: Dict[str, Any]) -> Dict[str, Any]:
        asked = params.get("protocolVersion")
        version = asked if asked in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0]
        client = params.get("clientInfo")
        name = client.get("name") if isinstance(client, dict) else None
        if isinstance(name, str):
            name = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-")[:90]
            if name:
                self.agent = "mcp:" + name
        return {"protocolVersion": version, "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "needs-you", "title": "needs-you", "version": VERSION},
                "instructions": INSTRUCTIONS}

    def call(self, mid: Any, params: Dict[str, Any]) -> Dict[str, Any]:
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if name not in ("needs_you_add", "needs_you_resolve", "needs_you_doctor"):
            return error(mid, -32602, "unknown tool: %s" % str(name)[:100])
        if not isinstance(arguments, dict):
            return result(mid, tool_result("arguments must be an object", True))
        try:
            if name == "needs_you_add":
                out = tool_add(arguments, self.agent)
            elif name == "needs_you_resolve":
                out = tool_resolve(arguments)
            else:
                out = tool_doctor(arguments)
        except ToolError as e:
            return result(mid, tool_result(redact(str(e)), True))
        return result(mid, tool_result(json.dumps(out, indent=1, sort_keys=True), False, out))


def tool_result(text: str, is_error: bool, structured: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    out: Dict[str, Any] = {"content": [{"type": "text", "text": text}], "isError": is_error}
    if structured is not None:
        out["structuredContent"] = structured
    return out


def result(mid: Any, value: Dict[str, Any]) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": mid, "result": value}


def error(mid: Any, code: int, message: str) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}


def _stop(signum: int, frame: Any) -> None:
    raise SystemExit(0)


def serve(inp: Any = None, out: Any = None) -> int:
    inp = inp or sys.stdin.buffer
    out = out or sys.stdout.buffer
    server = Server()
    while True:
        line = inp.readline()
        if not line:
            return 0  # the client closed stdin: done
        if not line.strip():
            continue
        try:
            msg = json.loads(line.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, RecursionError):  # RecursionError: "[[[[..."
            response: Optional[Any] = error(None, -32700, "parse error")
        else:
            if isinstance(msg, list):
                response = error(None, -32600, "batches are not supported")
            else:
                response = server.handle(msg)
        if response is not None:
            out.write(json.dumps(response, separators=(",", ":")).encode("utf-8") + b"\n")
            out.flush()


def main() -> int:
    signal.signal(signal.SIGTERM, _stop)
    try:
        return serve()
    except (KeyboardInterrupt, BrokenPipeError):
        return 0


if __name__ == "__main__":
    sys.exit(main())
