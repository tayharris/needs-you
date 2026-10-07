"""Shared helpers for the needs-you test suite (stdlib unittest only)."""
from __future__ import annotations

import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from typing import Any, Callable, Dict, List, Optional, Tuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "hub"))

import needs_you_hub as hubmod  # noqa: E402

CLI = os.path.join(ROOT, "cli", "needs-you")
PEER_SECRET = "test-peer-secret-0123456789"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class FakeClock:
    def __init__(self, start: float = 1_790_000_000.0) -> None:
        self.t = start
        self.lock = threading.Lock()

    def __call__(self) -> float:
        with self.lock:
            return self.t

    def advance(self, seconds: float) -> None:
        with self.lock:
            self.t += seconds


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def request(method: str, url: str, token: Optional[str] = None, body: Any = None,
            timeout: float = 5.0) -> Tuple[int, Dict[str, Any]]:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with OPENER.open(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8") or "{}")


def garbage_server(test, payload):
    """A loopback TCP server that answers every connection with `payload` and hangs up.
    Returns its URL; it is closed when the test ends."""
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(16)

    def serve():
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            try:
                conn.settimeout(2)
                conn.recv(65536)
                conn.sendall(payload)
            except OSError:
                pass
            finally:
                conn.close()

    threading.Thread(target=serve, daemon=True).start()
    test.addCleanup(srv.close)
    return "http://127.0.0.1:%d" % srv.getsockname()[1]


def wait_until(pred: Callable[[], bool], timeout: float = 15.0, interval: float = 0.05) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(interval)
    return pred()


def fast_cfg(tmp: str, name: str, **extra: Any) -> Dict[str, Any]:
    cfg = {
        "bind": "127.0.0.1", "port": 0, "db": os.path.join(tmp, name + ".db"), "hub_id": name,
        "peers": [], "peer_secret": PEER_SECRET, "anti_entropy_seconds": 0.5,
        "outbox_poll_seconds": 0.1, "retry_base_seconds": 0.05, "retry_max_seconds": 0.3,
        "peer_timeout_seconds": 1.0, "quiet": True,
    }
    cfg.update(extra)
    return hubmod.load_config(None, cfg)


class HubTestCase(unittest.TestCase):
    """Creates hubs in a temp dir and tears them down."""

    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp(prefix="needs-you-test-")
        self.hubs: List[hubmod.Hub] = []

    def tearDown(self) -> None:
        for h in self.hubs:
            if not h.stopping.is_set():
                h.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def make_hub(self, name: str = "hub-a", clock: Optional[Callable[[], float]] = None,
                 start: bool = True, **extra: Any) -> hubmod.Hub:
        cfg = fast_cfg(self.tmp, name, **extra)
        h = hubmod.Hub(cfg, clock=clock or time.time)
        self.hubs.append(h)
        if start:
            h.start()
        return h

    def tokens(self, hub: hubmod.Hub) -> Tuple[str, str]:
        sender, _ = hub.store.add_token("sender-" + hub.hub_id + "-" + str(len(self.hubs)), "sender")
        reader, _ = hub.store.add_token("reader-" + hub.hub_id + "-" + str(len(self.hubs)), "reader")
        return sender, reader


def snapshot(hub: hubmod.Hub) -> List[Dict[str, Any]]:
    with hub.store.lock:
        rows = [dict(r) for r in hub.store.conn.execute("SELECT * FROM items ORDER BY id")]
    return [hubmod.item_wire(r) for r in rows]


def token_snapshot(hub: hubmod.Hub) -> List[Dict[str, Any]]:
    with hub.store.lock:
        rows = [dict(r) for r in hub.store.conn.execute("SELECT * FROM tokens ORDER BY id")]
    return [hubmod.token_wire(r) for r in rows]
