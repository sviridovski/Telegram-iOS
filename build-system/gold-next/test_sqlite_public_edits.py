#!/usr/bin/env python3
"""#77: new public edits are keyed by kind and keep recorded original immutable."""
from pathlib import Path
import sqlite3, re

base = Path(__file__).parent
source = (base / "GoldgramHistoryStore.swift").read_text()
host = (base.parents[1] / "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift").read_text()

def ddl(name):
    match = re.search(r"private static let " + name + r' = """\n(.*?)\n    """', source, re.S)
    assert match, name
    return match.group(1)
assert "goldgram_archive_public_edit_v1" in source and "goldgram_archive_public_edit_v1" in host
assert "goldgramArchivePublicEdit(" in host
assert "goldgramVerifiedPublicKind" in host
assert "if previousState.pts >= pts" in host and "previousState.pts + ptsCount == pts" in host
assert "GoldgramSQLiteCaptureEnabled" in host
assert "let key = \"goldgram.edit.\\(peerKind)" in source
frag = source.split("static func archiveEdit(",1)[1].split("static func archiveIncoming(",1)[0]
revision_sql = re.search(r"INSERT INTO revisions\s+\(.*?\)\s+VALUES\s+\(.*?\);", frag, re.S).group(0)
event_sql = re.search(r"INSERT OR IGNORE INTO events\s+\(.*?\)\s+VALUES\s+\(.*?\);", frag, re.S).group(0)
assert revision_sql.count("?") == 7, revision_sql
assert event_sql.count("?") == 6, event_sql

def new():
    db=sqlite3.connect(":memory:")
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript(ddl("schemaV1"))
    db.executescript(ddl("schemaV2"))
    return db

db, second=new(),new()
for kind,peer in ((0,98),(2,98),(3,98)):
    db.execute("INSERT INTO dialogs(peer_kind,peer_id) VALUES(?,?)",(kind,peer))
    db.execute("""INSERT INTO messages
        (peer_kind,peer_id,message_id,original_text,original_observed,
         first_seen_at,last_seen_at) VALUES(?,?,4,?,1,1,1)""",
        (kind,peer,"Оригинал "+str(kind)))
    db.execute("""INSERT INTO revisions
        (peer_kind,peer_id,message_id,version_index,content,observed_at)
        VALUES(?,?,4,0,?,1)""",(kind,peer,"Оригинал "+str(kind)))
db.commit()

def edit(con,kind,peer,mid,text,version):
    key=f"goldgram.edit.{kind}.{peer}.{mid}.{version}"
    con.execute(revision_sql,(kind,peer,mid,version,101+version,500+version,text))
    con.execute(event_sql,(kind,peer,mid,500+version,101+version,key))
    con.commit()
for kind in (2,3):
    edit(db,kind,98,4,"Правка "+str(kind),1)
assert [x[0] for x in db.execute(
    "SELECT content FROM revisions WHERE peer_kind=0 ORDER BY version_index")] == ["Оригинал 0"]
assert {kind:content for kind,content in db.execute(
    "SELECT peer_kind,content FROM revisions WHERE version_index=1")} == {2:"Правка 2",3:"Правка 3"}
assert db.execute("SELECT COUNT(*) FROM events").fetchone()[0] == 2
assert all(x[1].startswith("Оригинал") for x in db.execute(
    "SELECT peer_kind,original_text FROM messages"))
# Unknown pre-edit version must never be invented.
second.execute("INSERT INTO dialogs(peer_kind,peer_id) VALUES(3,98)")
second.execute("""INSERT INTO messages(peer_kind,peer_id,message_id,original_text,
    original_observed,first_seen_at,last_seen_at) VALUES(3,98,4,NULL,0,1,1)""")
edit(second,3,98,4,"Первая известная редакция",0)
assert second.execute("SELECT original_text FROM messages").fetchone()[0] is None
assert second.execute("SELECT COUNT(*) FROM revisions").fetchone()[0] == 1
print("Goldgram #77: peer-kind keyed public edits, immutable originals, unknown originals OK")
