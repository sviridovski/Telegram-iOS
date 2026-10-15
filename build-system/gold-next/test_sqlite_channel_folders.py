#!/usr/bin/env python3
"""#80: run shipped SQL for a merged channel + linked-discussion history."""
from pathlib import Path
import re
import sqlite3
root=Path(__file__).parent
src=(root/'GoldgramHistoryStore.swift').read_text()
def sql(name):
    match=re.search(r'private static let '+name+r' = """\n(.*?)\n    """',src,re.S)
    assert match,name
    return match.group(1)
def setup():
    db=sqlite3.connect(':memory:')
    db.executescript(sql('schemaV1')); db.executescript(sql('schemaV2'))
    return db

def add(db,kind,peer,mid,sent,edit=True,deleted=False):
    db.execute('INSERT OR IGNORE INTO dialogs(peer_kind,peer_id) VALUES(?,?)',(kind,peer))
    db.execute('''INSERT INTO messages(peer_kind,peer_id,message_id,original_text,original_observed,
        first_seen_at,last_seen_at,sender_kind,sender_id,sent_at,is_deleted)
        VALUES(?,?,?,'Original',1,1,9999999,0,4321,?,?)''',(kind,peer,mid,sent,int(deleted)))
    if edit or deleted:
        db.execute('''INSERT INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at)
            VALUES(?,?,?,?,'test',?,2)''',(kind,peer,mid,2 if deleted else 1,f'{kind}-{peer}-{mid}'))

a,b=setup(),setup()
# Identical message IDs in channel and discussion must survive separately;
# another account, another channel, another group must never enter the folder.
for db in (a,b):
    add(db,3,100,7,2000)
    add(db,2,200,7,3000)
    add(db,2,200,8,4000,edit=False) # ordinary neighbor remains hidden
    add(db,2,200,9,1000,edit=False,deleted=True)
    add(db,3,999,7,8000)
    add(db,2,888,7,9000)
    add(db,0,100,7,9999)
combined=sql('messagesSQL').replace('WHERE m.peer_kind = ? AND m.peer_id = ?\n',
    'WHERE ((m.peer_kind = ? AND m.peer_id = ?) OR (m.peer_kind = ? AND m.peer_id = ?))\n')
rows=a.execute(combined,(3,100,2,200,30,0)).fetchall()
assert [(r[0],r[1],r[2]) for r in rows]==[(2,200,7),(3,100,7),(2,200,9)]
assert [r[7] for r in rows]==[3000,2000,1000], 'sent time, not last observed time'
assert all(r[6]==4321 and r[13]==0 for r in rows), 'saved sender identity and kind'
assert [r[14] for r in rows]==[1,1,0], 'actual edit evidence'
assert [r[15] for r in rows]==[0,0,1], 'actual deletion evidence'
assert a.execute(combined,(3,100,2,200,1,0)).fetchall()==rows[:1]
assert a.execute(combined,(3,100,2,200,1,1)).fetchall()==rows[1:2]
# Reading account A doesn't change or include B; message text stays in SQLite.
b.execute("UPDATE messages SET original_text='Other account'")
assert a.execute(combined,(3,100,2,200,30,0)).fetchall()[0][3]=='Original'
assert b.execute(combined,(3,100,2,200,30,0)).fetchall()[0][3]=='Other account'
print('Goldgram #80: combined channel/comment SQL scopes, event filter, author/time, pagination OK')
