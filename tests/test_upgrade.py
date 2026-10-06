"""Upgrading must never lose data: a database exactly as the previous release (main at
f43bf2f, before schema versioning) wrote it is opened by the current hub, and every item,
token, outbox row and cursor survives; a backup is taken first; auto_vacuum is converted.
"""
from __future__ import annotations

import glob
import os
import sqlite3
import time
import unittest

from support import PEER_SECRET, HubTestCase, hubmod, request

# The schema of hub/needs_you_hub.py at f43bf2f, verbatim. Never edit this fixture: it is
# what real databases in the field look like.
MAIN_F43BF2F_SCHEMA = """
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

PEER = "http://hub-b.example.ts.net:8765"
TABLES = ("items", "tokens", "outbox", "peer_state", "meta")


def make_main_db(path):
    """Create and fill a DB the way the f43bf2f hub did (WAL, auto_vacuum NONE, user_version 0)."""
    c = sqlite3.connect(path, isolation_level=None)
    c.execute("PRAGMA journal_mode=WAL")
    c.executescript(MAIN_F43BF2F_SCHEMA)
    c.execute("INSERT OR IGNORE INTO meta(k, v) VALUES('seq', '5')")
    c.execute("INSERT OR IGNORE INTO meta(k, v) VALUES('epoch', '01OLDEPOCH0000000000000000')")
    now = int(time.time() * 1000)
    c.execute("INSERT INTO items(id, key, context, kind, priority, title, body, links, source, status, "
              "created_at, updated_at, content_updated_at, seen_at, expires_at, token_id, origin_hub, "
              "updated_by, superseded_by, seq, local_at) VALUES "
              "('01AAAAAAAAAAAAAAAAAAAAAAAA', 'work:ACME-1:x', 'work', 'needs', 'urgent', 'Decide', 'b', "
              "'[{\"label\": \"PR\", \"url\": \"https://example.com/pr/1\"}]', '{\"host\": \"my-server\"}', "
              "'open', ?, ?, ?, NULL, NULL, '01TOKENAAAAAAAAAAAAAAAAAAA', 'hub-a', 'hub-a', NULL, 1, ?)",
              (now, now, now, now))
    c.execute("INSERT INTO items(id, key, context, kind, priority, title, status, created_at, updated_at, "
              "content_updated_at, seq, local_at) VALUES ('01BBBBBBBBBBBBBBBBBBBBBBBB', 'k2', 'personal', "
              "'needs', 'low', 'Second', 'resolved', ?, ?, ?, 2, ?)", (now, now, now, now))
    c.execute("INSERT INTO tokens VALUES ('01TOKENAAAAAAAAAAAAAAAAAAA', 'my-server', 'sender', ?, ?, ?, "
              "NULL, 'hub-a', 3)", (hubmod.hash_token("ny_old_sender_token"), now, now))
    c.execute("INSERT INTO tokens VALUES ('01TOKENBBBBBBBBBBBBBBBBBBB', 'mac', 'reader', ?, ?, ?, NULL, "
              "'hub-a', 4)", (hubmod.hash_token("ny_old_reader_token"), now, now))
    c.execute("INSERT INTO outbox(peer, kind, record_id, created_at) VALUES (?, 'item', "
              "'01AAAAAAAAAAAAAAAAAAAAAAAA', ?)", (PEER, now))
    c.execute("INSERT INTO peer_state VALUES (?, 42, '01PEEREPOCH', ?, ?, NULL)", (PEER, now, now))
    assert c.execute("PRAGMA user_version").fetchone()[0] == 0
    assert c.execute("PRAGMA auto_vacuum").fetchone()[0] == 0
    c.close()


def dump(path):
    c = sqlite3.connect(path)
    try:
        return {t: sorted(c.execute("SELECT * FROM %s" % t).fetchall()) for t in TABLES}
    finally:
        c.close()


class UpgradeFromMain(HubTestCase):
    def test_main_db_survives_the_upgrade(self):
        db = os.path.join(self.tmp, "hub.db")
        make_main_db(db)
        before = dump(db)
        hub = self.make_hub("hub-a", db=db, peers=[PEER], start=False)
        st = hub.store
        # schema migrated, auto_vacuum converted
        self.assertEqual(st.conn.execute("PRAGMA user_version").fetchone()[0], hubmod.SCHEMA_VERSION)
        self.assertEqual(st.conn.execute("PRAGMA auto_vacuum").fetchone()[0], 2)
        self.assertEqual(st.conn.execute("SELECT COUNT(*) FROM invites").fetchone()[0], 0)
        # every row survived unchanged
        with st.lock:
            after = {t: sorted(tuple(r) for r in st.conn.execute("SELECT * FROM %s" % t)) for t in TABLES}
        self.assertEqual(after, before)
        # and it works: old tokens authenticate, the old item is listed, the outbox is pending
        hub.start()
        _, body = request("GET", hub.url + "/v1/items", "ny_old_reader_token")
        self.assertEqual([i["key"] for i in body["items"]], ["work:ACME-1:x"])
        self.assertEqual(body["items"][0]["links"], [{"label": "PR", "url": "https://example.com/pr/1"}])
        status, _ = request("POST", hub.url + "/v1/items", "ny_old_sender_token", {"key": "new", "title": "t"})
        self.assertEqual(status, 201)
        self.assertGreaterEqual(st.outbox_pending(PEER), 1)
        # a backup of the old file was taken first and is the untouched old database
        self.assertEqual(st.backup_path, db + ".bak-0")
        bak = sqlite3.connect(db + ".bak-0")
        self.assertEqual(bak.execute("PRAGMA user_version").fetchone()[0], 0)
        self.assertEqual(bak.execute("SELECT COUNT(*) FROM items").fetchone()[0], 2)
        bak.close()
        self.assertEqual(oct(os.stat(db + ".bak-0").st_mode & 0o777), "0o600")

    def test_reopening_is_a_no_op_and_backups_are_capped(self):
        db = os.path.join(self.tmp, "hub.db")
        make_main_db(db)
        hubmod.Store(db, "hub-a", []).close()
        st = hubmod.Store(db, "hub-a", [])  # already current: no new backup
        self.assertIsNone(st.backup_path)
        st.close()
        for v in (7, 8, 9):  # older backups lying around
            open("%s.bak-%d" % (db, v), "w").close()
            time.sleep(0.02)
        c = sqlite3.connect(db)
        c.execute("PRAGMA user_version = 1")  # an intermediate version: migrate 1 -> current
        c.close()
        st = hubmod.Store(db, "hub-a", [])
        st.close()
        baks = sorted(os.path.basename(p) for p in glob.glob(db + ".bak-*"))
        self.assertEqual(len(baks), hubmod.DB_BACKUPS_KEPT)
        self.assertIn("hub.db.bak-1", baks)

    def test_newer_database_is_refused_untouched(self):
        db = os.path.join(self.tmp, "hub.db")
        make_main_db(db)
        hubmod.Store(db, "hub-a", []).close()
        c = sqlite3.connect(db)
        c.execute("PRAGMA user_version = %d" % (hubmod.SCHEMA_VERSION + 1))
        c.close()
        before = dump(db)
        with self.assertRaises(SystemExit):
            hubmod.Store(db, "hub-a", [])
        self.assertEqual(dump(db), before)

    def test_old_config_shape_still_loads(self):
        # old configs have "bind" as one string and no public_url / retention keys
        cfg = hubmod.load_config(None, {"bind": "100.64.1.2", "peers": [PEER], "peer_secret": PEER_SECRET,
                                        "hub_id": "hub-a", "port": 8765, "freebind": True})
        self.assertEqual(cfg["bind"], ["100.64.1.2"])
        self.assertEqual(cfg["retention_days"], 7.0)
        hubmod.check_bind(cfg)


if __name__ == "__main__":
    unittest.main()
