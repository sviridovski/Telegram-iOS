// Goldgram SQLite foundation (#64).
// Deliberately inert: no message capture, database creation, or account lookup
// occurs until a future, independently tested atom calls prepare(accountId:).
// Never infer an account ID from a message ID or a chat peer ID.
import Foundation
import SQLite3

enum GoldgramHistoryStore {
    enum StorageError: Error {
        case invalidAccount
        case incompatibleSchema(Int32)
        case sqlite(Int32)
    }

    // All database initialization is serialized off the main/render thread.
    // Later write APIs must use the same serialization discipline.
    static let storageQueue = DispatchQueue(
        label: "goldgram.history.sqlite.setup",
        qos: .utility
    )
    private static let currentSchemaVersion: Int32 = 2

    // Account-specific DB, with peer type + peer ID + message ID scoping inside.
    // Completion intentionally runs on main; the SQLite work never does.
    static func prepare(
        accountId: Int64,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        storageQueue.async {
            let result: Result<URL, Error>
            do {
                result = .success(try createOrOpen(accountId: accountId))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    static func createOrOpen(accountId: Int64) throws -> URL {
        guard accountId > 0 else { throw StorageError.invalidAccount }

        let fileManager = FileManager.default
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = support
            .appendingPathComponent("Goldgram", isDirectory: true)
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(String(accountId), isDirectory: true)

        let protectedAttributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: protectedAttributes
        )
        try fileManager.setAttributes(
            protectedAttributes, ofItemAtPath: directory.path
        )

        let url = directory.appendingPathComponent("goldgram_history.sqlite")
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let db = handle else {
            if let partial = handle {
                sqlite3_close(partial)
            }
            throw StorageError.sqlite(opened)
        }
        defer { sqlite3_close(db) }

        guard sqlite3_busy_timeout(db, 2500) == SQLITE_OK else {
            throw StorageError.sqlite(sqlite3_errcode(db))
        }
        try execute("PRAGMA foreign_keys = ON;", on: db)
        try execute("PRAGMA journal_mode = WAL;", on: db)

        let version = try readSchemaVersion(from: db)
        if version > currentSchemaVersion {
            throw StorageError.incompatibleSchema(version)
        }
        if version < currentSchemaVersion {
            // A clean install and upgrades from #66 are migrated atomically.
            // Failure rolls back both DDL and user_version; existing originals,
            // revision rows and event IDs are never rewritten or discarded.
            do {
                try execute("BEGIN IMMEDIATE;", on: db)
                if version == 0 {
                    try execute(schemaV1, on: db)
                }
                if version <= 1 {
                    try execute(schemaV2, on: db)
                }
                try execute("PRAGMA user_version = 2;", on: db)
                try execute("COMMIT;", on: db)
            } catch {
                try? execute("ROLLBACK;", on: db)
                throw error
            }
        }

        // Protect DB and existing WAL/SHM sidecars. The account directory
        // sets the inherited protection for sidecars created on later writes.
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if fileManager.fileExists(atPath: path) {
                try fileManager.setAttributes(
                    protectedAttributes, ofItemAtPath: path
                )
            }
        }
        return url
    }

    private static func readSchemaVersion(from db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(
            db, "PRAGMA user_version;", -1, &statement, nil
        )
        guard status == SQLITE_OK, let stmt = statement else {
            if let partial = statement {
                sqlite3_finalize(partial)
            }
            throw StorageError.sqlite(status)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw StorageError.sqlite(sqlite3_errcode(db))
        }
        return sqlite3_column_int(stmt, 0)
    }

    private static func execute(
        _ sql: String, on db: OpaquePointer
    ) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else {
            // Only return SQLite error codes. Never log message contents,
            // SQL parameters, or chat/person identifiers.
            throw StorageError.sqlite(code)
        }
    }

    // No records are inserted in this atom. SQLite triggers, foreign keys and
    // unique composite keys enforce account/dialog separation in later atoms.
    // peer_kind: 0=user, 1=basic group, 2=supergroup, 3=channel.
    // All observed_at / first_seen_at fields are Unix milliseconds.
    private static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS dialogs (
        peer_kind INTEGER NOT NULL CHECK (peer_kind BETWEEN 0 AND 3),
        peer_id INTEGER NOT NULL CHECK (peer_id != 0),
        display_name TEXT,
        last_event_at INTEGER,
        PRIMARY KEY (peer_kind, peer_id)
    );

    CREATE TABLE IF NOT EXISTS messages (
        peer_kind INTEGER NOT NULL,
        peer_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        original_text TEXT,
        original_observed INTEGER NOT NULL DEFAULT 0
            CHECK (original_observed IN (0, 1)),
        first_seen_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0
            CHECK (is_deleted IN (0, 1)),
        PRIMARY KEY (peer_kind, peer_id, message_id),
        FOREIGN KEY (peer_kind, peer_id)
            REFERENCES dialogs (peer_kind, peer_id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS revisions (
        peer_kind INTEGER NOT NULL,
        peer_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        version_index INTEGER NOT NULL CHECK (version_index >= 0),
        content TEXT NOT NULL,
        observed_at INTEGER NOT NULL,
        server_edit_at INTEGER,
        content_hash TEXT,
        PRIMARY KEY (peer_kind, peer_id, message_id, version_index),
        FOREIGN KEY (peer_kind, peer_id, message_id)
            REFERENCES messages (peer_kind, peer_id, message_id)
            ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS events (
        event_id INTEGER PRIMARY KEY AUTOINCREMENT,
        peer_kind INTEGER NOT NULL,
        peer_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        event_kind INTEGER NOT NULL CHECK (event_kind IN (1, 2)),
        source TEXT NOT NULL,
        event_key TEXT NOT NULL UNIQUE,
        server_time INTEGER,
        observed_at INTEGER NOT NULL,
        FOREIGN KEY (peer_kind, peer_id, message_id)
            REFERENCES messages (peer_kind, peer_id, message_id)
            ON DELETE CASCADE
    );

    -- A cloud deletion sometimes supplies a message ID but no dialog ID.
    -- Hold it without guessing which private chat or group is responsible.
    CREATE TABLE IF NOT EXISTS unresolved_deletions (
        update_key TEXT NOT NULL,
        message_id INTEGER NOT NULL,
        observed_at INTEGER NOT NULL,
        PRIMARY KEY (update_key, message_id)
    );

    -- NULL retention_days means forever; no cleanup runs in this atom.
    CREATE TABLE IF NOT EXISTS retention_settings (
        peer_kind INTEGER PRIMARY KEY CHECK (peer_kind BETWEEN 0 AND 3),
        retention_days INTEGER
            CHECK (retention_days IN (1, 3, 7) OR retention_days IS NULL)
    );

    CREATE INDEX IF NOT EXISTS messages_recent_by_dialog
        ON messages (peer_kind, peer_id, last_seen_at DESC);
    CREATE INDEX IF NOT EXISTS events_recent_by_dialog
        ON events (peer_kind, peer_id, observed_at DESC);
    CREATE INDEX IF NOT EXISTS events_recent_by_type
        ON events (event_kind, observed_at DESC);
    CREATE INDEX IF NOT EXISTS revisions_recent
        ON revisions (peer_kind, peer_id, message_id, version_index DESC);
    """

    // Goldgram #67: additive metadata, never a destructive table rebuild.
    // Times are Unix milliseconds; unknown values stay NULL. v1 rows retain
    // provenance=0 because their historical observation source is uncertain.
    //
    // sender_kind: 0 user, 1 group, 2 supergroup, 3 channel; sender_id is raw.
    // capture_provenance: 0 unknown/v1, 1 live initial, 2 difference snapshot,
    //                     3 explicitly verified legacy import (future).
    // revision_provenance: 0 unknown/v1, 1 live observed, 2 catch-up observed,
    //                      3 known edit (future).
    private static let schemaV2 = """
    ALTER TABLE messages ADD COLUMN sender_kind INTEGER
        CHECK (sender_kind IS NULL OR sender_kind BETWEEN 0 AND 3);
    ALTER TABLE messages ADD COLUMN sender_id INTEGER;
    ALTER TABLE messages ADD COLUMN sent_at INTEGER;
    ALTER TABLE messages ADD COLUMN thread_id INTEGER;
    ALTER TABLE messages ADD COLUMN reply_to_message_id INTEGER;
    ALTER TABLE messages ADD COLUMN root_channel_peer_id INTEGER;
    ALTER TABLE messages ADD COLUMN root_channel_post_id INTEGER;
    ALTER TABLE messages ADD COLUMN anchor_before_message_id INTEGER;
    ALTER TABLE messages ADD COLUMN anchor_after_message_id INTEGER;
    ALTER TABLE messages ADD COLUMN capture_provenance INTEGER NOT NULL DEFAULT 0
        CHECK (capture_provenance BETWEEN 0 AND 3);
    ALTER TABLE revisions ADD COLUMN revision_provenance INTEGER NOT NULL DEFAULT 0
        CHECK (revision_provenance BETWEEN 0 AND 3);

    CREATE INDEX IF NOT EXISTS messages_by_sent_time
        ON messages (peer_kind, peer_id, sent_at DESC, message_id DESC);
    CREATE INDEX IF NOT EXISTS messages_by_sender
        ON messages (sender_kind, sender_id, sent_at DESC);
    CREATE INDEX IF NOT EXISTS messages_by_thread
        ON messages (peer_kind, peer_id, thread_id, sent_at DESC);
    CREATE INDEX IF NOT EXISTS messages_by_root_channel_post
        ON messages (root_channel_peer_id, root_channel_post_id, sent_at DESC);
    CREATE INDEX IF NOT EXISTS messages_by_reply
        ON messages (peer_kind, peer_id, reply_to_message_id);
    """
}


// Goldgram #66: incoming personal-message originals, account-scoped and
// explicitly opt-in. The host supplies its authenticated accountPeerId.
private extension GoldgramHistoryStore {
    static var archiveConnections: [Int64: OpaquePointer] = [:]

    static func archiveConnection(for accountId: Int64) throws -> OpaquePointer {
        if let cached = archiveConnections[accountId] { return cached }
        let url = try createOrOpen(accountId: accountId)
        var pointer: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path, &pointer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard rc == SQLITE_OK, let db = pointer else {
            if let pointer = pointer { sqlite3_close(pointer) }
            throw StorageError.sqlite(rc)
        }
        guard sqlite3_busy_timeout(db, 2500) == SQLITE_OK,
              sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw StorageError.sqlite(SQLITE_ERROR)
        }
        archiveConnections[accountId] = db
        return db
    }

    static func archiveSQL(
        _ sql: String, db: OpaquePointer,
        ints: [Int64], text: String? = nil
    ) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let stmt = statement else {
            if let statement = statement { sqlite3_finalize(statement) }
            throw StorageError.sqlite(prepared)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in ints.enumerated() {
            let code = sqlite3_bind_int64(stmt, Int32(i + 1), value)
            guard code == SQLITE_OK else { throw StorageError.sqlite(code) }
        }
        if let text = text {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let utf8 = Array(text.utf8)
            let bound: Int32 = utf8.withUnsafeBytes { bytes in
                sqlite3_bind_text(
                    stmt, Int32(ints.count + 1),
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    Int32(bytes.count), transient
                )
            }
            guard bound == SQLITE_OK else { throw StorageError.sqlite(bound) }
        }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE else {
            throw StorageError.sqlite(result)
        }
    }

    // Returns the latest version (including its actual UTF-8 bytes). A repeated
    // delivery of the same edited text must not create another revision/event.
    static func lastSavedRevision(
        db: OpaquePointer, peerId: Int64, messageId: Int32
    ) throws -> (index: Int64, text: String)? {
        let sql = """
        SELECT version_index, content
        FROM revisions
        WHERE peer_kind = 0 AND peer_id = ? AND message_id = ?
        ORDER BY version_index DESC LIMIT 1;
        """
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let stmt = statement else {
            if let partial = statement { sqlite3_finalize(partial) }
            throw StorageError.sqlite(prepared)
        }
        defer { sqlite3_finalize(stmt) }
        let b1 = sqlite3_bind_int64(stmt, 1, peerId)
        let b2 = sqlite3_bind_int64(stmt, 2, Int64(messageId))
        guard b1 == SQLITE_OK, b2 == SQLITE_OK else {
            throw StorageError.sqlite(b1 != SQLITE_OK ? b1 : b2)
        }
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw StorageError.sqlite(status) }
        let index = sqlite3_column_int64(stmt, 0)
        let byteCount = Int(sqlite3_column_bytes(stmt, 1))
        guard let bytes = sqlite3_column_text(stmt, 1), byteCount >= 0 else {
            throw StorageError.sqlite(SQLITE_CORRUPT)
        }
        let content = String(decoding: UnsafeBufferPointer(start: bytes, count: byteCount), as: UTF8.self)
        return (index, content)
    }

    // #68: real edits only, received in TelegramCore.updateEditMessage.
    // Keeps the original immutable. If no prior capture exists, stores the
    // edited text as "first known edited version" and leaves original NULL.
    // Does NOT touch the existing MX Anti-Edit tracking or UI.
    static func archiveEdit(
        accountId: Int64, peerId: Int64, messageId: Int32,
        text: String, senderId: Int64, sentAt: Int64,
        threadId: Int64, editedAt: Int64
    ) {
        guard accountId > 0, peerId > 0, messageId > 0,
              !text.isEmpty, text.utf8.count <= 65536 else { return }
        storageQueue.async {
            guard UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled") else {
                return
            }
            do {
                let db = try archiveConnection(for: accountId)
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                try archiveSQL("BEGIN IMMEDIATE;", db: db, ints: [])
                do {
                    try archiveSQL(
                        "INSERT OR IGNORE INTO dialogs (peer_kind, peer_id) VALUES (0, ?);",
                        db: db, ints: [peerId]
                    )
                    // A genuinely edited message may arrive when Goldgram
                    // was not yet recording its original (or after a reinstall).
                    // It is *not* evidence for a pre-edit original.
                    try archiveSQL(
                        """
                        INSERT OR IGNORE INTO messages
                        (peer_kind, peer_id, message_id, original_text,
                         original_observed, capture_provenance,
                         first_seen_at, last_seen_at)
                        VALUES (0, ?, ?, NULL, 0, 0, ?, ?);
                        """,
                        db: db,
                        ints: [peerId, Int64(messageId), now, now]
                    )
                    try archiveSQL(
                        """
                        UPDATE messages
                        SET sender_kind = CASE
                                WHEN sender_kind IS NULL AND ? > 0 THEN 0
                                ELSE sender_kind END,
                            sender_id = COALESCE(sender_id, NULLIF(?, 0)),
                            sent_at = COALESCE(sent_at, NULLIF(?, 0)),
                            thread_id = COALESCE(thread_id, NULLIF(?, 0)),
                            last_seen_at = MAX(last_seen_at, ?)
                        WHERE peer_kind = 0 AND peer_id = ? AND message_id = ?;
                        """,
                        db: db,
                        ints: [senderId, senderId, sentAt, threadId,
                               now, peerId, Int64(messageId)]
                    )
                    if let previous = try lastSavedRevision(
                        db: db, peerId: peerId, messageId: messageId
                    ), previous.text == text {
                        // Duplicated/catch-up edit. No event should be added.
                        try archiveSQL("COMMIT;", db: db, ints: [])
                        return
                    }
                    let previous = try lastSavedRevision(
                        db: db, peerId: peerId, messageId: messageId
                    )
                    guard previous == nil || previous!.index < Int64.max else {
                        throw StorageError.sqlite(SQLITE_TOOBIG)
                    }
                    let index = (previous?.index ?? -1) + 1

                    // version_index 0 is the only *known* edit when no original
                    // exists; its revision_provenance=3 explicitly marks it.
                    try archiveSQL(
                        """
                        INSERT INTO revisions
                        (peer_kind, peer_id, message_id, version_index,
                         content, observed_at, server_edit_at,
                         revision_provenance)
                        VALUES (0, ?, ?, ?, ?, ?, 3);
                        """.replacingOccurrences(of: "?, ?, ?, ?, ?, 3", with: "?, ?, ?, ?, ?, 3"),
                        db: db,
                        ints: [peerId, Int64(messageId), index,
                               now, editedAt > 0 ? editedAt : 0],
                        text: text
                    )

                    // One stable key per observed content transition. A repeated
                    // update keeps the last version identical and never reaches
                    // this insert. An A→B→A revert is a *new* transition.
                    let key = "goldgram.edit.0.\(peerId).\(messageId).\(index)"
                    try archiveSQL(
                        """
                        INSERT OR IGNORE INTO events
                        (peer_kind, peer_id, message_id, event_kind, source,
                         event_key, server_time, observed_at)
                        VALUES (0, ?, ?, 1, 'telegram_edit_update', ?, NULLIF(?, 0), ?);
                        """,
                        db: db,
                        ints: [peerId, Int64(messageId),
                               editedAt > 0 ? editedAt : 0, now],
                        text: key
                    )
                    try archiveSQL("COMMIT;", db: db, ints: [])
                } catch {
                    try? archiveSQL("ROLLBACK;", db: db, ints: [])
                    throw error
                }
            } catch {
                // Fail closed. Never print private message bodies, message IDs
                // or account IDs; do not affect Telegram's real edits.
            }
        }
    }

    static func archiveIncoming(
        accountId: Int64, peerId: Int64, messageId: Int32,
        text: String, live: Bool,
        senderId: Int64 = 0, sentAt: Int64 = 0, threadId: Int64 = 0
    ) {
        guard accountId > 0, peerId > 0, messageId > 0,
              !text.isEmpty, text.utf8.count <= 65536 else { return }
        storageQueue.async {
            guard UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled") else {
                return
            }
            do {
                let db = try archiveConnection(for: accountId)
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                try archiveSQL("BEGIN IMMEDIATE;", db: db, ints: [])
                do {
                    try archiveSQL(
                        "INSERT OR IGNORE INTO dialogs (peer_kind, peer_id) VALUES (0, ?);",
                        db: db, ints: [peerId]
                    )
                    // Never overwrite a previous original or a migration.
                    // 'live' is true for a real updateNewMessage, false when
                    // a catch-up difference may already contain edited text.
                    // The original is immutable. For a new record, the
                    // provenance flag distinguishes live delivery from a
                    // catch-up where the first known text may already be edited.
                    try archiveSQL(
                        "INSERT OR IGNORE INTO messages (peer_kind, peer_id, message_id, original_observed, capture_provenance, first_seen_at, last_seen_at, original_text) VALUES (0, ?, ?, ?, ?, ?, ?, ?);",
                        db: db,
                        ints: [peerId, Int64(messageId), live ? 1 : 0, live ? 1 : 2, now, now],
                        text: text
                    )
                    // Also backfill missing metadata for existing #66 rows.
                    // Never manufacture a sender, timestamp, discussion
                    // mapping or certainty flag where the host lacks proof.
                    try archiveSQL(
                        """
                        UPDATE messages
                        SET sender_kind = CASE WHEN sender_kind IS NULL AND ? > 0 THEN 0 ELSE sender_kind END,
                            sender_id = COALESCE(sender_id, NULLIF(?, 0)),
                            sent_at = COALESCE(sent_at, NULLIF(?, 0)),
                            thread_id = COALESCE(thread_id, NULLIF(?, 0))
                        WHERE peer_kind = 0 AND peer_id = ? AND message_id = ?;
                        """,
                        db: db,
                        ints: [
                            senderId > 0 ? senderId : 0,
                            senderId > 0 ? senderId : 0,
                            sentAt > 0 ? sentAt : 0,
                            threadId > 0 ? threadId : 0,
                            peerId, Int64(messageId)
                        ]
                    )
                    try archiveSQL(
                        "INSERT OR IGNORE INTO revisions (peer_kind, peer_id, message_id, version_index, observed_at, revision_provenance, content) VALUES (0, ?, ?, 0, ?, ?, ?);",
                        db: db,
                        ints: [peerId, Int64(messageId), now, live ? 1 : 2],
                        text: text
                    )
                    try archiveSQL("COMMIT;", db: db, ints: [])
                } catch {
                    try? archiveSQL("ROLLBACK;", db: db, ints: [])
                    throw error
                }
            } catch {
                // Fail closed, retain old Mx functionality. No chat text,
                // account identifier, or query details go into diagnostics.
            }
        }
    }
}

// Stable C ABI: the original TelegramCore host resolves this from Mx.dylib
// using dlsym at runtime. No C++ ABI or additional host library dependencies.
@_cdecl("goldgram_archive_original")
public func goldgramArchiveOriginal(
    accountId: Int64, peerKind: Int32, peerId: Int64,
    messageId: Int32, content: UnsafePointer<CChar>?, live: Int32
) {
    guard peerKind == 0, let content = content else { return }
    let text = String(cString: content)
    GoldgramHistoryStore.archiveIncoming(
        accountId: accountId, peerId: peerId, messageId: messageId,
        text: text, live: live != 0
    )
}

// Goldgram #67: compatible v2 bridge. Keep #66's symbol working for existing
// callers; no breaking changes to the Mx linkage or settings.
@_cdecl("goldgram_archive_original_v2")
public func goldgramArchiveOriginalV2(
    accountId: Int64, peerKind: Int32, peerId: Int64,
    messageId: Int32, senderId: Int64, sentAt: Int64,
    threadId: Int64, content: UnsafePointer<CChar>?, live: Int32
) {
    guard peerKind == 0, let content = content else { return }
    let text = String(cString: content)
    GoldgramHistoryStore.archiveIncoming(
        accountId: accountId, peerId: peerId, messageId: messageId,
        text: text, live: live != 0,
        senderId: senderId, sentAt: sentAt, threadId: threadId
    )
}


// #68: account-identified real edit updates. No general response sniffing.
@_cdecl("goldgram_archive_edit_v1")
public func goldgramArchiveEditV1(
    accountId: Int64, peerKind: Int32, peerId: Int64,
    messageId: Int32, senderId: Int64, sentAt: Int64,
    threadId: Int64, editedAt: Int64,
    content: UnsafePointer<CChar>?
) {
    guard peerKind == 0, let content = content else { return }
    GoldgramHistoryStore.archiveEdit(
        accountId: accountId, peerId: peerId, messageId: messageId,
        text: String(cString: content),
        senderId: senderId, sentAt: sentAt, threadId: threadId,
        editedAt: editedAt
    )
}
