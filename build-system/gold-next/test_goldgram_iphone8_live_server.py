#!/usr/bin/env python3
"""No-network regression tests of Goldgram Live source/identity/watermark."""
import importlib.util
from pathlib import Path
import sqlite3
import tempfile

base = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "live", base / "goldgram_iphone8_live_server.py")
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)

with tempfile.TemporaryDirectory() as d:
    path = Path(d) / "collector.sqlite"
    con = sqlite3.connect(path)
    con.executescript("""
    CREATE TABLE messages (
      account_id INTEGER, chat_id INTEGER, message_id INTEGER,
      original_text TEXT, first_seen_at TEXT, first_seen_kind TEXT,
      peer_kind TEXT, sender_id INTEGER
    );
    CREATE TABLE edits (
      account_id INTEGER, chat_id INTEGER, message_id INTEGER,
      observed_at TEXT, server_edit_at TEXT, text TEXT
    );
    CREATE TABLE deletions (
      account_id INTEGER, chat_id INTEGER, message_id INTEGER,
      observed_at TEXT, resolution TEXT
    );
    """)
    t0 = "2026-11-11T17:00:00+00:00"
    t1 = "2026-11-11T17:10:00+00:00"
    con.execute("INSERT INTO messages VALUES(1,111,3,'Оригинал',?, 'new_unedited','PeerUser',12345)", (t0,))
    con.execute("INSERT INTO messages VALUES(1,-10044444,6,'Первые слова',?, 'new_unedited','PeerChannel',54321)", (t0,))
    con.execute("INSERT INTO messages VALUES(1,222,7,'Не доказано',?, 'edit_first','PeerUser',NULL)", (t0,))
    con.execute("INSERT INTO messages VALUES(2,333,8,'Чужой аккаунт',?, 'new_unedited','PeerUser',-10098765)", (t0,))
    con.execute("INSERT INTO edits VALUES(1,111,3,?,?,?)", (t1,t1,"Изменено"))
    con.execute("INSERT INTO edits VALUES(1,-10044444,6,?,?,?)", (t1,t1,"Новый текст"))
    con.execute("INSERT INTO edits VALUES(1,222,7,?,?,?)", (t1,t1,"Не доказано"))
    con.execute("INSERT INTO edits VALUES(2,333,8,?,?,?)", (t1,t1,"Чужой текст"))
    con.execute("INSERT INTO deletions VALUES(1,111,3,?,'telegram_chat')", (t1,))
    con.execute("INSERT INTO deletions VALUES(1,NULL,3,?,'unresolved')", (t1,))
    con.execute("INSERT INTO deletions VALUES(2,333,8,?,'telegram_chat')", (t1,))
    con.commit()
    con.close()

    with live.open_source(path) as db:
        packet = live.batch_from_db(db, 1, 0, 0)
    assert packet["format"] == "goldgram_bridge_v2"
    assert len(packet["records"]) == 3, packet
    assert packet["next_edit_cursor"] == 3, packet
    assert packet["next_delete_cursor"] == 2, packet
    assert packet["skipped_edits"] == 1
    assert packet["skipped_deletions"] == 1
    assert {r["record_kind"] for r in packet["records"]} == {"edit", "delete"}
    assert {r["account_id"] for r in packet["records"]} == {"1"}
    assert any(r["peer_kind"] == "PeerChannel" and r["chat_id"] == "-10044444"
               for r in packet["records"])
    assert any(r["edit_event_id"] == "delete:1" for r in packet["records"])
    assert all(r["source"] == "iphone8_telethon" for r in packet["records"])
    assert not any("api_hash" in r or "session" in r for r in packet["records"])
    assert {r["sender_id"] for r in packet["records"] if "sender_id" in r} == {"12345", "54321"}
    assert next(r for r in packet["records"] if r["record_kind"] == "delete")["sender_id"] == "12345"
    # This addition must not fabricate a sender type, send date, or thread.
    assert not any("sender_kind" in r or "sent_at" in r or "thread_id" in r
                   for r in packet["records"])

    with live.open_source(path) as db:
        again = live.batch_from_db(db, 1, packet["next_edit_cursor"],
                                   packet["next_delete_cursor"])
        only_first = live.batch_from_db(db, 1, 0, 0, 1)
    assert again["records"] == [] and again["next_edit_cursor"] == 3
    assert len(only_first["records"]) == 2  # first edit + first deletion
    assert only_first["next_edit_cursor"] == 1
    assert only_first["next_delete_cursor"] == 1

    with live.open_source(path) as db:
        other = live.batch_from_db(db, 2, 0, 0)
    assert len(other["records"]) == 2
    assert {r["account_id"] for r in other["records"]} == {"2"}
    assert all("sender_id" not in r for r in other["records"]), "do not mislabel channel senders as user authors"

    # Source archives created before sender_id was added still export as before.
    legacy = Path(d) / "legacy.sqlite"
    import shutil
    shutil.copyfile(path, legacy)
    with sqlite3.connect(legacy) as c:
        c.executescript("""
        CREATE TABLE original_msgs AS SELECT account_id,chat_id,message_id,
          original_text,first_seen_at,first_seen_kind,peer_kind FROM messages;
        DROP TABLE messages;
        ALTER TABLE original_msgs RENAME TO messages;
        """)
    with live.open_source(legacy) as db:
        old_packet = live.batch_from_db(db, 1, 0, 0)
    assert len(old_packet["records"]) == 3
    assert all("sender_id" not in r for r in old_packet["records"])

    for ip in ("192.168.1.20", "172.16.20.10", "10.11.12.13"):
        assert live.local_client(ip)
    for ip in ("127.0.0.1", "169.254.1.1", "8.8.8.8", "bad.host"):
        assert not live.local_client(ip)
print("Goldgram Live server: schema, read-only pagination, source isolation, edits/deletions OK")
