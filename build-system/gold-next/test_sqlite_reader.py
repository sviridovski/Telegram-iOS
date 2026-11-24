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
assert 'GoldgramHistoryStore.enqueueArchiveWork' in src
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
            VALUES (?,?,7,1,'goldgram_native_live_v2',?,200)""", (kind, peer, f"test-{kind}-{peer}"))
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
# #139: a catch-up record without a verified original must be hidden by
# #138's archive filter, but the underlying SQLite evidence stays untouched.
a.execute("UPDATE messages SET original_observed=0 WHERE peer_kind=0")
assert messages(a,0,10) == []
assert dialogs(a,(0,0)) == []
assert a.execute("""SELECT original_text, original_observed FROM messages
    WHERE peer_kind=0 AND peer_id=10 AND message_id=7""").fetchone() == ("Начало", 0)
# If a genuine baseline is later confirmed, it becomes visible without
# recreating the archive or changing another account's history.
a.execute("UPDATE messages SET original_observed=1 WHERE peer_kind=0")
assert messages(a,0,10)[0][4] == 1
assert dialogs(a,(0,0))[0][2] == 1
assert messages(b,0,10)[0][3] == "Другой аккаунт"
print("Goldgram #139 reader: scoped, paginated, verified originals only, durable hidden records OK")


# #254: exercise the actual local-search SQL template extracted from Swift.
# Python's Unicode normalization stands in for the Foundation scalar here;
# the production callback is separately compiled by the existing Swift CI.
import unicodedata

def fold(s):
    return "".join(c for c in unicodedata.normalize("NFD", s.casefold())
                   if not unicodedata.combining(c))

def contains(body, needle):
    return int(body is not None and needle is not None and fold(needle) in fold(body))

local = src.split("private static func readLocalSearch(", 1)[1].split("private static func read(", 1)[0]
template = re.search(r'let sql = """\n(.*?)\n        """', local, re.S).group(1)
original_match = re.search(r'let originalMatch = "(.*?)"', local).group(1)
revision_match = re.search(r'let revisionMatch = """\n(.*?)\n        """', local, re.S).group(1)
edit_pred = sql("fastEditPredicate")
delete_pred = sql("fastDeleteEventPredicate")
visible_code = src.split("private static var fastVisiblePredicate:", 1)[1].split("private static var fastSelectColumns:", 1)[0]
has_body = re.search(r'let hasBody = """\n(.*?)\n        """', visible_code, re.S).group(1)
reliable = re.search(r'let reliable = """\n(.*?)\n        """', visible_code, re.S).group(1)
reliable = reliable.replace(r"\(fastDeleteEventPredicate)", delete_pred)
visible = f"({has_body} AND {reliable} AND (m.is_deleted=1 OR {delete_pred} OR {edit_pred}))"
projection = message_sql.split("FROM messages m\n", 1)[0]
newest = "COALESCE((SELECT MAX(e.observed_at) FROM events e WHERE e.peer_kind=m.peer_kind AND e.peer_id=m.peer_id AND e.message_id=m.message_id), m.last_seen_at)"
deleted = f"(m.is_deleted=1 OR {delete_pred})"

def search(db, needle="", scope=(), event=0, since=0, author=None, limit=30, offset=0, fast=False):
    db.create_function("goldgram_contains_v1", 2, contains, deterministic=True)
    source = ("goldgram_ui_fast_rows_v1 f JOIN messages m ON m.peer_kind=f.peer_kind AND m.peer_id=f.peer_id AND m.message_id=f.message_id"
              if fast else "messages m")
    where = ["f.visible=1" if fast else visible, "m.peer_kind IN (0,1,2,3)",
             f"(terms.needle='' OR {original_match} OR EXISTS (SELECT 1 FROM revisions sr WHERE {revision_match}))"]
    params = [needle]
    if scope:
        where.append("(" + " OR ".join("(m.peer_kind=? AND m.peer_id=?)" for _ in scope) + ")")
        params += [v for pair in scope for v in pair]
    if event == 1:
        where.append("f.edited=1" if fast else edit_pred)
    if event == 2:
        where.append("f.deleted=1" if fast else deleted)
    date = "f.newest_at" if fast else newest
    if since:
        where.append(date + ">=?")
        params.append(since)
    if author:
        where.append("m.sender_kind=? AND m.sender_id=?")
        params += list(author)
    query = template
    for key, value in {
        r"\(projection[0])": projection, r"\(originalMatch)": original_match,
        r"\(revisionMatch)": revision_match, r"\(source)": source,
        r'\(predicates.joined(separator: " AND "))': " AND ".join(where), r"\(newest)": date
    }.items():
        assert key in query, key
        query = query.replace(key, value)
    assert r"\(" not in query, query
    return db.execute(query, (*params, limit + 1, offset)).fetchall()

# Real fixtures: original, intermediate-only match, latest text, deletion,
# another peer kind with same raw author ID, hidden unverified edit and account.
a.execute("UPDATE messages SET sender_kind=0,sender_id=42 WHERE peer_kind=0")
a.execute("UPDATE messages SET sender_kind=3,sender_id=42 WHERE peer_kind=3")
a.execute("UPDATE messages SET original_observed=0 WHERE peer_kind=1")
a.execute("UPDATE messages SET is_deleted=1 WHERE peer_kind=2")
a.execute("""INSERT INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at)
             VALUES (2,20,7,2,'goldgram_native_live_v2','test-delete-254',500)""")
a.execute("""INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,content,observed_at)
             VALUES (0,10,7,2,'Ещё 100%_ готово',300),(0,10,7,3,'Финал',400)""")
a.execute("""INSERT INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at)
             VALUES (0,10,7,1,'goldgram_native_live_v2','test-edit-254',400)""")
a.execute("""CREATE TABLE goldgram_ui_fast_rows_v1(
             peer_kind INTEGER,peer_id INTEGER,message_id INTEGER,
             visible INTEGER,edited INTEGER,deleted INTEGER,newest_at INTEGER)""")
a.execute(f"""INSERT INTO goldgram_ui_fast_rows_v1
              SELECT m.peer_kind,m.peer_id,m.message_id,
              CASE WHEN {visible} THEN 1 ELSE 0 END,
              CASE WHEN {edit_pred} THEN 1 ELSE 0 END,
              CASE WHEN {deleted} THEN 1 ELSE 0 END,{newest} FROM messages m""")
a.execute("PRAGMA query_only=ON")
before = a.total_changes

def ids(rows):
    return [tuple(row[:3]) for row in rows]

for fast in (False, True):
    matches = search(a, "ЕЩЕ 100%_", fast=fast)
    assert ids(matches) == [(0,10,7)] and matches[0][18] == "Ещё 100%_ готово"
    assert matches[0][10] == "Финал", "intermediate match must not replace latest text"
    assert search(a, "100%X", fast=fast) == [], "literal wildcard characters"
    assert ids(search(a, "начало", author=(0,42), fast=fast)) == [(0,10,7)]
    assert ids(search(a, "начало", author=(3,42), fast=fast)) == [(3,20,7)]
    assert ids(search(a, event=2, fast=fast)) == [(2,20,7)]
    assert ids(search(a, event=1, since=400, fast=fast)) == [(2,20,7),(0,10,7)]
    assert ids(search(a, scope=((3,20),), fast=fast)) == [(3,20,7)]
    assert ids(search(a, scope=((0,10),(3,20)), fast=fast)) == [(0,10,7),(3,20,7)]
    assert (1,20,7) not in ids(search(a, fast=fast)), "hidden unverified edit"
    assert ids(search(a, fast=fast, limit=1)) == [(2,20,7),(0,10,7)]
    assert ids(search(a, fast=fast, limit=1, offset=1)) == [(0,10,7),(3,20,7)]
assert search(b, "ЕЩЕ 100%_") == [], "account A content cannot appear in B"
assert a.total_changes == before, "search must not mutate archive"
print("Goldgram #254 search: fast/fallback SQL, Unicode literal, intermediate match, filters, paging and account isolation OK")
