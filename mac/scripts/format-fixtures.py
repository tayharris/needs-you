#!/usr/bin/env python3
"""Demo fixtures for the format tour (mac/scripts/screenshots.sh): every item in
tests/format_cases.py posted to a throwaway hub, then read back as the Mac would see it.

    mac/scripts/format-fixtures.py OUT-DIR

Writes OUT-DIR/formats.json (the catalog as posted, then the question cards the agent hooks
make from tests/fixtures/questions) and OUT-DIR/formats-repost.json (the same items after the
catalog's re-posts under their keys). Both in the hub's list shape, which
NEEDS_YOU_DEMO_FIXTURE and NEEDS_YOU_DEMO_REPOST read. Stdlib only, Python 3.9.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "hub"))
sys.path.insert(0, os.path.join(ROOT, "tests"))

import format_cases  # noqa: E402
import needs_you_hub as hubmod  # noqa: E402

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
QUESTIONS = os.path.join(ROOT, "tests", "fixtures", "questions")
# (agent, captured payload, extra environment): how each hook's test runs it.
HOOK_CASES = [
    ("claude", "claude-ask-user-question.json", {}),
    ("codex", "codex-request-user-input.json", {}),
    ("gemini", "gemini-ask-user.json", {"GEMINI_PROJECT_DIR": "{cwd}", "CLAUDE_PROJECT_DIR": "{cwd}"}),
    ("copilot", "copilot-elicitation-dialog.json", {"COPILOT_CLI": "1", "COPILOT_PROJECT_DIR": "{cwd}",
                                                    "CLAUDE_PROJECT_DIR": "{cwd}"}),
    ("kimi", "kimi-ask-user-question.json", {}),
    ("claude", "claude-exit-plan-mode.json", {}),
]
FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
"""


def hook_item(tmp, agent, name, extra):
    """The item the hook posts for a captured payload: run it against a fake CLI and read the
    `needs-you add` it ran. None when it posted nothing."""
    home = os.path.join(tmp, "home-%s-%s" % (agent, name))
    cwd = os.path.join(home, "src", "acme-web")
    os.makedirs(cwd)
    cli, log = os.path.join(home, "fake-needs-you"), os.path.join(home, "calls.log")
    with open(cli, "w") as fh:
        fh.write(FAKE_CLI)
    os.chmod(cli, 0o755)
    # The card names the machine: an example name, never this Mac's.
    fake_bin = os.path.join(home, "bin")
    os.makedirs(fake_bin)
    with open(os.path.join(fake_bin, "hostname"), "w") as fh:
        fh.write("#!/bin/sh\necho devbox\n")
    os.chmod(os.path.join(fake_bin, "hostname"), 0o755)
    with open(os.path.join(QUESTIONS, name)) as fh:
        payload = json.load(fh)
    payload.update(session_id="fmt-%s-session" % agent, sessionId="fmt-%s-session" % agent, cwd=cwd)
    env = {"PATH": fake_bin + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home, "NEEDS_YOU_BIN": cli,
           "FAKE_CLI_LOG": log, "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_HOOK_PLATFORM": "linux", "NY_TURN_WAIT": "0"}
    env.update({k: v.replace("{cwd}", cwd) for k, v in extra.items()})
    subprocess.run(["bash", HOOK, "notify", agent], input=json.dumps(payload), env=env, cwd=cwd,
                   capture_output=True, text=True, timeout=30)
    for _ in range(100):  # some hooks post from the background
        if os.path.exists(log):
            break
        time.sleep(0.1)
    time.sleep(0.2)
    try:
        with open(log) as fh:
            calls = [json.loads(line) for line in fh]
    except OSError:
        return None
    argv = next((c for c in reversed(calls) if c and c[0] == "add"), None)
    if not argv:
        return None

    def opt(flag):
        for i, a in enumerate(argv):
            if a == flag and i + 1 < len(argv):
                return argv[i + 1]
            if a.startswith(flag + "="):
                return a[len(flag) + 1:]
        return None
    item = {"title": opt("--title"), "body": opt("--body"), "priority": opt("--priority") or "normal",
            "source": {"host": "devbox", "agent": opt("--agent") or agent, "project": "acme-web"}}
    for flag, field in (("--question-json", "question"), ("--steps-json", "steps")):
        if opt(flag):
            item[field] = json.loads(opt(flag))
    links = [a for i, a in enumerate(argv) if i and argv[i - 1] == "--link"]
    if links:
        item["links"] = [dict(zip(("label", "url"), l.split("=", 1))) for l in links if "=" in l]
    return item


def call(method, url, token, body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with OPENER.open(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main(out):
    os.makedirs(out, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="needs-you-formats-")
    hub = hubmod.Hub(hubmod.load_config(None, {"bind": "127.0.0.1", "port": 0, "db": os.path.join(tmp, "hub.db"),
                                                "hub_id": "formats", "peers": [], "quiet": True}))
    hub.start()
    try:
        sender, _ = hub.store.add_token("formats-sender", "sender")
        reader, _ = hub.store.add_token("formats-reader", "reader")
        keys = {}
        for n, (name, item) in enumerate(format_cases.ACCEPTED, 1):
            keys[name] = "fmt:%02d-%s" % (n, name)
            call("POST", hub.url + "/v1/items", sender, dict(item, key=keys[name]))
            time.sleep(0.002)  # distinct created_at, so the cards keep the catalog's order
        for n, (agent, name, extra) in enumerate(HOOK_CASES, 1):
            item = hook_item(tmp, agent, name, extra)
            if item is None:
                print("format-fixtures: the %s hook posted nothing for %s" % (agent, name), file=sys.stderr)
                continue
            call("POST", hub.url + "/v1/items", sender, dict(item, key="fmt:h%d-%s" % (n, name[:-5])))
        dump(call("GET", hub.url + "/v1/items?status=open", reader), os.path.join(out, "formats.json"))
        for name, item, _ in format_cases.REPOSTS:
            call("POST", hub.url + "/v1/items", sender, dict(item, key=keys[name]))
        dump(call("GET", hub.url + "/v1/items?status=open", reader), os.path.join(out, "formats-repost.json"))
    finally:
        hub.stop()
        shutil.rmtree(tmp, ignore_errors=True)


def dump(page, path):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"items": page["items"]}, fh, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: format-fixtures.py OUT-DIR")
    main(sys.argv[1])
