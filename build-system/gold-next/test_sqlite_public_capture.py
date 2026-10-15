#!/usr/bin/env python3
"""Goldgram #75: actual Swift DDL/query contracts for live public text."""
from pathlib import Path
import re
import sqlite3

root = Path(__file__).parent
store = (root / "GoldgramHistoryStore.swift").read_text()
host = (root.parents[2] / "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift").read_text()
def block(name):
    m = re.search(r"private static let " + name + r' = """\n(.*?)\n    """', store, re.S)
    assert m, name
    return m.group(1)

assert 'goldgram_archive_public_original_v1' in store and 'goldgram_archive_public_original_v1' in host
assert 'case .group: return 2' in host and 'case .broadcast: return 3' in host
assert 'peer is TelegramGroup ? 1 : nil' in host
assert 'goldgramArchivePublicOriginal(' in host
assert 'GoldgramSQLiteCaptureEnabled' in host
assert 'peerKind: Int32 = 0' in store
assert 'live: true' in store.split('public func goldgramArchivePublicOriginalV1(',1)[1]
assert 'm.peer_kind IN (1, 2, 3) AND m.original_text IS NOT NULL' in block("dialogsSQL")
assert 'm.peer_kind IN (1, 2, 3) AND m.original_text IS NOT NULL' in block("messagesSQL")
# Validate actual SQL placeholder positions, including the extra kind bind.
incoming = store.split("static func archiveIncoming(",1)[1].split("\n}\n\n// Stable C ABI",1)[0]
for fragment, count in [
    ("VALUES (?, ?);", 2),
    ("VALUES (?, ?, ?, ?, ?, ?, ?, ?);", 8),
    ("VALUES (?, ?, ?, 0, ?, ?, ?);", 6),
]:
    assert fragment in incoming, fragment
    assert fragment.count("?") == count
assert "Int64(peerKind), peerId, Int64(messageId)" in incoming

def new_db():
    db = sqlite3.connect(":memory:")
    db.execute("PRAGMA foreign_keys = ON")
    db.executescript(block("schemaV1"))
    db.executescript(block("schemaV2"))
    return db

a, b = new_db(), new_db()
def observe(db, kind, peer, mid, content, sent=1234):
    db.execute("INSERT OR IGNORE INTO dialogs(peer_kind,peer_id) VALUES(?,?)", (kind,peer))
    db.execute("""INSERT OR IGNORE INTO messages
       (peer_kind,peer_id,message_id,original_observed,capture_provenance,
        first_seen_at,last_seen_at,original_text)
       VALUES(?,?,?,1,1,100,100,?)""", (kind,peer,mid,content))
    db.execute("""INSERT OR IGNORE INTO revisions
       (peer_kind,peer_id,message_id,version_index,observed_at,
        revision_provenance,content) VALUES(?,?,?,0,100,1,?)""", (kind,peer,mid,content))
    db.execute("UPDATE messages SET sent_at=? WHERE peer_kind=? AND peer_id=? AND message_id=?",
               (sent,kind,peer,mid))
    db.commit()
for kind in range(4): observe(a,kind,81,9,f"observed-{kind}")
observe(b,3,81,9,"other-account")
observe(a,3,81,9,"SHOULD-NOT-REWRITE")
assert a.execute("SELECT original_text FROM messages WHERE peer_kind=3").fetchone()[0] == "observed-3"
dialogs=block("dialogsSQL")
messages=block("messagesSQL")
def read_dialogs(db,kinds):
    return db.execute(dialogs,(*kinds,30,0)).fetchall()
def read_messages(db,kind):
    return db.execute(messages,(kind,81,30,0)).fetchall()
assert read_dialogs(a,(0,0)) == [], "Original-only private messages remain hidden"
assert {(x[0],x[1]) for x in read_dialogs(a,(1,2))} == {(1,81),(2,81)}
assert {(x[0],x[1]) for x in read_dialogs(a,(3,3))} == {(3,81)}
for kind in (1,2,3):
    item=read_messages(a,kind)[0]
    assert item[0]==kind and item[3]==f"observed-{kind}" and item[4]==1
assert read_messages(a,0) == []
assert read_messages(b,3)[0][3] == "other-account"
# Existing personal edits remain visible via the original event predicate.
a.execute("INSERT INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at) VALUES(0,81,9,1,'test','edit-private',123)")
a.commit()
assert len(read_messages(a,0)) == 1
print("Goldgram #75: live public browse groups/channels, isolated accounts, private event-only OK")
