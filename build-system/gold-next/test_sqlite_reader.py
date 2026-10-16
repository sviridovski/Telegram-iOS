#!/usr/bin/env python3
"""Goldgram #72: real read-only archive SQL, category scoping and uncertainty."""
from pathlib import Path
import re
import sqlite3

src = Path(__file__).with_name("GoldgramHistoryStore.swift").read_text()
def sql(name):
    match = re.search(r"private static let " + name + r' = """\n(.*?)\n    """', src, re.S)
    assert match, name
    return match.group(1)

def schema(name):
    match = re.search(r"private static let " + name + r' = """\n(.*?)\n    """', src, re.S)
    assert match, name
    return match.group(1)

assert '@objc(GoldgramArchiveReader)' in src
assert "SQLITE_OPEN_READONLY" in src
assert 'GoldgramHistoryStore.storageQueue.async' in src
assert 'MxLastKnownUserId' in src  # explicitly rejected in the data contract
assert "observed ? text(stmt, 3) : NSNull()" in src
assert "query_only = ON" in src

def setup():
    db = sqlite3.connect(":memory:")
    db.executescript(schema("schemaV1"))
    db.executescript(schema("schemaV2"))
    db.execute("PRAGMA user_version = 2")
    return db

a, b = setup(), setup()
for db in (a, b):
    for kind, peer in ((0, 10), (1, 20), (2, 20), (3, 20)):
        db.execute("INSERT INTO dialogs(peer_kind,peer_id) VALUES (?,?)", (kind, peer))
        db.execute("""INSERT INTO messages
            (peer_kind,peer_id,message_id,original_text,original_observed,first_seen_at,last_seen_at)
            VALUES (?,?,7,'Начало',1,100,200)""", (kind, peer))
        db.execute("""INSERT INTO events
            (peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at)
            VALUES (?,?,7,1,'goldgram_native_v1',?,200)""", (kind, peer, f"test-{kind}-{peer}"))
a.execute("""INSERT INTO revisions
    (peer_kind,peer_id,message_id,version_index,content,observed_at)
    VALUES (0,10,7,0,'Начало',100)""")
a.execute("""INSERT INTO revisions
    (peer_kind,peer_id,message_id,version_index,content,observed_at)
    VALUES (0,10,7,1,'Редакция',200)""")
b.execute("UPDATE messages SET original_text = 'Другой аккаунт' WHERE peer_kind=0")

dialog_sql = sql("dialogsSQL")
message_sql = sql("messagesSQL")
def dialogs(db, kinds, limit=30, offset=0):
    return db.execute(dialog_sql, (*kinds, limit, offset)).fetchall()
def messages(db, kind, peer, limit=30, offset=0):
    return db.execute(message_sql, (kind, peer, limit, offset)).fetchall()

assert [(r[0], r[1]) for r in dialogs(a, (0,0))] == [(0,10)]
assert {r[0] for r in dialogs(a, (1,2))} == {1,2}
assert [(r[0],r[1]) for r in dialogs(a, (3,3))] == [(3,20)]
assert len(dialogs(a,(1,2), limit=1)) == 1
assert len(dialogs(a,(1,2), limit=1, offset=1)) == 1
assert messages(a, 0, 10)[0][10:13] == ("Редакция", 2, "Начало")
assert messages(a, 1, 20)[0][0:3] == (1,20,7)
assert messages(a, 2, 20)[0][0:3] == (2,20,7)
assert messages(b,0,10)[0][3] == "Другой аккаунт"
assert messages(a,0,10)[0][3] == "Начало"
# Unknown original after catch-up is explicitly not observed as original.
a.execute("UPDATE messages SET original_observed=0 WHERE peer_kind=0")
assert messages(a,0,10)[0][4] == 0
print("Goldgram #72 reader: scoped, paginated, read-only SQL and certainty OK")
