#!/usr/bin/env python3
"""Run the shipped native writer's SQL, including numbered parameter binds."""
from pathlib import Path
import re, sqlite3
r=Path(__file__).parent
source=(r/'GoldgramHistoryStore.swift').read_text()
def block(name):
 m=re.search(r'private static let '+name+r' = """\n(.*?)\n    """',source,re.S);assert m
 return m.group(1)
writer=source.split('static func nativeEvent(',1)[1]
statements=re.findall(r'archiveSQL\("(.*?)", db: db, ints:',writer)
def sql(prefix):
 found=[q for q in statements if q.startswith(prefix)]
 assert len(found)==1,(prefix,found)
 return found[0]
db=sqlite3.connect(':memory:');db.execute('PRAGMA foreign_keys=ON')
db.executescript(block('schemaV1'));db.executescript(block('schemaV2'))
# Use identical message IDs in multiple dialog namespaces.
for kind,peer in ((0,10),(1,20),(2,30),(3,40)):
 scope=[kind,peer,7]
 db.execute('BEGIN IMMEDIATE')
 db.execute(sql('INSERT OR IGNORE INTO dialogs'),scope[:2])
 db.execute(sql('INSERT OR IGNORE INTO messages'),scope+[100,100,0,None])
 db.execute(sql('UPDATE messages SET original_observed'),scope+['Original'])
 db.execute(sql('UPDATE messages SET sender_kind'),scope+[0,99,12345,0,200,0])
 db.execute(sql('INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,observed_at,revision_provenance'),scope+[100,1,'Original'])
 db.execute(sql('INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,observed_at,server_edit_at'),scope+[1,200,201,'Changed'])
 event=sql('INSERT OR IGNORE INTO events').replace(r'\(source)','goldgram_native_live_v2')
 db.execute(event,scope+[1,201,200,f'edit:{kind}:{peer}'])
 db.commit()
 message=db.execute('SELECT original_text,original_observed,sender_id,sent_at,is_deleted FROM messages WHERE peer_kind=? AND peer_id=?',scope[:2]).fetchone()
 assert message==('Original',1,99,12345,0),message
 # Deleting retains previous original, latest revision and the first receipt time.
 db.execute('BEGIN IMMEDIATE')
 db.execute(sql('UPDATE messages SET sender_kind'),scope+[-1,0,0,0,500,1])
 delete=sql('INSERT OR IGNORE INTO events').replace(r'\(source)','goldgram_native_retained_v1')
 db.execute(delete,scope+[2,0,500,f'delete:{kind}:{peer}'])
 db.execute(delete,scope+[2,0,900,f'delete:{kind}:{peer}'])
 db.commit()
 assert db.execute('SELECT observed_at FROM events WHERE event_key=?',(f'delete:{kind}:{peer}',)).fetchone()[0]==500
 assert db.execute('SELECT original_text,is_deleted FROM messages WHERE peer_kind=? AND peer_id=?',scope[:2]).fetchone()==('Original',1)
# Unknown global deletions remain unresolved rather than choosing a channel.
db.execute(sql('INSERT OR IGNORE INTO unresolved_deletions'),(42,1000,'native.global'))
assert db.execute('SELECT message_id FROM unresolved_deletions').fetchall()==[(42,)]
assert db.execute('SELECT COUNT(*) FROM messages').fetchone()[0]==4
assert db.execute('PRAGMA foreign_key_check').fetchall()==[]
print('Goldgram #83: actual native writer SQL, immutable originals, media tombstones, dedup clocks and scope OK')


# #131: actual additive audit DDL + production INSERT + diagnostic SQL.
# No new DB, no plaintext duplicated, original+evidence commit atomically.
import uuid
evidence_ddl = block("schemaOriginalEvidence")
db.executescript(evidence_ddl)
audit_func = source.split("static func recordFirstOriginalEvidence(",1)[1].split(
    "// Returns the latest version",1)[0]
audit_sql = re.search(r'let sql = """\n(.*?)\n        """', audit_func, re.S)
assert audit_sql, "must test production audit INSERT"
audit_sql = audit_sql.group(1)
diagnostic = source.split('if mode == "diagnostics" {',1)[1].split(
    'var sql = mode == "totals"',1)[0]
count_sql = re.search(r'let evidenceSQL = """\n(.*?)\n            """', diagnostic, re.S)
assert count_sql, "must test production evidence counters"
count_sql = count_sql.group(1)

# Simulate capture before a later edit, and a baseline first supplied with
# the same edit event, using SQL actually shipped in the Swift source.
db.execute('INSERT INTO dialogs(peer_kind,peer_id) VALUES(2,111)')
for mid in (100,101):
    db.execute('INSERT INTO messages(peer_kind,peer_id,message_id,first_seen_at,last_seen_at,original_observed,original_text) VALUES(2,111,?,100,100,1,?)',
               (mid, 'original text owned by existing messages table'))
token = str(uuid.uuid4())
db.execute(audit_sql, (2,111,100,100,'geo_sensor',token,0,2,111,100))
db.execute('INSERT INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at) VALUES(2,111,100,1,?,?,200)',
           ('telegram_edit_update','edit_100'))
db.execute('INSERT INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at) VALUES(2,111,101,1,?,?,150)',
           ('telegram_edit_update','edit_101'))
db.execute(audit_sql, (2,111,101,175,'edit_with_before',None,1,2,111,101))
# Duplicated API history must never rewrite the first source/time/attempt.
db.execute(audit_sql, (2,111,100,300,'history_snapshot',None,0,2,111,100))
assert db.execute('SELECT source,captured_at,edit_already_observed,attempt_token FROM original_capture_evidence WHERE message_id=100').fetchone() == ('geo_sensor',100,0,token)
assert db.execute('SELECT source,captured_at,edit_already_observed FROM original_capture_evidence WHERE message_id=101').fetchone() == ('edit_with_before',175,1)
assert db.execute(count_sql, (90,300)).fetchone() == (2,1,0,0,0,0,1,1,1)
cols={x[1] for x in db.execute('PRAGMA table_info(original_capture_evidence)')}
assert 'original_text' not in cols and 'attempt_token' in cols
# Pre-#131 known originals do NOT receive retrospective provenance.
assert db.execute('SELECT COUNT(*) FROM original_capture_evidence').fetchone()[0] == 2
db.execute('DELETE FROM messages WHERE peer_kind=2 AND peer_id=111 AND message_id=100')
assert db.execute('SELECT COUNT(*) FROM original_capture_evidence WHERE message_id=100').fetchone()[0] == 0
assert db.execute('PRAGMA foreign_key_check').fetchall() == []
native=source.split('static func nativeEvent(',1)[1].split('@_cdecl("goldgram_capture_event_v1")',1)[0]
assert 'let alreadyKnown = try originalIsKnown(db: db, scope: scope)' in native
assert 'if !alreadyKnown {' in native and 'try recordFirstOriginalEvidence(db: db' in native
assert native.index('try recordFirstOriginalEvidence(db: db') < native.index('try archiveSQL("COMMIT;"')
assert '"edit_with_before"' in native
assert 'CREATE TABLE IF NOT EXISTS original_capture_evidence' in source
assert 'try execute(schemaOriginalEvidence, on: db)' in source
assert 'currentSchemaVersion: Int32 = 2' in source
print("Goldgram #131: provenance audit SQL, first-write idempotence, late edit classification, same-transaction guard OK")
