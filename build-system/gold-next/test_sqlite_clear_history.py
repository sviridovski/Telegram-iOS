#!/usr/bin/env python3
"""Execute the shipped clear SQL, including cascades, rollback and account scope."""
from pathlib import Path
import re
import sqlite3

root = Path(__file__).parent
source = (root/'GoldgramHistoryStore.swift').read_text()
def block(name):
    m = re.search(r'private static let '+name+r' = """\n(.*?)\n    """', source, re.S)
    assert m, name
    return m.group(1)
def setup():
    db = sqlite3.connect(':memory:')
    db.execute('PRAGMA foreign_keys=ON')
    db.executescript(block('schemaV1'))
    db.executescript(block('schemaV2'))
    db.execute('PRAGMA user_version=2')
    for kind in range(4):
        db.execute('INSERT INTO dialogs(peer_kind,peer_id) VALUES(?,81)',(kind,))
        db.execute('INSERT INTO messages(peer_kind,peer_id,message_id,first_seen_at,last_seen_at,original_text) VALUES(?,81,9,1,2,?)',(kind,'original'))
        db.execute('INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,content,observed_at) VALUES(?,81,9,0,?,1)',(kind,'original'))
        db.execute('INSERT INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at) VALUES(?,81,9,1,?,?,2)',(kind,'test',str(kind)))
    db.execute("INSERT INTO unresolved_deletions VALUES('pending',9,2)")
    db.execute('INSERT INTO retention_settings VALUES(0,7)')
    db.commit()
    return db

a,b=setup(),setup()
# Execute statements inside the same explicit transaction as Swift, not
# executescript (which would implicitly commit and invalidate rollback testing).
def clear(db):
    for sql in block('clearHistorySQL').split(';'):
        if sql.strip(): db.execute(sql)
a.execute('BEGIN IMMEDIATE')
clear(a)
a.rollback()
assert a.execute('SELECT COUNT(*) FROM messages').fetchone()[0] == 4
a.execute('BEGIN IMMEDIATE')
clear(a)
a.commit()
for table in ('dialogs','messages','revisions','events','unresolved_deletions'):
    assert a.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0] == 0, table
assert b.execute('SELECT COUNT(*) FROM messages').fetchone()[0] == 4
assert a.execute('SELECT retention_days FROM retention_settings').fetchone()[0] == 7
assert a.execute('PRAGMA user_version').fetchone()[0] == 2
assert a.execute('PRAGMA foreign_key_check').fetchall() == []
# The same writer connection is still usable after clearing.
a.execute('INSERT INTO dialogs(peer_kind,peer_id) VALUES(3,81)')
a.execute('INSERT INTO messages(peer_kind,peer_id,message_id,first_seen_at,last_seen_at) VALUES(3,81,10,3,3)')
a.commit()
assert a.execute('SELECT message_id FROM messages').fetchall() == [(10,)]
print('Goldgram #79: clear transaction/cascades/rollback/isolation/retention and subsequent writes OK')
