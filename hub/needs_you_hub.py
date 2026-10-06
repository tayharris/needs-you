#!/usr/bin/env python3
"""needs-you hub: HTTP + SQLite inbox service with peer replication.

Python 3.9+ standard library only. Run directly:

    python3 hub/needs_you_hub.py --config /etc/needs-you/hub.json

The wire contract is in docs/API.md; operating notes are in docs/HUB.md.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import hmac
import json
import os
import random
import re
import secrets
import socket
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Dict, Iterator, List, Optional, Tuple

VERSION = "1.0.0"
API_VERSION = "v1"

# ---------------------------------------------------------------------------
# Limits and enums (docs/PLAN.md "Data model" / "API (v1)")
# ---------------------------------------------------------------------------

CONTEXTS = ("work", "personal")
KINDS = ("needs", "done", "info")
PRIORITIES = ("urgent", "normal", "low")
STATUSES = ("open", "resolved", "dismissed")
PATCH_STATUSES = ("resolved", "dismissed")
ROLES = ("sender", "reader")
LINK_SCHEMES = ("https", "orca", "slack", "vscode", "cursor", "figma", "msteams", "discord")

MAX_TITLE = 100
MAX_BODY = 2000
MAX_KEY = 200
MAX_LINKS = 6
MAX_LINK_LABEL = 80
MAX_LINK_URL = 2000
MAX_SOURCE_FIELD = 100
MAX_REQUEST_BYTES = 64 * 1024
MAX_REPLICATE_BYTES = 8 * 1024 * 1024
DEFAULT_MAX_OPEN_PER_TOKEN = 60
DEFAULT_EXPIRY_HOURS = 24.0
DEFAULT_PORT = 8765
LIST_LIMIT_DEFAULT = 500
LIST_LIMIT_MAX = 2000
EXPIRY_HUB = "~expiry"  # reserved; never a real hub id

ANY_INTERFACE = ("", "0.0.0.0", "::", "[::]", "*")


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str = "", field: Optional[str] = None) -> None:
        super().__init__(message or code)
        self.status = status
        self.code = code
        self.message = message or code
        self.field = field


def _invalid(field: str, message: str) -> ApiError:
    return ApiError(400, "invalid", message, field)


# ---------------------------------------------------------------------------
# Time and ids
# ---------------------------------------------------------------------------

_TS_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?"
    r"(Z|z|[+-]\d{2}:?\d{2})?$"
)


def parse_ts(value: Any) -> int:
    """Parse an ISO 8601 timestamp (or epoch seconds) into epoch milliseconds."""
    if isinstance(value, bool):
        raise ValueError("not a timestamp")
    if isinstance(value, (int, float)):
        return int(round(float(value) * 1000))
    if not isinstance(value, str):
        raise ValueError("not a timestamp")
    s = value.strip()
    if re.match(r"^\d+(\.\d+)?$", s):
        return int(round(float(s) * 1000))
    m = _TS_RE.match(s)
    if not m:
        raise ValueError("bad timestamp: %r" % value)
    y, mo, d, h, mi, se, frac, zone = m.groups()
    ms = int((frac or "0").ljust(3, "0")[:3])
    dt = datetime(int(y), int(mo), int(d), int(h), int(mi), int(se), tzinfo=timezone.utc)
    epoch_ms = int(dt.timestamp()) * 1000 + ms
    if zone and zone not in ("Z", "z"):
        sign = 1 if zone[0] == "+" else -1
        digits = zone[1:].replace(":", "")
        offset_min = int(digits[:2]) * 60 + int(digits[2:])
        epoch_ms -= sign * offset_min * 60 * 1000
    return epoch_ms


def fmt_ts(ms: Optional[int]) -> Optional[str]:
    """Epoch ms -> '2026-10-06T17:04:05.123Z' (fixed width, so it sorts as text)."""
    if ms is None:
        return None
    dt = datetime.fromtimestamp(ms // 1000, timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + ".%03dZ" % (ms % 1000)


_CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def new_ulid(ms: Optional[int] = None) -> str:
    """26-char ULID: 48-bit ms timestamp + 80 random bits, Crockford base32."""
    if ms is None:
        ms = int(time.time() * 1000)
    value = (ms & ((1 << 48) - 1)) << 80 | secrets.randbits(80)
    out = []
    for _ in range(26):
        out.append(_CROCKFORD[value & 31])
        value >>= 5
    return "".join(reversed(out))


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def mint_token() -> str:
    return "ny_" + secrets.token_urlsafe(32)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

KEY_RE = re.compile(r"^[A-Za-z0-9._:/@#+=-]+$")
_CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def _str_field(data: Dict[str, Any], name: str, max_len: int, required: bool = False,
               allow_newlines: bool = False, path: Optional[str] = None) -> Optional[str]:
    path = path or name
    if name not in data or data[name] is None:
        if required:
            raise _invalid(path, "%s is required" % path)
        return None
    v = data[name]
    if not isinstance(v, str):
        raise _invalid(path, "%s must be a string" % path)
    v = v.strip()
    if required and not v:
        raise _invalid(path, "%s must not be empty" % path)
    if len(v) > max_len:
        raise _invalid(path, "%s is longer than %d characters" % (path, max_len))
    bad = _CTRL_RE if allow_newlines else re.compile(r"[\x00-\x1f\x7f]")
    if bad.search(v):
        raise _invalid(path, "%s contains control characters" % path)
    return v


def _enum_field(data: Dict[str, Any], name: str, allowed: Tuple[str, ...], default: str) -> str:
    v = data.get(name)
    if v is None:
        return default
    if not isinstance(v, str) or v.strip().lower() not in allowed:
        raise _invalid(name, "%s must be one of %s" % (name, ", ".join(allowed)))
    return v.strip().lower()


def validate_links(links: Any) -> List[Dict[str, str]]:
    if links is None:
        return []
    if not isinstance(links, list):
        raise _invalid("links", "links must be a list")
    if len(links) > MAX_LINKS:
        raise _invalid("links", "at most %d links" % MAX_LINKS)
    out = []
    for i, link in enumerate(links):
        if not isinstance(link, dict):
            raise _invalid("links[%d]" % i, "links[%d] must be an object" % i)
        label = _str_field(link, "label", MAX_LINK_LABEL, required=True, path="links[%d].label" % i)
        url = _str_field(link, "url", MAX_LINK_URL, required=True, path="links[%d].url" % i)
        assert label is not None and url is not None
        scheme = urllib.parse.urlsplit(url).scheme.lower()
        if scheme not in LINK_SCHEMES:
            raise _invalid("links[%d].url" % i, "links[%d].url scheme %r is not allowed (allowed: %s)"
                           % (i, scheme, ", ".join(LINK_SCHEMES)))
        if len(url) <= len(scheme) + 1:
            raise _invalid("links[%d].url" % i, "links[%d].url is empty" % i)
        out.append({"label": label, "url": url})
    return out


def validate_source(source: Any) -> Dict[str, str]:
    if source is None:
        return {}
    if not isinstance(source, dict):
        raise _invalid("source", "source must be an object")
    out = {}
    for name in ("host", "agent", "project"):
        v = _str_field(source, name, MAX_SOURCE_FIELD, path="source." + name)
        if v:
            out[name] = v
    return out


def validate_item_input(data: Any) -> Dict[str, Any]:
    """Validate a POST /v1/items body. Returns normalised fields (unknown keys ignored)."""
    if not isinstance(data, dict):
        raise ApiError(400, "invalid", "body must be a JSON object")
    if "status" in data:
        raise _invalid("status", "status cannot be set on POST; use resolve or PATCH")
    out: Dict[str, Any] = {}
    out["key"] = _str_field(data, "key", MAX_KEY)
    if out["key"] is not None and not KEY_RE.match(out["key"]):
        raise _invalid("key", "key may only contain letters, digits and . _ : - / @ # + =")
    out["title"] = _str_field(data, "title", MAX_TITLE, required=True)
    out["body"] = _str_field(data, "body", MAX_BODY, allow_newlines=True) or ""
    out["context"] = _enum_field(data, "context", CONTEXTS, "work")
    out["kind"] = _enum_field(data, "kind", KINDS, "needs")
    out["priority"] = _enum_field(data, "priority", PRIORITIES, "normal")
    out["links"] = validate_links(data.get("links"))
    out["source"] = validate_source(data.get("source"))
    out["expires_at"] = None
    if data.get("expires_at") is not None:
        try:
            out["expires_at"] = parse_ts(data["expires_at"])
        except ValueError:
            raise _invalid("expires_at", "expires_at must be an ISO 8601 timestamp")
    return out


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def load_config(path: Optional[str], overrides: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    cfg: Dict[str, Any] = {}
    if path:
        with open(path, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
        if not isinstance(cfg, dict):
            raise SystemExit("config must be a JSON object")
    for k, v in (overrides or {}).items():
        if v is not None:
            cfg[k] = v
    if not cfg.get("peer_secret") and os.environ.get("NEEDS_YOU_PEER_SECRET"):
        cfg["peer_secret"] = os.environ["NEEDS_YOU_PEER_SECRET"]
    if cfg.get("peer_secret_file") and not cfg.get("peer_secret"):
        with open(cfg["peer_secret_file"], "r", encoding="utf-8") as fh:
            cfg["peer_secret"] = fh.read().strip()
    cfg.setdefault("port", DEFAULT_PORT)
    cfg.setdefault("db", "needs-you-hub.db")
    cfg.setdefault("hub_id", socket.gethostname().split(".")[0])
    cfg.setdefault("peers", [])
    cfg.setdefault("max_open_per_token", DEFAULT_MAX_OPEN_PER_TOKEN)
    cfg.setdefault("default_expiry_hours", DEFAULT_EXPIRY_HOURS)
    cfg.setdefault("anti_entropy_seconds", 60.0)
    cfg.setdefault("outbox_poll_seconds", 2.0)
    cfg.setdefault("retry_base_seconds", 1.0)
    cfg.setdefault("retry_max_seconds", 300.0)
    cfg.setdefault("peer_timeout_seconds", 5.0)
    cfg.setdefault("allow_any_interface", False)
    cfg.setdefault("freebind", False)
    cfg["peers"] = [str(p).rstrip("/") for p in cfg["peers"] if str(p).strip()]
    return cfg


def check_bind(cfg: Dict[str, Any]) -> None:
    bind = cfg.get("bind")
    if bind is None:
        raise SystemExit("bind address is required (config \"bind\" or --bind), e.g. your tailnet IP "
                         "from `tailscale ip -4`")
    if str(bind).strip() in ANY_INTERFACE and not cfg.get("allow_any_interface"):
        raise SystemExit("refusing to bind to all interfaces (%r); bind to the tailnet IP or pass "
                         "--allow-any-interface" % bind)
    if cfg.get("peers"):
        secret = cfg.get("peer_secret") or ""
        if len(secret) < 16:
            raise SystemExit("peers are configured but peer_secret is missing or shorter than 16 chars")
    hub_id = str(cfg.get("hub_id") or "")
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", hub_id):
        raise SystemExit("hub_id must be 1-64 chars of letters, digits, '.', '_' or '-'")


# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS items (
  id TEXT PRIMARY KEY,
  key TEXT NOT NULL,
  context TEXT NOT NULL,
  kind TEXT NOT NULL,
  priority TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  links TEXT NOT NULL DEFAULT '[]',
  source TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  content_updated_at INTEGER NOT NULL,
  seen_at INTEGER,
  expires_at INTEGER,
  token_id TEXT,
  origin_hub TEXT NOT NULL DEFAULT '',
  updated_by TEXT NOT NULL DEFAULT '',
  superseded_by TEXT,
  seq INTEGER NOT NULL,
  local_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS items_key_status ON items(key, status);
CREATE INDEX IF NOT EXISTS items_seq ON items(seq);
CREATE INDEX IF NOT EXISTS items_local_at ON items(local_at);
CREATE INDEX IF NOT EXISTS items_token_status ON items(token_id, status);
CREATE TABLE IF NOT EXISTS tokens (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  role TEXT NOT NULL,
  hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  revoked_at INTEGER,
  updated_by TEXT NOT NULL DEFAULT '',
  seq INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS tokens_seq ON tokens(seq);
CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  peer TEXT NOT NULL,
  kind TEXT NOT NULL,
  record_id TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS outbox_peer ON outbox(peer, id);
CREATE TABLE IF NOT EXISTS peer_state (
  peer TEXT PRIMARY KEY,
  cursor INTEGER NOT NULL DEFAULT 0,
  epoch TEXT NOT NULL DEFAULT '',
  last_push_ok INTEGER,
  last_pull_ok INTEGER,
  last_error TEXT
);
"""

ITEM_COLS = ("id", "key", "context", "kind", "priority", "title", "body", "links", "source",
             "status", "created_at", "updated_at", "content_updated_at", "seen_at", "expires_at",
             "token_id", "origin_hub", "updated_by", "superseded_by", "seq", "local_at")
TOKEN_COLS = ("id", "name", "role", "hash", "created_at", "updated_at", "revoked_at",
              "updated_by", "seq")


class Store:
    """SQLite access. One connection, serialised by a lock; WAL so the admin tool can share it."""

    def __init__(self, path: str, hub_id: str, peers: List[str],
                 clock: Callable[[], float] = time.time) -> None:
        self.path = path
        self.hub_id = hub_id
        self.peers = list(peers)
        self.clock = clock
        self.lock = threading.RLock()
        d = os.path.dirname(os.path.abspath(path))
        os.makedirs(d, exist_ok=True)
        self.conn = sqlite3.connect(path, isolation_level=None, check_same_thread=False, timeout=10)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA busy_timeout=10000")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        with self.lock:
            self.conn.executescript(SCHEMA)
            self.conn.execute("INSERT OR IGNORE INTO meta(k, v) VALUES('seq', '0')")
            self.conn.execute("INSERT OR IGNORE INTO meta(k, v) VALUES('epoch', ?)", (new_ulid(),))
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass

    def close(self) -> None:
        with self.lock:
            self.conn.close()

    # -- plumbing --------------------------------------------------------

    def now_ms(self) -> int:
        return int(self.clock() * 1000)

    @contextlib.contextmanager
    def tx(self) -> Iterator[sqlite3.Connection]:
        with self.lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                yield self.conn
            except BaseException:
                self.conn.execute("ROLLBACK")
                raise
            self.conn.execute("COMMIT")

    def next_seq(self) -> int:
        self.conn.execute("UPDATE meta SET v = CAST(v AS INTEGER) + 1 WHERE k = 'seq'")
        return int(self.conn.execute("SELECT v FROM meta WHERE k = 'seq'").fetchone()[0])

    def epoch(self) -> str:
        with self.lock:
            return self.conn.execute("SELECT v FROM meta WHERE k = 'epoch'").fetchone()[0]

    def max_seq(self) -> int:
        with self.lock:
            return int(self.conn.execute("SELECT v FROM meta WHERE k = 'seq'").fetchone()[0])

    def enqueue(self, kind: str, record_id: str, exclude: Optional[str] = None) -> None:
        now = self.now_ms()
        for peer in self.peers:
            if peer == exclude:
                continue
            self.conn.execute("INSERT INTO outbox(peer, kind, record_id, created_at) VALUES(?,?,?,?)",
                              (peer, kind, record_id, now))

    def bump(self, prev: Optional[int]) -> int:
        """A new updated_at that is strictly after prev (so LWW always moves forward)."""
        now = self.now_ms()
        if prev is not None and now <= prev:
            return prev + 1
        return now

    @staticmethod
    def newer(a_updated: int, a_by: str, b_updated: int, b_by: str) -> bool:
        return (a_updated, a_by or "") > (b_updated, b_by or "")

    # -- items -----------------------------------------------------------

    def _write_item(self, rec: Dict[str, Any]) -> None:
        rec = dict(rec)
        rec["seq"] = self.next_seq()
        rec["local_at"] = self.now_ms()  # when *this* hub stored this version: the `since` cursor
        cols = ",".join(ITEM_COLS)
        marks = ",".join("?" for _ in ITEM_COLS)
        self.conn.execute("INSERT OR REPLACE INTO items(%s) VALUES(%s)" % (cols, marks),
                          tuple(rec.get(c) for c in ITEM_COLS))

    def get_item(self, item_id: str) -> Optional[Dict[str, Any]]:
        with self.lock:
            row = self.conn.execute("SELECT * FROM items WHERE id = ?", (item_id,)).fetchone()
        return dict(row) if row else None

    def _effective_open(self, key: str, now: int, exclude_id: Optional[str] = None) -> List[Dict[str, Any]]:
        rows = self.conn.execute(
            "SELECT * FROM items WHERE key = ? AND status = 'open' "
            "AND (expires_at IS NULL OR expires_at > ?) ORDER BY id", (key, now)).fetchall()
        return [dict(r) for r in rows if r["id"] != exclude_id]

    def open_count_for_token(self, token_id: str) -> int:
        now = self.now_ms()
        with self.lock:
            return int(self.conn.execute(
                "SELECT COUNT(*) FROM items WHERE token_id = ? AND status = 'open' "
                "AND (expires_at IS NULL OR expires_at > ?)", (token_id, now)).fetchone()[0])

    def upsert_item(self, fields: Dict[str, Any], token: Optional[Dict[str, Any]],
                    max_open: int, default_expiry_ms: int) -> Tuple[Dict[str, Any], bool, bool]:
        """Create or upsert-by-key. Returns (record, created, changed)."""
        with self.tx():
            now = self.now_ms()
            expires = fields["expires_at"]
            if expires is None and fields["kind"] in ("done", "info"):
                expires = now + default_expiry_ms
            existing = self._effective_open(fields["key"], now) if fields["key"] else []
            if existing:
                cur = existing[0]
                changed = (cur["title"] != fields["title"] or cur["body"] != fields["body"]
                           or cur["priority"] != fields["priority"])
                updated = self.bump(cur["updated_at"])
                rec = dict(cur)
                rec.update({
                    "context": fields["context"], "kind": fields["kind"],
                    "priority": fields["priority"], "title": fields["title"], "body": fields["body"],
                    "links": json.dumps(fields["links"]), "source": json.dumps(fields["source"]),
                    "updated_at": updated, "updated_by": self.hub_id, "expires_at": expires,
                    "token_id": token["id"] if token else cur["token_id"],
                })
                if changed:
                    rec["content_updated_at"] = updated
                self._write_item(rec)
                self.enqueue("item", rec["id"])
                return rec, False, changed
            if token is not None and max_open > 0:
                n = self.conn.execute(
                    "SELECT COUNT(*) FROM items WHERE token_id = ? AND status = 'open' "
                    "AND (expires_at IS NULL OR expires_at > ?)", (token["id"], now)).fetchone()[0]
                if n >= max_open:
                    raise ApiError(429, "too_many_open",
                                   "token %r already has %d open items (limit %d); something is "
                                   "probably looping" % (token["name"], n, max_open))
            item_id = new_ulid(now)
            rec = {
                "id": item_id, "key": fields["key"] or item_id, "context": fields["context"],
                "kind": fields["kind"], "priority": fields["priority"], "title": fields["title"],
                "body": fields["body"], "links": json.dumps(fields["links"]),
                "source": json.dumps(fields["source"]), "status": "open",
                "created_at": now, "updated_at": now, "content_updated_at": now,
                "seen_at": None, "expires_at": expires, "token_id": token["id"] if token else None,
                "origin_hub": self.hub_id, "updated_by": self.hub_id, "superseded_by": None,
            }
            self._write_item(rec)
            self.enqueue("item", item_id)
            return rec, True, True

    def resolve(self, item_id: Optional[str], key: Optional[str]) -> List[Dict[str, Any]]:
        with self.tx():
            now = self.now_ms()
            if item_id:
                row = self.conn.execute("SELECT * FROM items WHERE id = ?", (item_id,)).fetchone()
                targets = [dict(row)] if row else []
            else:
                targets = self._effective_open(key or "", now)
            out = []
            for cur in targets:
                if cur["status"] != "open" or (cur["expires_at"] is not None and cur["expires_at"] <= now):
                    continue  # already closed or expired: nothing to do (idempotent)
                rec = dict(cur)
                rec.update({"status": "resolved", "updated_at": self.bump(cur["updated_at"]),
                            "updated_by": self.hub_id})
                self._write_item(rec)
                self.enqueue("item", rec["id"])
                out.append(rec)
            return out

    def patch(self, item_id: str, status: Optional[str], seen_at: Any, has_seen: bool) -> Dict[str, Any]:
        with self.tx():
            row = self.conn.execute("SELECT * FROM items WHERE id = ?", (item_id,)).fetchone()
            if not row:
                raise ApiError(404, "not_found", "no item with that id")
            rec = dict(row)
            if status is not None:
                rec["status"] = status
            if has_seen:
                rec["seen_at"] = seen_at
            rec["updated_at"] = self.bump(rec["updated_at"])
            rec["updated_by"] = self.hub_id
            self._write_item(rec)
            self.enqueue("item", rec["id"])
            return rec

    def list_items(self, status: str, since: Optional[int], limit: int
                   ) -> Tuple[List[Dict[str, Any]], int, bool]:
        """Returns (records, cursor, more).

        With `since`: every item this hub stored a new version of after `since` (exclusive),
        in any status, plus open items whose expiry passed after `since`; `status` is ignored.
        Without `since`: the current set for `status` (default open).
        `cursor` is what the client sends back as the next `since`."""
        with self.lock:
            now = self.now_ms()
            args: List[Any] = []
            if since is not None:
                sql = ("SELECT * FROM items WHERE local_at > ? OR "
                       "(status = 'open' AND expires_at > ? AND expires_at <= ?)")
                args += [since, since, now]
            else:
                sql = "SELECT * FROM items WHERE 1=1"
                if status == "open":
                    sql += " AND status = 'open' AND (expires_at IS NULL OR expires_at > ?)"
                    args.append(now)
                elif status == "resolved":
                    sql += " AND (status = 'resolved' OR (status = 'open' AND expires_at <= ?))"
                    args.append(now)
                elif status == "dismissed":
                    sql += " AND status = 'dismissed'"
            sql += " ORDER BY local_at, id LIMIT ?"
            args.append(limit + 1)
            rows = [dict(r) for r in self.conn.execute(sql, args).fetchall()]
        more = len(rows) > limit
        rows = rows[:limit]
        # 1 ms behind "now": a write landing in this same millisecond is still after the cursor.
        cursor = now - 1
        if more and since is not None:
            cursor = max(since, rows[-1]["local_at"] - 1)
        return rows, cursor, more

    # -- replication -----------------------------------------------------

    def apply_item(self, rec: Dict[str, Any], from_peer: Optional[str] = None) -> bool:
        """Last-writer-wins apply of a replicated item record. Returns True if it changed local state."""
        rec = normalise_item_record(rec)
        with self.tx():
            row = self.conn.execute("SELECT * FROM items WHERE id = ?", (rec["id"],)).fetchone()
            if row is not None and not self.newer(rec["updated_at"], rec["updated_by"],
                                                  row["updated_at"], row["updated_by"]):
                return False
            self._write_item(rec)
            now = self.now_ms()
            if rec["status"] == "open" and (rec["expires_at"] is None or rec["expires_at"] > now):
                others = self._effective_open(rec["key"], now, exclude_id=rec["id"])
                if others:
                    self._merge_duplicates([rec] + others)
                    return True
            self._settle_content(rec["superseded_by"] or rec["id"])
            return True

    CONTENT_COLS = ("context", "kind", "priority", "title", "body", "links", "source", "expires_at",
                    "token_id", "content_updated_at")

    @staticmethod
    def _content_rank(r: Dict[str, Any]) -> Tuple[int, int, str]:
        return (r["content_updated_at"], r["updated_at"], r["updated_by"] or "")

    def _settle_content(self, winner_id: str) -> None:
        """Invariant after a merge: the winner carries the freshest content (by
        content_updated_at) of itself and every item superseded by it. Hubs may see merges
        in different orders; re-applying this rule makes them all land on the same content."""
        row = self.conn.execute("SELECT * FROM items WHERE id = ?", (winner_id,)).fetchone()
        if row is None:
            return
        winner = dict(row)
        losers = [dict(r) for r in self.conn.execute(
            "SELECT * FROM items WHERE superseded_by = ?", (winner_id,))]
        if not losers:
            return
        best = max([winner] + losers, key=self._content_rank)
        if best is winner or self._content_rank(best) <= self._content_rank(winner):
            return
        for col in self.CONTENT_COLS:
            winner[col] = best[col]
        winner["updated_at"] = self.bump(max(r["updated_at"] for r in [winner] + losers))
        winner["updated_by"] = self.hub_id
        self._write_item(winner)
        self.enqueue("item", winner["id"])

    def _merge_duplicates(self, recs: List[Dict[str, Any]]) -> None:
        """Two hubs minted different ids for one open key. The lowest id wins; the freshest
        content (by content_updated_at, then updated_at, then hub id) is kept on the winner; losers are closed as
        resolved with superseded_by = winner id. Both writes are replicated."""
        recs = sorted(recs, key=lambda r: r["id"])
        winner = dict(recs[0])
        freshest = max(recs, key=self._content_rank)
        stamp = self.bump(max(r["updated_at"] for r in recs))
        for col in self.CONTENT_COLS:
            winner[col] = freshest[col]
        winner["created_at"] = min(r["created_at"] for r in recs)
        seen = [r["seen_at"] for r in recs if r["seen_at"] is not None]
        winner["seen_at"] = max(seen) if seen else None
        winner["updated_at"] = stamp
        winner["updated_by"] = self.hub_id
        self._write_item(winner)
        self.enqueue("item", winner["id"])
        for loser in recs[1:]:
            lo = dict(loser)
            lo.update({"status": "resolved", "superseded_by": winner["id"], "updated_at": stamp,
                       "updated_by": self.hub_id})
            self._write_item(lo)
            self.enqueue("item", lo["id"])

    def apply_token(self, rec: Dict[str, Any]) -> bool:
        rec = normalise_token_record(rec)
        with self.tx():
            row = self.conn.execute("SELECT * FROM tokens WHERE id = ?", (rec["id"],)).fetchone()
            if row is not None and not self.newer(rec["updated_at"], rec["updated_by"],
                                                  row["updated_at"], row["updated_by"]):
                return False
            # a token hash is unique; a different id with the same hash would be a collision
            clash = self.conn.execute("SELECT id FROM tokens WHERE hash = ? AND id != ?",
                                      (rec["hash"], rec["id"])).fetchone()
            if clash:
                return False
            self._write_token(rec)
            return True

    def changes(self, after: int, limit: int) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]], int, bool]:
        with self.lock:
            items = [dict(r) for r in self.conn.execute(
                "SELECT * FROM items WHERE seq > ? ORDER BY seq LIMIT ?", (after, limit + 1))]
            toks = [dict(r) for r in self.conn.execute(
                "SELECT * FROM tokens WHERE seq > ? ORDER BY seq LIMIT ?", (after, limit + 1))]
        merged = sorted([("item", r) for r in items] + [("token", r) for r in toks],
                        key=lambda x: x[1]["seq"])
        more = len(merged) > limit
        merged = merged[:limit]
        next_after = merged[-1][1]["seq"] if merged else after
        return ([r for k, r in merged if k == "item"], [r for k, r in merged if k == "token"],
                next_after, more)

    # -- tokens ----------------------------------------------------------

    def _write_token(self, rec: Dict[str, Any]) -> None:
        rec = dict(rec)
        rec["seq"] = self.next_seq()
        cols = ",".join(TOKEN_COLS)
        marks = ",".join("?" for _ in TOKEN_COLS)
        self.conn.execute("INSERT OR REPLACE INTO tokens(%s) VALUES(%s)" % (cols, marks),
                          tuple(rec.get(c) for c in TOKEN_COLS))

    def add_token(self, name: str, role: str) -> Tuple[str, Dict[str, Any]]:
        if role not in ROLES:
            raise ValueError("role must be one of %s" % ", ".join(ROLES))
        if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._:@-]{0,63}$", name):
            raise ValueError("name must be 1-64 chars of letters, digits, '.', '_', ':', '@' or '-'")
        token = mint_token()
        with self.tx():
            clash = self.conn.execute(
                "SELECT id FROM tokens WHERE name = ? AND revoked_at IS NULL", (name,)).fetchone()
            if clash:
                raise ValueError("an active token named %r already exists" % name)
            now = self.now_ms()
            rec = {"id": new_ulid(now), "name": name, "role": role, "hash": hash_token(token),
                   "created_at": now, "updated_at": now, "revoked_at": None,
                   "updated_by": self.hub_id}
            self._write_token(rec)
            self.enqueue("token", rec["id"])
        return token, rec

    def revoke_token(self, name_or_id: str) -> List[Dict[str, Any]]:
        with self.tx():
            rows = self.conn.execute(
                "SELECT * FROM tokens WHERE (name = ? OR id = ?) AND revoked_at IS NULL",
                (name_or_id, name_or_id)).fetchall()
            out = []
            for row in rows:
                rec = dict(row)
                stamp = self.bump(rec["updated_at"])
                rec.update({"revoked_at": stamp, "updated_at": stamp, "updated_by": self.hub_id})
                self._write_token(rec)
                self.enqueue("token", rec["id"])
                out.append(rec)
            return out

    def list_tokens(self) -> List[Dict[str, Any]]:
        now = self.now_ms()
        with self.lock:
            rows = self.conn.execute(
                "SELECT t.*, (SELECT COUNT(*) FROM items i WHERE i.token_id = t.id AND "
                "i.status = 'open' AND (i.expires_at IS NULL OR i.expires_at > ?)) AS open_items "
                "FROM tokens t ORDER BY t.created_at", (now,)).fetchall()
        return [dict(r) for r in rows]

    def token_by_secret(self, token: str) -> Optional[Dict[str, Any]]:
        h = hash_token(token)
        with self.lock:
            row = self.conn.execute(
                "SELECT * FROM tokens WHERE hash = ? AND revoked_at IS NULL", (h,)).fetchone()
        return dict(row) if row else None

    # -- outbox / peer state --------------------------------------------

    def outbox_batch(self, peer: str, limit: int) -> List[Dict[str, Any]]:
        with self.lock:
            return [dict(r) for r in self.conn.execute(
                "SELECT * FROM outbox WHERE peer = ? ORDER BY id LIMIT ?", (peer, limit))]

    def outbox_ack(self, peer: str, max_id: int) -> None:
        with self.tx():
            self.conn.execute("DELETE FROM outbox WHERE peer = ? AND id <= ?", (peer, max_id))

    def outbox_pending(self, peer: str) -> int:
        with self.lock:
            return int(self.conn.execute("SELECT COUNT(*) FROM outbox WHERE peer = ?",
                                         (peer,)).fetchone()[0])

    def records_for(self, rows: List[Dict[str, Any]]) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
        item_ids = sorted({r["record_id"] for r in rows if r["kind"] == "item"})
        token_ids = sorted({r["record_id"] for r in rows if r["kind"] == "token"})
        items, toks = [], []
        with self.lock:
            for i in item_ids:
                row = self.conn.execute("SELECT * FROM items WHERE id = ?", (i,)).fetchone()
                if row:
                    items.append(dict(row))
            for t in token_ids:
                row = self.conn.execute("SELECT * FROM tokens WHERE id = ?", (t,)).fetchone()
                if row:
                    toks.append(dict(row))
        return items, toks

    def peer_state(self, peer: str) -> Dict[str, Any]:
        with self.lock:
            row = self.conn.execute("SELECT * FROM peer_state WHERE peer = ?", (peer,)).fetchone()
        if row:
            return dict(row)
        return {"peer": peer, "cursor": 0, "epoch": "", "last_push_ok": None,
                "last_pull_ok": None, "last_error": None}

    def save_peer_state(self, peer: str, **fields: Any) -> None:
        st = self.peer_state(peer)
        st.update(fields)
        with self.tx():
            self.conn.execute(
                "INSERT OR REPLACE INTO peer_state(peer, cursor, epoch, last_push_ok, last_pull_ok, "
                "last_error) VALUES(?,?,?,?,?,?)",
                (peer, st["cursor"], st["epoch"], st["last_push_ok"], st["last_pull_ok"],
                 st["last_error"]))


def normalise_item_record(rec: Any) -> Dict[str, Any]:
    """Accept a replicated item record (wire form: ISO timestamps, JSON links/source)."""
    if not isinstance(rec, dict):
        raise ApiError(400, "invalid", "item record must be an object")
    out: Dict[str, Any] = {}
    try:
        for c in ("id", "key", "context", "kind", "priority", "title", "status"):
            v = rec[c]
            if not isinstance(v, str) or not v:
                raise ValueError(c)
            out[c] = v
        out["body"] = rec.get("body") or ""
        out["links"] = json.dumps(rec.get("links") or [])
        out["source"] = json.dumps(rec.get("source") or {})
        for c in ("created_at", "updated_at"):
            out[c] = parse_ts(rec[c])
        out["content_updated_at"] = parse_ts(rec.get("content_updated_at") or rec["updated_at"])
        for c in ("seen_at", "expires_at"):
            out[c] = parse_ts(rec[c]) if rec.get(c) is not None else None
        out["token_id"] = rec.get("token_id")
        out["origin_hub"] = rec.get("origin_hub") or ""
        out["updated_by"] = rec.get("updated_by") or ""
        out["superseded_by"] = rec.get("superseded_by")
    except (KeyError, ValueError, TypeError) as e:
        raise ApiError(400, "invalid", "bad item record: %s" % e)
    if out["status"] not in STATUSES:
        raise ApiError(400, "invalid", "bad item status")
    return out


def normalise_token_record(rec: Any) -> Dict[str, Any]:
    if not isinstance(rec, dict):
        raise ApiError(400, "invalid", "token record must be an object")
    try:
        out = {c: rec[c] for c in ("id", "name", "role", "hash")}
        out["created_at"] = parse_ts(rec["created_at"])
        out["updated_at"] = parse_ts(rec["updated_at"])
        out["revoked_at"] = parse_ts(rec["revoked_at"]) if rec.get("revoked_at") is not None else None
        out["updated_by"] = rec.get("updated_by") or ""
    except (KeyError, ValueError, TypeError) as e:
        raise ApiError(400, "invalid", "bad token record: %s" % e)
    if out["role"] not in ROLES or not re.match(r"^[0-9a-f]{64}$", str(out["hash"])):
        raise ApiError(400, "invalid", "bad token record")
    return out


def item_public(rec: Dict[str, Any], now_ms: int) -> Dict[str, Any]:
    status = rec["status"]
    if status == "open" and rec["expires_at"] is not None and rec["expires_at"] <= now_ms:
        status = "resolved"  # expired: reported as resolved, never written
    links = rec["links"]
    source = rec["source"]
    return {
        "id": rec["id"], "key": rec["key"], "context": rec["context"], "kind": rec["kind"],
        "priority": rec["priority"], "title": rec["title"], "body": rec["body"] or None,
        "links": json.loads(links) if isinstance(links, str) else links,
        "source": json.loads(source) if isinstance(source, str) else source,
        "status": status,
        "created_at": fmt_ts(rec["created_at"]), "updated_at": fmt_ts(rec["updated_at"]),
        "content_updated_at": fmt_ts(rec["content_updated_at"]),
        "seen_at": fmt_ts(rec["seen_at"]), "expires_at": fmt_ts(rec["expires_at"]),
        "superseded_by": rec.get("superseded_by"),
    }


def item_wire(rec: Dict[str, Any]) -> Dict[str, Any]:
    """Full record for replication (raw status, plus bookkeeping fields)."""
    out = item_public(rec, -1)
    out["status"] = rec["status"]
    out["token_id"] = rec.get("token_id")
    out["origin_hub"] = rec.get("origin_hub") or ""
    out["updated_by"] = rec.get("updated_by") or ""
    return out


def token_wire(rec: Dict[str, Any]) -> Dict[str, Any]:
    return {"id": rec["id"], "name": rec["name"], "role": rec["role"], "hash": rec["hash"],
            "created_at": fmt_ts(rec["created_at"]), "updated_at": fmt_ts(rec["updated_at"]),
            "revoked_at": fmt_ts(rec["revoked_at"]), "updated_by": rec.get("updated_by") or ""}


# ---------------------------------------------------------------------------
# Peer replication worker
# ---------------------------------------------------------------------------

_NO_PROXY_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class PeerWorker(threading.Thread):
    """Per-peer thread: drains the durable outbox (push) and runs anti-entropy (pull)."""

    def __init__(self, hub: "Hub", peer: str) -> None:
        super().__init__(name="peer:%s" % peer, daemon=True)
        self.hub = hub
        self.peer = peer
        self.wake = threading.Event()
        self.failures = 0
        self.next_push = 0.0
        self.next_pull = 0.0
        self.disabled = False

    def _request(self, method: str, path: str, body: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(self.peer + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.hub.cfg["peer_secret"])
        req.add_header("X-Needs-You-Hub", self.hub.hub_id)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        with _NO_PROXY_OPENER.open(req, timeout=float(self.hub.cfg["peer_timeout_seconds"])) as resp:
            return json.loads(resp.read().decode("utf-8") or "{}")

    def run(self) -> None:
        while not self.hub.stopping.is_set() and not self.disabled:
            now = time.monotonic()
            did_work = False
            if now >= self.next_push:
                did_work = self.push_once()
            if now >= self.next_pull and not self.disabled:
                self.pull()
                self.next_pull = time.monotonic() + float(self.hub.cfg["anti_entropy_seconds"])
            if did_work:
                continue
            now = time.monotonic()
            wait = float(self.hub.cfg["outbox_poll_seconds"])
            if self.next_push > now:
                wait = max(wait, self.next_push - now) if self.failures else wait
            wait = min(wait, max(0.0, self.next_pull - now))
            self.wake.wait(max(0.05, wait))
            self.wake.clear()

    def _fail(self, err: Exception) -> None:
        self.failures += 1
        base = float(self.hub.cfg["retry_base_seconds"])
        delay = min(base * (2 ** (self.failures - 1)), float(self.hub.cfg["retry_max_seconds"]))
        delay *= random.uniform(0.8, 1.2)
        self.next_push = time.monotonic() + delay
        try:
            self.hub.store.save_peer_state(self.peer, last_error="%s: %s" % (type(err).__name__, err))
        except sqlite3.Error:
            pass

    def push_once(self) -> bool:
        """Send one batch. Returns True if something was sent (so the caller loops again)."""
        rows = self.hub.store.outbox_batch(self.peer, 200)
        if not rows:
            self.failures = 0
            return False
        items, toks = self.hub.store.records_for(rows)
        payload = {"from_hub": self.hub.hub_id, "items": [item_wire(r) for r in items],
                   "tokens": [token_wire(r) for r in toks]}
        try:
            self._request("POST", "/v1/replicate", payload)
        except urllib.error.HTTPError as e:
            if e.code == 409:  # the "peer" is this hub
                self.disabled = True
                self.hub.store.outbox_ack(self.peer, max(r["id"] for r in rows))
                return False
            self._fail(e)
            return False
        except (OSError, ValueError) as e:
            self._fail(e)
            return False
        self.hub.store.outbox_ack(self.peer, max(r["id"] for r in rows))
        self.failures = 0
        self.hub.store.save_peer_state(self.peer, last_push_ok=self.hub.store.now_ms(), last_error=None)
        return True

    def pull(self) -> None:
        st = self.hub.store.peer_state(self.peer)
        cursor, epoch = int(st["cursor"]), st["epoch"]
        try:
            for _ in range(10000):
                q = urllib.parse.urlencode({"after": cursor, "limit": 500})
                resp = self._request("GET", "/v1/replicate/changes?" + q)
                if resp.get("hub_id") == self.hub.hub_id:
                    self.disabled = True
                    return
                peer_epoch = str(resp.get("epoch") or "")
                if peer_epoch != epoch or int(resp.get("max_seq", 0)) < cursor:
                    # first contact, or the peer's database was replaced: restart from zero
                    epoch = peer_epoch
                    if cursor != 0:
                        cursor = 0
                        continue
                for t in resp.get("tokens", []):
                    self.hub.store.apply_token(t)
                changed = False
                for it in resp.get("items", []):
                    changed = self.hub.store.apply_item(it, from_peer=self.peer) or changed
                if changed:
                    self.hub.notify()
                cursor = int(resp.get("next_after", cursor))
                self.hub.store.save_peer_state(self.peer, cursor=cursor, epoch=epoch,
                                               last_pull_ok=self.hub.store.now_ms())
                if not resp.get("more"):
                    break
        except (OSError, ValueError, ApiError) as e:
            try:
                self.hub.store.save_peer_state(self.peer, last_error="pull %s: %s" % (type(e).__name__, e))
            except sqlite3.Error:
                pass


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "needs-you-hub/" + VERSION
    protocol_version = "HTTP/1.0"
    hub: "Hub"  # set on the subclass per server

    def log_message(self, fmt: str, *args: Any) -> None:  # quieter, and to stderr
        if self.hub.cfg.get("access_log", True) and not self.hub.cfg.get("quiet"):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # -- helpers ---------------------------------------------------------

    def _send(self, status: int, body: Any, headers: Optional[Dict[str, str]] = None) -> None:
        data = json.dumps(body, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _error(self, err: ApiError) -> None:
        body = {"error": err.code, "message": err.message}
        if err.field:
            body["field"] = err.field
        self._send(err.status, body)

    def _body(self, limit: int = MAX_REQUEST_BYTES) -> Any:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise ApiError(400, "invalid", "bad Content-Length")
        if length > limit:
            raise ApiError(413, "too_large", "request body over %d bytes" % limit)
        raw = self.rfile.read(length) if length else b""
        if not raw:
            raise ApiError(400, "invalid", "a JSON body is required")
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ApiError(400, "invalid", "body is not valid JSON")

    def _bearer(self) -> Optional[str]:
        auth = self.headers.get("Authorization") or ""
        if auth[:7].lower() == "bearer ":
            return auth[7:].strip()
        return None

    def _auth(self, role: Optional[str]) -> Dict[str, Any]:
        tok = self._bearer()
        if not tok:
            raise ApiError(401, "unauthorized", "missing bearer token")
        rec = self.hub.store.token_by_secret(tok)
        if rec is None:
            raise ApiError(401, "unauthorized", "unknown or revoked token")
        if role is not None and rec["role"] != role:
            raise ApiError(403, "forbidden", "this endpoint needs a %s token (this one is %s)"
                           % (role, rec["role"]))
        return rec

    def _peer_auth(self) -> None:
        secret = self.hub.cfg.get("peer_secret") or ""
        tok = self._bearer() or ""
        if not secret:
            raise ApiError(404, "not_found", "replication is not enabled on this hub")
        if not hmac.compare_digest(tok.encode("utf-8"), secret.encode("utf-8")):
            raise ApiError(401, "unauthorized", "bad peer secret")

    def _route(self, method: str) -> None:
        try:
            parsed = urllib.parse.urlsplit(self.path)
            path = parsed.path.rstrip("/") or "/"
            query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
            if path == "/v1/health" and method in ("GET", "HEAD"):
                return self._health()
            if path == "/v1/items" and method == "POST":
                return self._post_item()
            if path == "/v1/items" and method == "GET":
                return self._list(query)
            if path == "/v1/items/resolve" and method == "POST":
                return self._resolve()
            if path.startswith("/v1/items/") and method in ("PATCH", "GET"):
                item_id = urllib.parse.unquote(path[len("/v1/items/"):])
                if "/" not in item_id and item_id:
                    return self._patch(item_id) if method == "PATCH" else self._get_one(item_id)
            if path == "/v1/stream" and method == "GET":
                return self._stream(query)
            if path == "/v1/replicate" and method == "POST":
                return self._replicate()
            if path == "/v1/replicate/changes" and method == "GET":
                return self._changes(query)
            raise ApiError(404, "not_found", "no such endpoint")
        except ApiError as e:
            self._error(e)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:  # pragma: no cover - last resort
            sys.stderr.write("internal error: %r\n" % (e,))
            try:
                self._error(ApiError(500, "internal", "internal error"))
            except OSError:
                pass

    def do_GET(self) -> None:
        self._route("GET")

    def do_HEAD(self) -> None:
        self._route("HEAD")

    def do_POST(self) -> None:
        self._route("POST")

    def do_PATCH(self) -> None:
        self._route("PATCH")

    def do_PUT(self) -> None:
        self._route("PUT")

    def do_DELETE(self) -> None:
        self._route("DELETE")

    # -- endpoints -------------------------------------------------------

    def _health(self) -> None:
        st = self.hub.store
        body: Dict[str, Any] = {"ok": True, "hub_id": self.hub.hub_id, "version": VERSION,
                                "api": API_VERSION, "time": fmt_ts(st.now_ms())}
        bearer = self._bearer()
        if bearer:
            tok = self.hub.store.token_by_secret(bearer)
            if tok is None:
                body["token"] = None
                body["token_error"] = "unknown or revoked token"
            else:
                body["token"] = {"name": tok["name"], "role": tok["role"]}
                body["peers"] = [self.hub.peer_status(p) for p in self.hub.cfg["peers"]]
        self._send(200, body)

    def _post_item(self) -> None:
        tok = self._auth("sender")
        fields = validate_item_input(self._body())
        rec, created, changed = self.hub.store.upsert_item(
            fields, tok, int(self.hub.cfg["max_open_per_token"]),
            int(float(self.hub.cfg["default_expiry_hours"]) * 3600 * 1000))
        self.hub.notify()
        out = item_public(rec, self.hub.store.now_ms())
        out["created"] = created
        out["changed"] = changed
        self._send(201 if created else 200, out)

    def _resolve(self) -> None:
        self._auth("sender")
        data = self._body()
        if not isinstance(data, dict):
            raise ApiError(400, "invalid", "body must be a JSON object")
        item_id = data.get("id")
        key = data.get("key")
        if bool(item_id) == bool(key):
            raise ApiError(400, "invalid", "send exactly one of id or key")
        if not isinstance(item_id or key, str):
            raise ApiError(400, "invalid", "id/key must be a string")
        recs = self.hub.store.resolve(item_id, key)
        if recs:
            self.hub.notify()
        now = self.hub.store.now_ms()
        self._send(200, {"resolved": len(recs), "items": [item_public(r, now) for r in recs]})

    def _patch(self, item_id: str) -> None:
        self._auth("reader")
        data = self._body()
        if not isinstance(data, dict):
            raise ApiError(400, "invalid", "body must be a JSON object")
        status = None
        if data.get("status") is not None:
            status = data["status"]
            if status not in PATCH_STATUSES:
                raise ApiError(400, "invalid", "status must be one of %s" % ", ".join(PATCH_STATUSES))
        has_seen = "seen_at" in data
        seen = None
        if has_seen and data["seen_at"] is not None:
            try:
                seen = parse_ts(data["seen_at"])
            except ValueError:
                raise ApiError(400, "invalid", "seen_at must be an ISO 8601 timestamp or null")
        if status is None and not has_seen:
            raise ApiError(400, "invalid", "nothing to change (status and/or seen_at)")
        rec = self.hub.store.patch(item_id, status, seen, has_seen)
        self.hub.notify()
        self._send(200, item_public(rec, self.hub.store.now_ms()))

    def _get_one(self, item_id: str) -> None:
        self._auth("reader")
        rec = self.hub.store.get_item(item_id)
        if not rec:
            raise ApiError(404, "not_found", "no item with that id")
        self._send(200, item_public(rec, self.hub.store.now_ms()))

    def _list(self, query: Dict[str, List[str]]) -> None:
        self._auth("reader")
        status = (query.get("status") or ["open"])[0] or "open"
        if status not in STATUSES + ("all",):
            raise ApiError(400, "invalid", "status must be open, resolved, dismissed or all")
        since = None
        if (query.get("since") or [""])[0]:
            try:
                since = parse_ts(query["since"][0])
            except ValueError:
                raise ApiError(400, "invalid", "since must be an ISO 8601 timestamp")
        try:
            limit = int((query.get("limit") or [LIST_LIMIT_DEFAULT])[0])
        except ValueError:
            raise ApiError(400, "invalid", "limit must be an integer")
        limit = max(1, min(limit, LIST_LIMIT_MAX))
        recs, cursor, more = self.hub.store.list_items(status, since, limit)
        now = self.hub.store.now_ms()
        self._send(200, {"items": [item_public(r, now) for r in recs], "server_time": fmt_ts(cursor),
                         "hub_id": self.hub.hub_id, "more": more})

    def _stream(self, query: Dict[str, List[str]]) -> None:
        self._auth("reader")
        last = self.headers.get("Last-Event-ID") or (query.get("after") or [""])[0]
        try:
            after = int(last) if last else self.hub.store.max_seq()
        except ValueError:
            after = self.hub.store.max_seq()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        self.wfile.write(b": connected\n\n")
        self.wfile.flush()
        heartbeat = float(self.hub.cfg.get("sse_heartbeat_seconds", 15.0))
        while not self.hub.stopping.is_set():
            items, _toks, next_after, _more = self.hub.store.changes(after, 200)
            now = self.hub.store.now_ms()
            for r in items:
                msg = "id: %d\nevent: item\ndata: %s\n\n" % (
                    r["seq"], json.dumps(item_public(r, now), separators=(",", ":"), sort_keys=True))
                self.wfile.write(msg.encode("utf-8"))
            after = next_after
            if items:
                self.wfile.flush()
                continue
            with self.hub.changed:
                self.hub.changed.wait(heartbeat)
            self.wfile.write(b": ping\n\n")
            self.wfile.flush()

    def _replicate(self) -> None:
        self._peer_auth()
        data = self._body(MAX_REPLICATE_BYTES)
        if not isinstance(data, dict):
            raise ApiError(400, "invalid", "body must be a JSON object")
        if data.get("from_hub") == self.hub.hub_id:
            raise ApiError(409, "self", "a hub cannot replicate to itself")
        applied = 0
        for t in data.get("tokens") or []:
            applied += 1 if self.hub.store.apply_token(t) else 0
        for it in data.get("items") or []:
            applied += 1 if self.hub.store.apply_item(it) else 0
        if applied:
            self.hub.notify()
        self._send(200, {"ok": True, "applied": applied, "hub_id": self.hub.hub_id})

    def _changes(self, query: Dict[str, List[str]]) -> None:
        self._peer_auth()
        try:
            after = int((query.get("after") or ["0"])[0] or 0)
            limit = max(1, min(int((query.get("limit") or ["500"])[0] or 500), 2000))
        except ValueError:
            raise ApiError(400, "invalid", "after/limit must be integers")
        st = self.hub.store
        items, toks, next_after, more = st.changes(after, limit)
        self._send(200, {"hub_id": self.hub.hub_id, "epoch": st.epoch(), "max_seq": st.max_seq(),
                         "next_after": next_after, "more": more,
                         "items": [item_wire(r) for r in items],
                         "tokens": [token_wire(r) for r in toks]})


class _Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr: Tuple[str, int], handler: Any, freebind: bool = False) -> None:
        self._freebind = freebind
        if ":" in addr[0]:
            self.address_family = socket.AF_INET6
        super().__init__(addr, handler)

    def server_bind(self) -> None:
        if self._freebind and sys.platform.startswith("linux"):
            # Lets the hub start before tailscaled has assigned the tailnet IP.
            self.socket.setsockopt(socket.IPPROTO_IP, getattr(socket, "IP_FREEBIND", 15), 1)
        super().server_bind()


class Hub:
    def __init__(self, cfg: Dict[str, Any], clock: Callable[[], float] = time.time) -> None:
        check_bind(cfg)
        self.cfg = cfg
        self.hub_id = str(cfg["hub_id"])
        self.store = Store(cfg["db"], self.hub_id, cfg["peers"], clock)
        self.stopping = threading.Event()
        self.changed = threading.Condition()
        self.workers: Dict[str, PeerWorker] = {}
        self._drop_stale_outbox()

        handler = type("BoundHandler", (Handler,), {"hub": self})
        bind = str(cfg["bind"]).strip("[]")
        if bind in ANY_INTERFACE:
            bind = "0.0.0.0"
        self.server = _Server((bind, int(cfg["port"])), handler, bool(cfg.get("freebind")))
        self.port = self.server.server_address[1]
        self.thread: Optional[threading.Thread] = None

    @property
    def url(self) -> str:
        host = self.server.server_address[0]
        if ":" in host:
            host = "[%s]" % host
        return "http://%s:%d" % (host, self.port)

    def set_peers(self, peers: List[str]) -> None:
        """Replace the peer list (before start(); used by tests that bind port 0 first)."""
        if peers and len(self.cfg.get("peer_secret") or "") < 16:
            raise ValueError("peer_secret required")
        self.cfg["peers"] = [p.rstrip("/") for p in peers]
        self.store.peers = list(self.cfg["peers"])

    def _drop_stale_outbox(self) -> None:
        peers = self.cfg["peers"]
        with self.store.tx() as c:
            if peers:
                marks = ",".join("?" for _ in peers)
                c.execute("DELETE FROM outbox WHERE peer NOT IN (%s)" % marks, tuple(peers))
            else:
                c.execute("DELETE FROM outbox")

    def notify(self) -> None:
        with self.changed:
            self.changed.notify_all()
        for w in self.workers.values():
            w.wake.set()

    def peer_status(self, peer: str) -> Dict[str, Any]:
        st = self.store.peer_state(peer)
        return {"url": peer, "outbox_pending": self.store.outbox_pending(peer),
                "last_push_ok": fmt_ts(st["last_push_ok"]), "last_pull_ok": fmt_ts(st["last_pull_ok"]),
                "last_error": st["last_error"]}

    def start(self) -> "Hub":
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.1},
                                       name="http", daemon=True)
        self.thread.start()
        for peer in self.cfg["peers"]:
            w = PeerWorker(self, peer)
            self.workers[peer] = w
            w.start()
        return self

    def stop(self) -> None:
        self.stopping.set()
        self.notify()
        if self.thread is not None:
            self.server.shutdown()
        self.server.server_close()
        for w in self.workers.values():
            w.wake.set()
            w.join(timeout=10)
        if self.thread:
            self.thread.join(timeout=5)
        self.store.close()


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(description="needs-you hub (API v1)")
    p.add_argument("--config", help="JSON config file (see deploy/hub.example.json)")
    p.add_argument("--bind", help="address to listen on (required here or in the config)")
    p.add_argument("--port", type=int)
    p.add_argument("--db", help="SQLite database path")
    p.add_argument("--hub-id", dest="hub_id")
    p.add_argument("--allow-any-interface", action="store_true", default=None,
                   help="allow binding to 0.0.0.0 / :: (not recommended)")
    args = p.parse_args(argv)
    cfg = load_config(args.config, {"bind": args.bind, "port": args.port, "db": args.db,
                                    "hub_id": args.hub_id,
                                    "allow_any_interface": args.allow_any_interface})
    hub = Hub(cfg)
    sys.stderr.write("needs-you-hub %s (%s) listening on %s, %d peer(s)\n"
                     % (VERSION, hub.hub_id, hub.url, len(cfg["peers"])))
    hub.start()
    import signal

    done = threading.Event()

    def _stop(*_a: Any) -> None:
        done.set()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    while not done.wait(1.0):
        pass
    hub.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
