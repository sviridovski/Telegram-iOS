#!/usr/bin/env python3
"""Goldgram Bridge Live v1 — authenticated, certificate-pinned HTTPS pull source.

Runs alongside (NOT inside) the existing Telethon collector on jailbroken iPhone 8.
Reads its current SQLite in read-only mode. Does not read the MTProto .session or
Telegram api_hash, and never changes the collector's DB or daemon.
No raw message content is printed to stdout or the HTTP access log.

iOS receiver records cursors only after successfully committing the batch to its
existing Swiftgram account SQLite; a failed request safely retries the same rows.
"""
import argparse
import hashlib
import hmac
import http.server
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import ssl
import subprocess
import sys
from urllib.parse import parse_qs, urlparse

ROOT = Path("/var/mobile/Library/GoldgramCollector")
PORT = 8873
# Fixed so a batch always fits the max-50 record importer.
PER_KIND = 20
FIELDS = {
    "messages": {"account_id", "chat_id", "message_id", "original_text",
                 "first_seen_at", "first_seen_kind", "peer_kind"},
    "edits": {"account_id", "chat_id", "message_id", "observed_at",
              "server_edit_at", "text"},
    "deletions": {"account_id", "chat_id", "message_id", "observed_at", "resolution"},
}


def validate_schema(conn):
    for table, required in FIELDS.items():
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(" + table + ")")}
        missing = required - columns
        if missing:
            raise ValueError(f"Database table {table} missing fields: {sorted(missing)}")


def open_source(path):
    # Immutable flag is NOT used: SQLite WAL must remain visible.
    conn = sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True,
                           timeout=5, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    try:
        validate_schema(conn)
        conn.execute("PRAGMA query_only=ON")
        return conn
    except Exception:
        conn.close()
        raise


def find_db(folder):
    files = []
    for pattern in ("*.sqlite", "*.sqlite3", "*.db"):
        files.extend(folder.glob(pattern))
    matches = []
    for p in files:
        try:
            conn = open_source(p)
            conn.close()
            matches.append(p)
        except (sqlite3.Error, ValueError, OSError):
            continue
    if len(matches) != 1:
        raise ValueError("Expected one collector DB, found "
                         + str([str(x) for x in matches])
                         + "; pass --db /exact/path")
    return matches[0]


def ensure_pairing(folder):
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    secret = folder / "live_bridge_secret.txt"
    if not secret.exists():
        fd = os.open(secret, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as f:
            f.write(secrets.token_hex(32))
    os.chmod(secret, 0o600)
    token = secret.read_text(encoding="ascii").strip()
    if len(token) != 64 or any(c not in "0123456789abcdef" for c in token):
        raise ValueError("Pairing token must be 64 lowercase hex characters")

    cert = folder / "live_bridge_cert.pem"
    key = folder / "live_bridge_key.pem"
    if not cert.exists() or not key.exists():
        if cert.exists() or key.exists():
            raise ValueError("Incomplete TLS certificate pair: do not replace either key")
        subprocess.run(["openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048",
                        "-sha256", "-days", "365", "-subj", "/CN=goldgram-iphone8",
                        "-keyout", str(key), "-out", str(cert)],
                       check=True, capture_output=True)
        os.chmod(key, 0o600)
        os.chmod(cert, 0o600)
    der = ssl.PEM_cert_to_DER_cert(cert.read_text(encoding="ascii"))
    fingerprint = hashlib.sha256(der).hexdigest()
    return token, cert, key, fingerprint


def iso(value):
    if value is None:
        return None
    # Strings already came from the active collector, not from user inputs.
    if isinstance(value, str):
        return value
    return str(value)


def pair_from_record(r, kind):
    # Telethon stores PeerChannel as -100...; user IDs as positive numbers.
    chat = str(r["chat_id"]) if r["chat_id"] is not None else ""
    peer = str(r["peer_kind"] or "")
    if peer not in ("PeerUser", "PeerChannel"):
        return None
    if peer == "PeerUser" and not chat.isdigit():
        return None
    if peer == "PeerChannel" and not (chat.startswith("-100") and chat[4:].isdigit()):
        return None
    return peer, chat


def batch_from_db(conn, account, after_edits, after_deletions, limit_per_kind=PER_KIND):
    # SQLite consistent read snapshot, without blocking the live collector.
    conn.execute("BEGIN")
    try:
        edits = conn.execute("""
          SELECT e.rowid AS cursor, e.account_id, e.chat_id, e.message_id,
                 e.observed_at, e.server_edit_at, e.text,
                 m.peer_kind, m.first_seen_at, m.first_seen_kind,
                 m.original_text
          FROM edits e LEFT JOIN messages m
            ON m.account_id=e.account_id AND m.chat_id=e.chat_id
           AND m.message_id=e.message_id
          WHERE e.rowid > ? AND e.account_id = ?
          ORDER BY e.rowid LIMIT ?
        """, (after_edits, account, limit_per_kind)).fetchall()
        deletes = conn.execute("""
          SELECT d.rowid AS cursor, d.account_id, d.chat_id, d.message_id,
                 d.observed_at, d.resolution,
                 m.peer_kind, m.first_seen_at, m.first_seen_kind,
                 m.original_text
          FROM deletions d LEFT JOIN messages m
            ON m.account_id=d.account_id AND m.chat_id=d.chat_id
           AND m.message_id=d.message_id
          WHERE d.rowid > ? AND d.account_id = ?
          ORDER BY d.rowid LIMIT ?
        """, (after_deletions, account, limit_per_kind)).fetchall()
    finally:
        conn.execute("ROLLBACK")
    records = []
    skipped_edits = 0
    skipped_deletions = 0
    for r in edits:
        if r["first_seen_kind"] != "new_unedited" or not r["original_text"]:
            skipped_edits += 1
            continue
        pair = pair_from_record(r, "edit")
        if not pair:
            skipped_edits += 1
            continue
        if r["text"] is None or r["text"] == r["original_text"]:
            # Initial event with same body is not proof of an edit.
            skipped_edits += 1
            continue
        if not r["server_edit_at"] or not r["observed_at"] or not r["first_seen_at"]:
            skipped_edits += 1
            continue
        records.append({
            "record_kind": "edit", "source": "iphone8_telethon",
            "account_id": str(r["account_id"]),
            "peer_kind": pair[0], "chat_id": pair[1],
            "message_id": str(r["message_id"]),
            "first_seen_at": iso(r["first_seen_at"]),
            "original_text": r["original_text"],
            "latest_text": r["text"],
            "server_edit_at": iso(r["server_edit_at"]),
            "event_observed_at": iso(r["observed_at"]),
            "edit_event_id": "edit:" + str(r["cursor"]),
        })
    for r in deletes:
        pair = pair_from_record(r, "delete")
        if not pair or r["resolution"] != "telegram_chat" or not r["observed_at"]:
            skipped_deletions += 1
            continue
        records.append({
            "record_kind": "delete", "source": "iphone8_telethon",
            "account_id": str(r["account_id"]),
            "peer_kind": pair[0], "chat_id": pair[1],
            "message_id": str(r["message_id"]),
            "event_observed_at": iso(r["observed_at"]),
            "edit_event_id": "delete:" + str(r["cursor"]),
            "original_text": r["original_text"] if
                r["first_seen_kind"] == "new_unedited" else None,
            "first_seen_at": iso(r["first_seen_at"]),
        })
    return {
        "format": "goldgram_bridge_v2",
        "records": records,
        "next_edit_cursor": int(edits[-1]["cursor"]) if edits else after_edits,
        "next_delete_cursor": int(deletes[-1]["cursor"]) if deletes else after_deletions,
        "skipped_edits": skipped_edits,
        "skipped_deletions": skipped_deletions,
    }


def local_client(address):
    try:
        ip = ipaddress.ip_address(address)
        return ip.is_private and not ip.is_loopback and not ip.is_link_local
    except ValueError:
        return False


def make_handler(db_path, token, account):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "GoldgramLive/1"
        sys_version = ""

        def log_message(self, fmt, *args):
            # Deliberately do not log URL parameters, pairing token, or chat data.
            pass

        def do_GET(self):
            if not local_client(self.client_address[0]):
                return self.fail(403)
            header = self.headers.get("X-Goldgram-Token", "")
            if not hmac.compare_digest(header, token):
                return self.fail(401)
            url = urlparse(self.path)
            if url.path != "/v1/events":
                return self.fail(404)
            args = parse_qs(url.query)
            try:
                keys = ("edits_after", "deletions_after")
                if set(args) != set(keys):
                    return self.fail(400)
                ec, dc = (int(args[k][0]) for k in keys)
                if ec < 0 or dc < 0 or ec > 2**63 - 1 or dc > 2**63 - 1:
                    return self.fail(400)
                size = PER_KIND
                while True:
                    with open_source(db_path) as conn:
                        data = batch_from_db(conn, account, ec, dc, size)
                    response = json.dumps(data, ensure_ascii=False,
                                          separators=(",", ":")).encode("utf-8")
                    if len(response) <= 950_000:
                        break
                    if size <= 1:
                        return self.fail(413)
                    size = max(1, size // 2)
            except (ValueError, sqlite3.Error, TypeError):
                return self.fail(503)
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(response)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(response)

        def fail(self, code):
            self.send_response(code)
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=None)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not (1 <= args.port <= 65535):
        parser.error("Invalid port")
    db = args.db or find_db(ROOT)
    with open_source(db) as con:
        accounts = [r[0] for r in con.execute(
            "SELECT DISTINCT account_id FROM messages LIMIT 2")]
    if len(accounts) != 1 or not isinstance(accounts[0], int) or accounts[0] <= 0:
        parser.error("Expected one Telegram account in collector SQLite")
    token, cert, key, fingerprint = ensure_pairing(ROOT / "live_bridge")
    print("GOLDGRAM LIVE SOURCE READY", flush=True)
    print("DB:", db, flush=True)
    print("ACCOUNT:", accounts[0], flush=True)
    print("TLS SHA256:", fingerprint, flush=True)
    print("PAIRING TOKEN FILE:", ROOT / "live_bridge/live_bridge_secret.txt", flush=True)
    print("PORT:", args.port, flush=True)
    if args.dry_run:
        return
    class ReuseServer(http.server.ThreadingHTTPServer):
        allow_reuse_address = True
        daemon_threads = True

    server = ReuseServer((args.bind, args.port),
                         make_handler(db, token, accounts[0]))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(str(cert), str(key))
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
