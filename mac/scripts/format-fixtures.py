#!/usr/bin/env python3
"""Demo fixtures for the format tour (mac/scripts/screenshots.sh): every item in
tests/format_cases.py posted to a throwaway hub, then read back as the Mac would see it.

    mac/scripts/format-fixtures.py OUT-DIR

Writes OUT-DIR/formats.json (the catalog as posted) and OUT-DIR/formats-repost.json (the same
items after the catalog's re-posts under their keys). Both in the hub's list shape, which
NEEDS_YOU_DEMO_FIXTURE and NEEDS_YOU_DEMO_REPOST read. Stdlib only, Python 3.9.
"""
from __future__ import annotations

import json
import os
import shutil
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
