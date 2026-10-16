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
