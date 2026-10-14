#!/usr/bin/env python3
"""Goldgram #68: SQLite version/event invariants on actual Swift v1/v2 DDL.

Uses independent in-memory per-account DBs and mirrors the v68 SQL contract.
CI must also compile the actual Swift/ObjC code in the later build step.
"""
from pathlib import Path
import re
import sqlite3

source = (Path(__file__).parent / "GoldgramHistoryStore.swift").read_text()
host = (Path(__file__).parents[2] / "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift").read_text()
def schema(which):
    m = re.search(r"private static let " + which + r' = """\n(.*?)\n    """', source, re.S)
    assert m, which
    return m.group(1)

def new_db():
    db = sqlite3.connect(":memory:", isolation_level=None)
    db.execute("PRAGMA foreign_keys = ON")
    db.executescript(schema("schemaV1"))
    for sql in schema("schemaV2").split(";"):
        if sql.strip():
            db.execute(sql)
    db.execute("PRAGMA user_version = 2")
    return db

assert 'goldgram_archive_edit_v1' in source
assert 'goldgramArchivePrivateEdit(' in host
assert 'case let .updateEditMessage(updateEditMessageData):' in host
assert re.search(r"original_text\s*,\s*original_observed", source), ("Original columns not found in Goldgram Swift SQL")
assert 'lastSavedRevision(' in source

# The importer and live-capture storage use independently scoped databases.
alice, bob = new_db(), new_db()

def original(db, peer, mid, text):
    db.execute("INSERT OR IGNORE INTO dialogs(peer_kind,peer_id) VALUES (0,?)", (peer,))
    db.execute(
        "INSERT OR IGNORE INTO messages(peer_kind,peer_id,message_id,original_text,original_observed,first_seen_at,last_seen_at,capture_provenance) VALUES (0,?,?,?,1,100,100,1)",
        (peer, mid, text)
    )
    db.execute(
        "INSERT OR IGNORE INTO revisions(peer_kind,peer_id,message_id,version_index,content,observed_at,revision_provenance) VALUES (0,?,?,0,?,100,1)",
        (peer, mid, text)
    )

def edit(db, peer, mid, content, timestamp):
    db.execute("BEGIN IMMEDIATE")
    try:
        db.execute("INSERT OR IGNORE INTO dialogs(peer_kind,peer_id) VALUES (0,?)", (peer,))
        db.execute(
            "INSERT OR IGNORE INTO messages(peer_kind,peer_id,message_id,original_text,original_observed,capture_provenance,first_seen_at,last_seen_at) VALUES (0,?,?,NULL,0,0,100,100)",
            (peer, mid)
        )
        last = db.execute(
            "SELECT version_index,content FROM revisions WHERE peer_kind=0 AND peer_id=? AND message_id=? ORDER BY version_index DESC LIMIT 1",
            (peer, mid)
        ).fetchone()
        if last is None or last[1] != content:
            index = 0 if last is None else last[0] + 1
            db.execute(
                "INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,content,observed_at,server_edit_at,revision_provenance) VALUES (0,?,?,?,?,?, ?,3)",
                (peer, mid, index, content, 200+index, timestamp)
            )
            db.execute(
                "INSERT OR IGNORE INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,server_time,observed_at) VALUES (0,?,?,1,'telegram_edit_update',?,?,?)",
                (peer, mid, f"goldgram.edit.0.{peer}.{mid}.{index}", timestamp, 200+index)
            )
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise

original(alice, 123, 10, "До")
edit(alice, 123, 10, "После", 1600)
edit(alice, 123, 10, "После", 1600)
edit(alice, 123, 10, "После-2", 1700)
edit(alice, 123, 10, "До", 1800)  # legitimate revert is another edit
assert [x[0] for x in alice.execute(
    "SELECT content FROM revisions WHERE peer_id=123 AND message_id=10 ORDER BY version_index"
)] == ["До","После","После-2","До"]
assert alice.execute("SELECT original_text FROM messages WHERE peer_id=123 AND message_id=10").fetchone()[0] == "До"
assert alice.execute("SELECT COUNT(*) FROM events WHERE peer_id=123").fetchone()[0] == 3
# Previously unseen edit must NOT fabricate a pre-edit original.
edit(alice, 333, 99, "Только изменённое", 1900)
assert alice.execute(
    "SELECT original_text,original_observed,capture_provenance FROM messages WHERE peer_id=333"
).fetchone() == (None,0,0)
assert alice.execute(
    "SELECT version_index,revision_provenance FROM revisions WHERE peer_id=333"
).fetchone() == (0,3)
# Same raw message ID in different accounts must not collide.
original(bob, 123, 10, "Иной аккаунт")
edit(bob, 123, 10, "Иная правка", 2000)
assert bob.execute("SELECT original_text FROM messages WHERE peer_id=123 AND message_id=10").fetchone()[0] == "Иной аккаунт"
assert bob.execute("SELECT COUNT(*) FROM events").fetchone()[0] == 1

# Transaction rollback: revision insert can't remain if event insertion fails.
alice.execute("BEGIN IMMEDIATE")
try:
    alice.execute(
        "INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,content,observed_at,revision_provenance) VALUES (0,123,10,4,'failure',999,3)"
    )
    alice.execute(
        "INSERT INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at) VALUES (0,123,10,1,'test','goldgram.edit.0.123.10.1',999)"
    )
except sqlite3.IntegrityError:
    alice.execute("ROLLBACK")
else:
    raise AssertionError("Duplicate event key did not trigger rollback")
assert alice.execute(
    "SELECT COUNT(*) FROM revisions WHERE peer_id=123 AND message_id=10"
).fetchone()[0] == 4

# Extract the *actual Swift SQL strings*, not just the Python behavioral mirror:
# archiveSQL binds numeric parameters first and the text parameter LAST.
# These executions catch real bind-order/count regressions at the next build.
edit_source = source.split("static func archiveEdit(", 1)[1].split(
    "static func archiveIncoming(", 1
)[0]
rev_query = re.search(r"INSERT INTO revisions\s+\(.*?\)\s+VALUES\s+\(.*?\);", edit_source, re.S)
event_query = re.search(r"INSERT OR IGNORE INTO events\s+\(.*?\)\s+VALUES\s+\(.*?\);", edit_source, re.S)
assert rev_query and event_query, "Swift runtime revision/event queries missing"
actual = new_db()
actual.execute("INSERT INTO dialogs (peer_kind,peer_id) VALUES (0,500)")
actual.execute(
    "INSERT INTO messages (peer_kind,peer_id,message_id,original_observed,first_seen_at,last_seen_at) VALUES (0,500,9,0,100,100)"
)
# Mirrors Goldgram.archiveSQL parameters: Int64 arguments precede text.
actual.execute(rev_query.group(0), (500,9,0,120,150,"текст правки"))
actual.execute(
    event_query.group(0),
    (500,9,150,120,"goldgram.edit.0.500.9.0")
)
assert actual.execute(
    "SELECT version_index,content,observed_at,server_edit_at,revision_provenance FROM revisions"
).fetchone() == (0,"текст правки",120,150,3)
assert actual.execute(
    "SELECT event_key,server_time,observed_at FROM events"
).fetchone() == ("goldgram.edit.0.500.9.0",150,120)

print("Goldgram edits #68: dedupe, reverts, honest unknown original, isolation, rollback OK")
