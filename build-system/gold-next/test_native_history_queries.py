#!/usr/bin/env python3
"""#83: execute the actual shipped reader against regression event fixtures."""
from pathlib import Path
import re, sqlite3
r=Path(__file__).parent
s=(r/'GoldgramHistoryStore.swift').read_text()
def block(name):
 m=re.search(r'private static let '+name+r' = """\n(.*?)\n    """',s,re.S); assert m,name
 return m.group(1)
db=sqlite3.connect(':memory:');db.execute('PRAGMA foreign_keys=ON')
db.executescript(block('schemaV1'));db.executescript(block('schemaV2'))
def add(kind,peer,mid,source=None,event=1,original=None,latest='headline',server=None,deleted=0,time=100):
 db.execute('INSERT OR IGNORE INTO dialogs(peer_kind,peer_id) VALUES(?,?)',(kind,peer))
 db.execute('INSERT INTO messages(peer_kind,peer_id,message_id,first_seen_at,last_seen_at,original_text,original_observed,is_deleted) VALUES(?,?,?,1,2,?,?,?)',(kind,peer,mid,original,int(original is not None),deleted))
 db.execute('INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,content,observed_at) VALUES(?,?,?,0,?,2)',(kind,peer,mid,latest))
 if source:
  db.execute('INSERT INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,server_time,observed_at) VALUES(?,?,?,?,?,?,?,?)',(kind,peer,mid,event,source,f'{kind}:{peer}:{mid}',server,time))
add(3,10,1,'telegram_edit_update') # user's screenshot: unknown original + unproven notification
add(3,10,2,'telegram_edit_update',original='same',latest='same',server=10)
add(3,10,3,'telegram_edit_update',original='A',latest='B',server=10) # credible legacy difference
add(3,10,4,'goldgram_native_live_v2',latest='changed')
add(3,10,5,'goldgram_native_retained_v1',event=2,latest='[Фото]',deleted=1,time=500)
add(2,20,5,'goldgram_native_retained_v1',event=2,latest='comment',deleted=1,time=600)
add(0,30,5,'goldgram_native_retained_v1',event=2,latest='[Видео]',deleted=1,time=400)
add(1,40,5,'goldgram_native_v1',event=2,latest='unavailable',deleted=1,time=300)
add(3,10,6,None,latest='normal untouched post')
# #84 observation-only history backfill is no longer an accepted new edit.
add(3,10,7,'goldgram_native_v1',latest='old edited text',server=10)
add(3,10,8,'goldgram_native_v1',original='old A',latest='old B',server=10)

rows=db.execute(block('messagesSQL'),(3,10,30,0)).fetchall()
assert {x[2] for x in rows}=={3,4,5}, 'reject legacy false/unchanged, retain proven events'
photo=next(x for x in rows if x[2]==5)
assert photo[16:18]==(500,1), 'deletion receipt time + native retained anchor'
# Reproduce production composition for deleted category (4 bound kinds).
q=block('dialogsSQL').replace('WHERE d.peer_kind IN (?, ?)','WHERE d.peer_kind IN (?, ?, ?, ?)')
predicate='AND (m.is_deleted=1 OR EXISTS (SELECT 1 FROM events de WHERE de.peer_kind=m.peer_kind AND de.peer_id=m.peer_id AND de.message_id=m.message_id AND de.event_kind=2)) '
q=q.replace('GROUP BY d.peer_kind',predicate+'GROUP BY d.peer_kind')
assert {x[0] for x in db.execute(q,(0,1,2,3,30,0))}=={0,1,2,3}
q=block('messagesSQL').replace('WHERE m.peer_kind = ? AND m.peer_id = ?\n','WHERE ((m.peer_kind = ? AND m.peer_id = ?) OR (m.peer_kind = ? AND m.peer_id = ?))\n')
q=q.replace('ORDER BY COALESCE(m.sent_at, m.last_seen_at) DESC',predicate+'ORDER BY COALESCE((SELECT MIN(de.observed_at) FROM events de WHERE de.peer_kind=m.peer_kind AND de.peer_id=m.peer_id AND de.message_id=m.message_id AND de.event_kind=2),m.last_seen_at) DESC')
rows=db.execute(q,(3,10,2,20,30,0)).fetchall()
assert [(x[0],x[1],x[2]) for x in rows]==[(2,20,5),(3,10,5)]
assert [x[16] for x in rows]==[600,500], 'deletions ordered by receipt, not message sent date'
assert len(db.execute(q,(3,10,2,20,1,1)).fetchall())==1
# A #88 ID-only receipt may already be the last stored revision. Recover the
# earlier real text on read without erasing any stored revision/event.
db.execute('INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,content,observed_at) VALUES(2,20,5,1,?,700)',('[Содержимое не было получено]',))
recovered=db.execute(block('messagesSQL'),(2,20,30,0)).fetchall()
assert recovered[0][10]=='comment', 'old receipt placeholders must not hide actually saved content'
# Cascade clear also removes delete events/revisions; no mixed-peer IDs.
db.execute('DELETE FROM dialogs WHERE peer_kind=3')
assert db.execute('SELECT COUNT(*) FROM events WHERE peer_kind=2').fetchone()[0]==1
assert db.execute('PRAGMA foreign_key_check').fetchall()==[]
print('Goldgram #83: false-edit regression, deleted/media anchors, event clock, all peer kinds and scoped paging OK')
