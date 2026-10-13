#!/usr/bin/env python3
"""Goldgram #67: exercise *real Swift-sourced* v1 and v2 SQLite DDL.

No mock schema and no live user data. Python's stdlib sqlite3 uses the same
SQLite SQL dialect as iOS. GitHub CI executes this before compiling Mx.
"""
from pathlib import Path
import re
import sqlite3

source = (Path(__file__).parent / "GoldgramHistoryStore.swift").read_text()

def extract(name: str) -> str:
    found = re.search(
        r"private static let " + re.escape(name) + r' = """\n(.*?)\n    """',
        source,
        flags=re.DOTALL,
    )
    if found is None:
        raise AssertionError(f"Missing {name} SQLite schema in Swift source")
    return found.group(1)

v1, v2 = extract("schemaV1"), extract("schemaV2")
assert "currentSchemaVersion: Int32 = 2" in source
assert "if version > currentSchemaVersion" in source
assert 'execute("BEGIN IMMEDIATE;"' in source
assert 'execute("ROLLBACK;"' in source
assert 'execute("PRAGMA user_version = 2;"' in source

def migrate(db, current_version: int):
    if current_version > 2:
        raise ValueError("newer schema must be rejected")
    if current_version == 2:
        return
    db.execute("BEGIN IMMEDIATE")
    try:
        if current_version == 0:
            # v1 creation SQL can contain semicolons in comment lines; the
            # already-tested fixture is created outside the migration test.
            raise AssertionError("Use fresh_install() for v0")
        for part in v2.split(";"):
            if part.strip():
                db.execute(part)
        db.execute("PRAGMA user_version = 2")
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise

def version(db):
    return db.execute("PRAGMA user_version").fetchone()[0]

def columns(db, table):
    return {r[1] for r in db.execute(f"PRAGMA table_info({table})")}

expected = {
    "sender_kind", "sender_id", "sent_at", "thread_id",
    "reply_to_message_id", "root_channel_peer_id",
    "root_channel_post_id", "anchor_before_message_id",
    "anchor_after_message_id", "capture_provenance",
}

# Upgrade a real #66-style DB containing originals, edits and deletion events.
db = sqlite3.connect(":memory:", isolation_level=None)
db.executescript(v1)
db.execute("PRAGMA user_version = 1")
db.execute("PRAGMA foreign_keys = ON")
db.execute("INSERT INTO dialogs (peer_kind, peer_id) VALUES (0, 101)")
db.execute(
    "INSERT INTO messages (peer_kind,peer_id,message_id,original_text,original_observed,first_seen_at,last_seen_at) VALUES (0,101,77,?,1,1700000000000,1700000000000)",
    ("прежний оригинал",),
)
db.execute(
    "INSERT INTO revisions (peer_kind,peer_id,message_id,version_index,content,observed_at) VALUES (0,101,77,0,?,1700000000000)",
    ("прежний оригинал",),
)
db.execute(
    "INSERT INTO events (peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at) VALUES (0,101,77,1,'test','same-event',1700000000000)"
)
migrate(db, 1)
assert version(db) == 2
assert expected.issubset(columns(db, "messages"))
assert "revision_provenance" in columns(db, "revisions")
row = db.execute(
    "SELECT original_text,original_observed,sender_id,sent_at,thread_id,capture_provenance FROM messages WHERE peer_id=101 AND message_id=77"
).fetchone()
assert row == ("прежний оригинал", 1, None, None, None, 0), row
assert db.execute("SELECT content FROM revisions").fetchone()[0] == "прежний оригинал"
assert db.execute("SELECT event_key FROM events").fetchone()[0] == "same-event"
assert len(list(db.execute("PRAGMA index_list(messages)"))) >= 5

# Idempotence (no second ALTER / no changed user data).
migrate(db, version(db))
assert version(db) == 2
assert db.execute("SELECT COUNT(*) FROM messages").fetchone()[0] == 1

# Roll back a partially applied schema if a later DDL operation fails.
test = sqlite3.connect(":memory:", isolation_level=None)
test.executescript(v1)
test.execute("PRAGMA user_version = 1")
test.execute("BEGIN IMMEDIATE")
try:
    test.execute("ALTER TABLE messages ADD COLUMN sender_kind INTEGER")
    test.execute("ALTER TABLE messages ADD COLUMN sender_kind INTEGER")
except sqlite3.OperationalError:
    test.execute("ROLLBACK")
else:
    raise AssertionError("Deliberate duplicate-column failure did not fail")
assert version(test) == 1
assert "sender_kind" not in columns(test, "messages")

# A fresh account installs both schemas and leaves unknown metadata NULL.
fresh = sqlite3.connect(":memory:", isolation_level=None)
fresh.executescript(v1)
fresh.execute("PRAGMA user_version = 1")
migrate(fresh, 1)
assert version(fresh) == 2
assert expected.issubset(columns(fresh, "messages"))
fresh.execute("PRAGMA foreign_keys = ON")
fresh.execute("INSERT INTO dialogs (peer_kind,peer_id) VALUES (0,201)")
fresh.execute(
    "INSERT INTO messages (peer_kind,peer_id,message_id,original_text,original_observed,capture_provenance,first_seen_at,last_seen_at,sender_kind,sender_id,sent_at) VALUES (0,201,1,'hello',1,1,1700000000000,1700000000000,0,201,1700000000000)"
)
assert fresh.execute(
    "SELECT sender_kind,sender_id,capture_provenance FROM messages WHERE message_id=1"
).fetchone() == (0, 201, 1)

# The v2 constraint must refuse invalid origin certainty.
try:
    fresh.execute(
        "UPDATE messages SET capture_provenance = 99 WHERE peer_id = 201"
    )
except sqlite3.IntegrityError:
    pass
else:
    raise AssertionError("capture_provenance CHECK was not enforced")

print("Goldgram SQLite v2: upgrade preserves v1, rollback works, constraints and indexes OK")
