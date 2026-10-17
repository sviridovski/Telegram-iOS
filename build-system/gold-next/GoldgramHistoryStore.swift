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

        #if os(iOS)
        let protectedAttributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        #else
        // macOS runs the same writer/queue against real SQLite in CI.
        let protectedAttributes: [FileAttributeKey: Any] = [:]
        #endif
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
        db: OpaquePointer, peerId: Int64, messageId: Int32,
        peerKind: Int32 = 0
    ) throws -> (index: Int64, text: String)? {
        let sql = """
        SELECT version_index, content
        FROM revisions
        WHERE peer_kind = ? AND peer_id = ? AND message_id = ?
        ORDER BY version_index DESC LIMIT 1;
        """
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let stmt = statement else {
            if let partial = statement { sqlite3_finalize(partial) }
            throw StorageError.sqlite(prepared)
        }
        defer { sqlite3_finalize(stmt) }
        let b1 = sqlite3_bind_int64(stmt, 1, Int64(peerKind))
        let b2 = sqlite3_bind_int64(stmt, 2, peerId)
        let b3 = sqlite3_bind_int64(stmt, 3, Int64(messageId))
        guard b1 == SQLITE_OK, b2 == SQLITE_OK, b3 == SQLITE_OK else {
            throw StorageError.sqlite(b1 != SQLITE_OK ? b1 : (b2 != SQLITE_OK ? b2 : b3))
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
        threadId: Int64, editedAt: Int64, peerKind: Int32 = 0
    ) {
        guard peerKind >= 0, peerKind <= 3,
              accountId > 0, peerId > 0, messageId > 0,
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
                        "INSERT OR IGNORE INTO dialogs (peer_kind, peer_id) VALUES (?, ?);",
                        db: db, ints: [Int64(peerKind), peerId]
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
                        VALUES (?, ?, ?, NULL, 0, 0, ?, ?);
                        """,
                        db: db,
                        ints: [Int64(peerKind), peerId, Int64(messageId), now, now]
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
                        WHERE peer_kind = ? AND peer_id = ? AND message_id = ?;
                        """,
                        db: db,
                        ints: [senderId, senderId, sentAt, threadId,
                               now, Int64(peerKind), peerId, Int64(messageId)]
                    )
                    let previous = try lastSavedRevision(
                        db: db, peerId: peerId, messageId: messageId,
                        peerKind: peerKind
                    )
                    if previous?.text == text {
                        // Duplicated/catch-up edit. No event should be added.
                        try archiveSQL("COMMIT;", db: db, ints: [])
                        return
                    }
                    guard previous?.index != Int64.max else {
                        throw StorageError.sqlite(SQLITE_TOOBIG)
                    }
                    let index = (previous?.index ?? -1) + 1

                    // version_index 0 is the only *known* edit when no original
                    // exists; its revision_provenance=3 explicitly marks it.
                    try archiveSQL(
                        """
                        INSERT INTO revisions
                        (peer_kind, peer_id, message_id, version_index,
                         observed_at, server_edit_at, revision_provenance,
                         content)
                        VALUES (?, ?, ?, ?, ?, NULLIF(?, 0), 3, ?);
                        """,
                        db: db,
                        ints: [Int64(peerKind), peerId, Int64(messageId), index,
                               now, editedAt > 0 ? editedAt : 0],
                        text: text
                    )

                    // One stable key per observed content transition. A repeated
                    // update keeps the last version identical and never reaches
                    // this insert. An A→B→A revert is a *new* transition.
                    let key = "goldgram.edit.\(peerKind).\(peerId).\(messageId).\(index)"
                    try archiveSQL(
                        """
                        INSERT OR IGNORE INTO events
                        (peer_kind, peer_id, message_id, event_kind, source,
                         server_time, observed_at, event_key)
                        VALUES (?, ?, ?, 1, 'telegram_edit_update', NULLIF(?, 0), ?, ?);
                        """,
                        db: db,
                        ints: [Int64(peerKind), peerId, Int64(messageId),
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

    static func retainedIdsForClear(accountId: Int64) throws -> [[String: Any]] {
        let db = try archiveConnection(for: accountId)
        var statement: OpaquePointer?
        let sql = "SELECT m.peer_kind,m.peer_id,m.message_id FROM messages m WHERE EXISTS (SELECT 1 FROM events e WHERE e.peer_kind=m.peer_kind AND e.peer_id=m.peer_id AND e.message_id=m.message_id AND (e.event_kind=2 OR (e.event_kind=1 AND e.source='goldgram_native_live_v2')));"
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let stmt = statement else { throw StorageError.sqlite(code) }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: Any]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw StorageError.sqlite(step) }
            rows.append(["peerKind": NSNumber(value: sqlite3_column_int(stmt,0)),
                "peerId": NSNumber(value: sqlite3_column_int64(stmt,1)), "messageId": NSNumber(value: sqlite3_column_int64(stmt,2))])
        }
        return rows
    }

    // Called only on storageQueue, in FIFO order with capture and reads.
    // Keep the connection/schema/settings; cascade removes all message history.
    static func clearHistory(accountId: Int64) throws {
        let db = try archiveConnection(for: accountId)
        try archiveSQL("BEGIN IMMEDIATE;", db: db, ints: [])
        do {
            try execute(clearHistorySQL, on: db)
            try archiveSQL("COMMIT;", db: db, ints: [])
        } catch {
            try? archiveSQL("ROLLBACK;", db: db, ints: [])
            throw error
        }
    }

    private static let clearHistorySQL = """
    DELETE FROM dialogs;
    DELETE FROM unresolved_deletions;
    """

    static func archiveIncoming(
        accountId: Int64, peerId: Int64, messageId: Int32,
        text: String, live: Bool,
        senderId: Int64 = 0, sentAt: Int64 = 0, threadId: Int64 = 0,
        peerKind: Int32 = 0
    ) {
        guard peerKind >= 0, peerKind <= 3,
              accountId > 0, peerId > 0, messageId > 0,
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
                        "INSERT OR IGNORE INTO dialogs (peer_kind, peer_id) VALUES (?, ?);",
                        db: db, ints: [Int64(peerKind), peerId]
                    )
                    // Never overwrite a previous original or a migration.
                    // 'live' is true for a real updateNewMessage, false when
                    // a catch-up difference may already contain edited text.
                    // The original is immutable. For a new record, the
                    // provenance flag distinguishes live delivery from a
                    // catch-up where the first known text may already be edited.
                    try archiveSQL(
                        "INSERT OR IGNORE INTO messages (peer_kind, peer_id, message_id, original_observed, capture_provenance, first_seen_at, last_seen_at, original_text) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
                        db: db,
                        ints: [Int64(peerKind), peerId, Int64(messageId), live ? 1 : 0, live ? 1 : 2, now, now],
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
                        WHERE peer_kind = ? AND peer_id = ? AND message_id = ?;
                        """,
                        db: db,
                        ints: [
                            senderId > 0 ? senderId : 0,
                            senderId > 0 ? senderId : 0,
                            sentAt > 0 ? sentAt : 0,
                            threadId > 0 ? threadId : 0,
                            Int64(peerKind), peerId, Int64(messageId)
                        ]
                    )
                    try archiveSQL(
                        "INSERT OR IGNORE INTO revisions (peer_kind, peer_id, message_id, version_index, observed_at, revision_provenance, content) VALUES (?, ?, ?, 0, ?, ?, ?);",
                        db: db,
                        ints: [Int64(peerKind), peerId, Int64(messageId), now, live ? 1 : 2],
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


// Goldgram #72: bounded, read-only account-scoped history queries.
// This is the data contract for future category/dialog screens; it does not
// open the UI, infer the current account, or import legacy MX defaults.

// #78: callable only on the main thread from the archive UI.
// The native host owns actual Telegram account records and navigation.
// Failure to register keeps archive data fully read-only and navigational
// requests disabled; cached peer IDs never authorize another account.
typealias GoldgramNativeNavigate = @convention(c) (
    Int64, Int32, Int64, Int32
) -> Int32

@objc(GoldgramArchiveReader)
public final class GoldgramArchiveReader: NSObject {
    private static let accountLock = NSLock()
    private static var selectedAccount: Int64 = 0
    private static var nativeNavigate: GoldgramNativeNavigate?

    static func registerNativeNavigation(_ callback: GoldgramNativeNavigate?) {
        accountLock.lock()
        nativeNavigate = callback
        accountLock.unlock()
    }

    @objc(navigateToMessage:)
    public static func navigateToMessage(_ request: NSDictionary) -> Bool {
        guard Thread.isMainThread,
              let accountId = (request["accountId"] as? NSNumber)?.int64Value,
              let peerId = (request["peerId"] as? NSNumber)?.int64Value,
              let rawKind = (request["peerKind"] as? NSNumber)?.intValue,
              let peerKind = Int32(exactly: rawKind),
              let rawMessageId = (request["messageId"] as? NSNumber)?.int64Value,
              let messageId = Int32(exactly: rawMessageId),
              accountId > 0, peerId > 0, messageId > 0,
              (0...3).contains(peerKind) else { return false }
        accountLock.lock()
        let allowed = selectedAccount == accountId
        let navigation = nativeNavigate
        accountLock.unlock()
        guard allowed, let navigation else { return false }
        // This confirms native navigation was requested, not that a deleted
        // or inaccessible message still exists in Telegram.
        return navigation(accountId, peerKind, peerId, messageId) == 1
    }

    static func updateSelectedAccount(_ id: Int64) {
        accountLock.lock()
        selectedAccount = max(0, id)
        accountLock.unlock()
    }

    private static func isSelected(_ id: Int64) -> Bool {
        accountLock.lock()
        defer { accountLock.unlock() }
        return id > 0 && selectedAccount == id
    }

    // The menu binds the account before confirmation. Never clear whichever
    // account happens to be active by the time the queued action executes.
    @objc(clearHistoryForAccount:completion:)
    public static func clearHistory(
        forAccount account: NSNumber,
        completion: @escaping (NSDictionary) -> Void
    ) {
        let accountId = account.int64Value
        guard isSelected(accountId) else {
            completion(["status": "account_changed"])
            return
        }
        GoldgramHistoryStore.storageQueue.async {
            guard self.isSelected(accountId) else {
                DispatchQueue.main.async { completion(["status": "account_changed"]) }
                return
            }
            let status: String
            var retained: [[String: Any]] = []
            do {
                retained = try GoldgramHistoryStore.retainedIdsForClear(accountId: accountId)
                try GoldgramHistoryStore.clearHistory(accountId: accountId)
                status = "ok"
            } catch {
                status = "unavailable"
            }
            let retainedItems = retained
            DispatchQueue.main.async { completion(["status": status, "retainedItems": retainedItems]) }
        }
    }

    @objc(activeAccountId)
    public static func activeAccountId() -> NSNumber? {
        accountLock.lock()
        defer { accountLock.unlock() }
        return selectedAccount > 0 ? NSNumber(value: selectedAccount) : nil
    }
    // #79: every category shows only edit/deletion events. Original-only rows
    // stay private baselines for future comparisons, never archive entries.
    // One database per account; peer kind + peer ID scope every lookup.
    private static let dialogsSQL = """
    SELECT d.peer_kind, d.peer_id, COUNT(*) AS archived_count,
           MAX(COALESCE((SELECT MAX(e.observed_at) FROM events e WHERE e.peer_kind=m.peer_kind
             AND e.peer_id=m.peer_id AND e.message_id=m.message_id),m.last_seen_at)) AS newest_at
    FROM dialogs d
    JOIN messages m
      ON m.peer_kind = d.peer_kind AND m.peer_id = d.peer_id
    WHERE d.peer_kind IN (?, ?)
      AND (m.is_deleted = 1 OR EXISTS (
           SELECT 1 FROM events e
           WHERE e.peer_kind = m.peer_kind AND e.peer_id = m.peer_id
             AND e.message_id = m.message_id AND (e.event_kind = 2 OR (e.event_kind = 1 AND (e.source = 'goldgram_native_live_v2' OR (e.source != 'goldgram_native_v1' AND e.server_time > 0 AND m.original_observed = 1 AND EXISTS (
               SELECT 1 FROM revisions vr WHERE vr.peer_kind=m.peer_kind AND vr.peer_id=m.peer_id
                 AND vr.message_id=m.message_id AND vr.content != m.original_text)))))))
    GROUP BY d.peer_kind, d.peer_id
    ORDER BY newest_at DESC, d.peer_kind ASC, d.peer_id ASC
    LIMIT ? OFFSET ?;
    """

    private static let messagesSQL = """
    SELECT m.peer_kind, m.peer_id, m.message_id, m.original_text,
           m.original_observed, m.capture_provenance, m.sender_id,
           m.sent_at, m.last_seen_at, m.is_deleted,
           (SELECT r.content FROM revisions r
            WHERE r.peer_kind = m.peer_kind AND r.peer_id = m.peer_id
              AND r.message_id = m.message_id
            ORDER BY CASE WHEN m.is_deleted=1 AND r.content='[Содержимое не было получено]' THEN 1 ELSE 0 END ASC,
                     r.version_index DESC LIMIT 1) AS latest_text,
           (SELECT COUNT(*) FROM revisions r
            WHERE r.peer_kind = m.peer_kind AND r.peer_id = m.peer_id
              AND r.message_id = m.message_id) AS revision_count,
           (SELECT r.content FROM revisions r
            WHERE r.peer_kind = m.peer_kind AND r.peer_id = m.peer_id
              AND r.message_id = m.message_id
            ORDER BY r.version_index ASC LIMIT 1) AS first_known_text,
           m.sender_kind,
           EXISTS (SELECT 1 FROM events e
             WHERE e.peer_kind = m.peer_kind AND e.peer_id = m.peer_id
               AND e.message_id = m.message_id AND e.event_kind = 1 AND (e.source = 'goldgram_native_live_v2' OR (e.source != 'goldgram_native_v1' AND e.server_time > 0 AND m.original_observed = 1 AND EXISTS (
               SELECT 1 FROM revisions vr WHERE vr.peer_kind=m.peer_kind AND vr.peer_id=m.peer_id
                 AND vr.message_id=m.message_id AND vr.content != m.original_text)))) AS edited,
           EXISTS (SELECT 1 FROM events e
             WHERE e.peer_kind = m.peer_kind AND e.peer_id = m.peer_id
               AND e.message_id = m.message_id AND e.event_kind = 2) AS delete_event,
           (SELECT MIN(e.observed_at) FROM events e WHERE e.peer_kind=m.peer_kind
             AND e.peer_id=m.peer_id AND e.message_id=m.message_id AND e.event_kind=2) AS deleted_at,
           EXISTS (SELECT 1 FROM events e WHERE e.peer_kind=m.peer_kind AND e.peer_id=m.peer_id
             AND e.message_id=m.message_id AND e.event_kind=2 AND e.source='goldgram_native_retained_v1') AS retained
    FROM messages m
    WHERE m.peer_kind = ? AND m.peer_id = ?
      AND (m.is_deleted = 1 OR EXISTS (
           SELECT 1 FROM events e
           WHERE e.peer_kind = m.peer_kind AND e.peer_id = m.peer_id
             AND e.message_id = m.message_id AND (e.event_kind = 2 OR (e.event_kind = 1 AND (e.source = 'goldgram_native_live_v2' OR (e.source != 'goldgram_native_v1' AND e.server_time > 0 AND m.original_observed = 1 AND EXISTS (
               SELECT 1 FROM revisions vr WHERE vr.peer_kind=m.peer_kind AND vr.peer_id=m.peer_id
                 AND vr.message_id=m.message_id AND vr.content != m.original_text)))))))
    ORDER BY COALESCE(m.sent_at, m.last_seen_at) DESC, m.message_id DESC, m.peer_kind ASC, m.peer_id ASC
    LIMIT ? OFFSET ?;
    """

    // Only explicit, positive Telegram account IDs are accepted. The UI must
    // obtain the selected authenticated account from native Telegram context,
    // NEVER from global MxLastKnownUserId or whichever DB happens to exist.
    // The callback is always delivered on the main queue; disk I/O is not.
    @objc(query:completion:)
    public static func query(
        _ request: NSDictionary,
        completion: @escaping (NSDictionary) -> Void
    ) {
        let accountId = (request["accountId"] as? NSNumber)?.int64Value ?? 0
        let category = (request["category"] as? NSNumber)?.intValue ?? -1
        let mode = request["mode"] as? String ?? ""
        let peerId = (request["peerId"] as? NSNumber)?.int64Value ?? 0
        let peerKind = (request["peerKind"] as? NSNumber)?.intValue ?? -1
        // Never trap on an unexpected 64-bit peer kind from a caller.
        let scopedPeerKind = Int32(exactly: peerKind) ?? -1
        let offset = (request["offset"] as? NSNumber)?.intValue ?? 0
        let limit = (request["limit"] as? NSNumber)?.intValue ?? 30
        let kinds: [Int32]
        switch category {
        case 0: kinds = [0, 0]       // Personal
        case 1: kinds = [1, 2]       // Basic groups + supergroups
        case 2: kinds = [2, 3]       // Channels + natively verified discussions in UI
        case 3: kinds = [0, 1, 2, 3] // Deleted-only folder, all cloud peer kinds
        default: kinds = []
        }
        let requestedSources = request["sources"] as? [[String: Any]] ?? []
        var sources: [(kind: Int32, id: Int64)] = []
        if mode == "combined" {
            guard (category == 2 || category == 3), !requestedSources.isEmpty, requestedSources.count <= 2 else {
                completion(["status": "invalid_request", "items": []]); return
            }
            for source in requestedSources {
                guard let rawKind = (source["peerKind"] as? NSNumber)?.int64Value,
                      let kind = Int32(exactly: rawKind), kinds.contains(kind),
                      let id = (source["peerId"] as? NSNumber)?.int64Value, id > 0 else {
                    completion(["status": "invalid_request", "items": []]); return
                }
                if !sources.contains(where: { $0.kind == kind && $0.id == id }) {
                    sources.append((kind, id))
                }
            }
        }
        guard isSelected(accountId), !kinds.isEmpty,
              mode == "dialogs" || mode == "messages" || mode == "combined",
              offset >= 0, offset <= 5000,
              limit >= 1, limit <= 50,
              mode != "messages" ||
              (peerId > 0 && kinds.contains(scopedPeerKind)) else {
            completion(["status": "invalid_request", "items": []])
            return
        }
        GoldgramHistoryStore.storageQueue.async {
            let response = self.read(
                accountId: accountId, mode: mode,
                kinds: kinds, peerId: peerId, peerKind: scopedPeerKind, sources: sources, deletedOnly: category == 3,
                offset: Int32(offset), limit: Int32(limit)
            )
            DispatchQueue.main.async {
                completion(self.isSelected(accountId) ? response as NSDictionary : ["status": "account_changed", "items": []])
            }
        }
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> Any {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
              let bytes = sqlite3_column_text(stmt, column) else {
            return NSNull()
        }
        let count = Int(sqlite3_column_bytes(stmt, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private static func nullableInt(_ stmt: OpaquePointer, _ column: Int32) -> Any {
        if sqlite3_column_type(stmt, column) == SQLITE_NULL {
            return NSNull()
        }
        return NSNumber(value: sqlite3_column_int64(stmt, column))
    }

    private static func read(
        accountId: Int64, mode: String, kinds: [Int32],
        peerId: Int64, peerKind: Int32, sources: [(kind: Int32, id: Int64)], deletedOnly: Bool,
        offset: Int32, limit: Int32
    ) -> [String: Any] {
        // Opening a missing DB in READONLY mode must never create one.
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let path = support
            .appendingPathComponent("Goldgram/Accounts/\(accountId)", isDirectory: true)
            .appendingPathComponent("goldgram_history.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else {
            return ["status": "no_archive", "items": []]
        }
        var pointer: OpaquePointer?
        let rc = sqlite3_open_v2(
            path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard rc == SQLITE_OK, let db = pointer else {
            if let pointer = pointer { sqlite3_close(pointer) }
            return ["status": "unavailable", "items": []]
        }
        defer { sqlite3_close(db) }
        guard sqlite3_busy_timeout(db, 2500) == SQLITE_OK,
              sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil) == SQLITE_OK else {
            return ["status": "unavailable", "items": []]
        }

        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &versionStatement, nil) == SQLITE_OK,
              let version = versionStatement else {
            if let versionStatement = versionStatement { sqlite3_finalize(versionStatement) }
            return ["status": "unavailable", "items": []]
        }
        let versionRead = sqlite3_step(version)
        let schemaVersion = sqlite3_column_int(version, 0)
        sqlite3_finalize(version)
        guard versionRead == SQLITE_ROW && schemaVersion == 2 else {
            return ["status": "incompatible_schema", "items": []]
        }

        var sql = mode == "dialogs" ? dialogsSQL : messagesSQL
        if mode == "dialogs" {
            let placeholders = kinds.map { _ in "?" }.joined(separator: ", ")
            sql = sql.replacingOccurrences(of: "WHERE d.peer_kind IN (?, ?)", with: "WHERE d.peer_kind IN (\(placeholders))")
        }
        if deletedOnly {
            let deletedPredicate = "AND (m.is_deleted=1 OR EXISTS (SELECT 1 FROM events de WHERE de.peer_kind=m.peer_kind AND de.peer_id=m.peer_id AND de.message_id=m.message_id AND de.event_kind=2)) "
            if mode == "dialogs" {
                if let start = sql.range(of: "MAX(COALESCE("), let end = sql.range(of: " AS newest_at") {
                    sql.replaceSubrange(start.lowerBound..<end.lowerBound, with: "MAX(COALESCE((SELECT MIN(de.observed_at) FROM events de WHERE de.peer_kind=m.peer_kind AND de.peer_id=m.peer_id AND de.message_id=m.message_id AND de.event_kind=2),m.last_seen_at))")
                }
                sql = sql.replacingOccurrences(of: "GROUP BY d.peer_kind", with: deletedPredicate + "GROUP BY d.peer_kind")
            } else {
                sql = sql.replacingOccurrences(of: "ORDER BY COALESCE(m.sent_at, m.last_seen_at) DESC", with: deletedPredicate + "ORDER BY COALESCE((SELECT MIN(de.observed_at) FROM events de WHERE de.peer_kind=m.peer_kind AND de.peer_id=m.peer_id AND de.message_id=m.message_id AND de.event_kind=2),m.last_seen_at) DESC")
            }
        }
        if mode == "combined" {
            let predicate = sources.map { _ in "(m.peer_kind = ? AND m.peer_id = ?)" }.joined(separator: " OR ")
            sql = sql.replacingOccurrences(
                of: "WHERE m.peer_kind = ? AND m.peer_id = ?\n",
                with: "WHERE (\(predicate))\n"
            )
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else {
            if let statement = statement { sqlite3_finalize(statement) }
            return ["status": "unavailable", "items": []]
        }
        defer { sqlite3_finalize(stmt) }
        let first: Int64 = mode == "dialogs" ? Int64(kinds[0]) : Int64(peerKind)
        let second: Int64 = mode == "dialogs" ? Int64(kinds[1]) : peerId
        let scope: [Int64] = mode == "combined"
            ? sources.flatMap { [Int64($0.kind), $0.id] }
            : mode == "dialogs" ? kinds.map { Int64($0) } : [first, second]
        let parameters = scope + [Int64(limit), Int64(offset)]
        for (index, value) in parameters.enumerated() {
            guard sqlite3_bind_int64(stmt, Int32(index + 1), value) == SQLITE_OK else {
                return ["status": "unavailable", "items": []]
            }
        }

        var rows: [[String: Any]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                return ["status": "unavailable", "items": []]
            }
            if mode == "dialogs" {
                rows.append([
                    "peerKind": NSNumber(value: sqlite3_column_int(stmt, 0)),
                    "peerId": NSNumber(value: sqlite3_column_int64(stmt, 1)),
                    "messageCount": NSNumber(value: sqlite3_column_int64(stmt, 2)),
                    "lastMessageAt": nullableInt(stmt, 3)
                ])
            } else {
                let observed = sqlite3_column_int(stmt, 4) == 1
                // A catch-up snapshot (observed=0) is never called original.
                rows.append([
                    "peerKind": NSNumber(value: sqlite3_column_int(stmt, 0)),
                    "peerId": NSNumber(value: sqlite3_column_int64(stmt, 1)),
                    "messageId": NSNumber(value: sqlite3_column_int64(stmt, 2)),
                    "originalText": observed ? text(stmt, 3) : NSNull(),
                    "originalObserved": NSNumber(value: observed),
                    "captureProvenance": NSNumber(value: sqlite3_column_int(stmt, 5)),
                    "senderId": nullableInt(stmt, 6),
                    "sentAt": nullableInt(stmt, 7),
                    "lastSeenAt": nullableInt(stmt, 8),
                    "deleted": NSNumber(value: sqlite3_column_int(stmt, 9) == 1 || sqlite3_column_int(stmt, 15) == 1),
                    "latestText": text(stmt, 10),
                    "revisionCount": NSNumber(value: sqlite3_column_int64(stmt, 11)),
                    "firstKnownText": text(stmt, 12),
                    "senderKind": nullableInt(stmt, 13),
                    "edited": NSNumber(value: sqlite3_column_int(stmt, 14) == 1),
                    "deletedAt": nullableInt(stmt, 16),
                    "retained": NSNumber(value: sqlite3_column_int(stmt, 17) == 1)
                ])
            }
        }
        return ["status": "ok", "items": rows, "hasMore": rows.count == Int(limit)]
    }
}

@_cdecl("goldgram_bind_active_account_v1")
public func goldgramBindActiveAccountV1(_ id: Int64) {
    GoldgramArchiveReader.updateSelectedAccount(id)
}


// Goldgram #75: independent ABI for new observed group/channel texts.
// Old personal writer ABIs are unchanged.
@_cdecl("goldgram_archive_public_original_v1")
public func goldgramArchivePublicOriginalV1(
    accountId: Int64, peerKind: Int32, peerId: Int64,
    messageId: Int32, senderId: Int64, sentAt: Int64,
    threadId: Int64, content: UnsafePointer<CChar>?
) {
    guard peerKind >= 1, peerKind <= 3, let content = content else { return }
    GoldgramHistoryStore.archiveIncoming(
        accountId: accountId, peerId: peerId, messageId: messageId,
        text: String(cString: content), live: true,
        senderId: senderId, sentAt: sentAt, threadId: threadId,
        peerKind: peerKind
    )
}


// #77: new isolated C bridge for accepted channel/supergroup edit updates.
// Existing private-channel ABI is preserved; unknown first originals remain NULL.
@_cdecl("goldgram_archive_public_edit_v1")
public func goldgramArchivePublicEditV1(
    accountId: Int64, peerKind: Int32, peerId: Int64, messageId: Int32,
    senderId: Int64, sentAt: Int64, threadId: Int64, editedAt: Int64,
    content: UnsafePointer<CChar>?
) {
    guard peerKind >= 1, peerKind <= 3, let content = content else { return }
    GoldgramHistoryStore.archiveEdit(
        accountId: accountId, peerId: peerId, messageId: messageId,
        text: String(cString: content),
        senderId: senderId, sentAt: sentAt, threadId: threadId,
        editedAt: editedAt, peerKind: peerKind
    )
}

// TelegramUI registers a main-thread native navigator (pointer only).
// A separate C bridge means Mx never imports TelegramUI/Core types.
@_cdecl("goldgram_register_native_navigation_v1")
public func goldgramRegisterNativeNavigationV1(_ rawCallback: UnsafeMutableRawPointer?) {
    let typed: GoldgramNativeNavigate? = rawCallback.map {
        unsafeBitCast($0, to: GoldgramNativeNavigate.self)
    }
    GoldgramArchiveReader.registerNativeNavigation(typed)
}

// #83: authenticated native replay is the sole producer of new history events.
private extension GoldgramHistoryStore {
    static func nativeEvent(_ payload: [String: Any]) -> Bool {
        guard let account = (payload["accountId"] as? NSNumber)?.int64Value, account > 0,
              let kind = (payload["peerKind"] as? NSNumber)?.int32Value,
              let peer = (payload["peerId"] as? NSNumber)?.int64Value,
              let rawId = (payload["messageId"] as? NSNumber)?.int64Value,
              let id = Int32(exactly: rawId), id > 0,
              let event = (payload["eventKind"] as? NSNumber)?.int32Value, (0...2).contains(event),
              UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled") else { return false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if kind == -1 && peer == 0 && event == 2 {
            storageQueue.async {
                do {
                    let db = try archiveConnection(for: account)
                    try archiveSQL("INSERT OR IGNORE INTO unresolved_deletions(message_id, observed_at, update_key) VALUES(?, ?, ?);", db: db, ints: [Int64(id), now], text: "native.global")
                } catch { }
            }
            return true
        }
        guard (0...3).contains(kind), peer > 0,
              let content = payload["text"] as? String, content.utf8.count <= 65536,
              event != 1 || (payload["visibleEdit"] as? Bool == true && (payload["beforeText"] == nil || payload["changed"] as? Bool == true)) else { return false }
        let before = payload["beforeText"] as? String
        guard before == nil || before!.utf8.count <= 65536 else { return false }
        let known = payload["originalObserved"] as? Bool == true
        let retained = payload["retained"] as? Bool == true
        let sender = (payload["senderId"] as? NSNumber)?.int64Value ?? 0
        let senderKind = (payload["senderKind"] as? NSNumber)?.int64Value ?? 0
        let sent = (payload["sentAt"] as? NSNumber)?.int64Value ?? 0
        let thread = (payload["threadId"] as? NSNumber)?.int64Value ?? 0
        let edited = (payload["editedAt"] as? NSNumber)?.int64Value ?? 0
        // Stable content transition identity; Swift's randomized Hasher is not persisted.
        let parts = [before ?? "", content, String(describing: payload["beforeMediaKeys"] ?? ""),
            String(describing: payload["mediaKeys"] ?? ""), String(edited)]
        let identity = parts.map { "\($0.utf8.count):\($0)" }.joined()
        var hash: UInt64 = 14695981039346656037
        for byte in identity.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let key = event == 2 ? "native.delete.\(kind).\(peer).\(id)" : "native.edit.\(kind).\(peer).\(id).\(hash)"
        storageQueue.async {
            do {
                let db = try archiveConnection(for: account)
                try archiveSQL("BEGIN IMMEDIATE;", db: db, ints: [])
                do {
                    let scope = [Int64(kind), peer, Int64(id)]
                    try archiveSQL("INSERT OR IGNORE INTO dialogs(peer_kind,peer_id) VALUES(?,?);", db: db, ints: [Int64(kind),peer])
                    let baseline = before ?? (event != 1 ? content : nil)
                    try archiveSQL("INSERT OR IGNORE INTO messages(peer_kind,peer_id,message_id,first_seen_at,last_seen_at,original_observed,original_text) VALUES(?,?,?,?,?,?,?);", db: db, ints: scope + [now,now,known ? 1 : 0], text: known ? baseline : nil)
                    if known, let baseline {
                        try archiveSQL("UPDATE messages SET original_observed=1, original_text=?4 WHERE peer_kind=?1 AND peer_id=?2 AND message_id=?3 AND original_observed=0;", db: db, ints: scope, text: baseline)
                    }
                    try archiveSQL("UPDATE messages SET sender_kind=COALESCE(sender_kind,CASE WHEN ?4 BETWEEN 0 AND 3 THEN ?4 ELSE NULL END),sender_id=COALESCE(sender_id,NULLIF(?5,0)),sent_at=COALESCE(sent_at,NULLIF(?6,0)),thread_id=COALESCE(thread_id,NULLIF(?7,0)),last_seen_at=MAX(last_seen_at,?8),is_deleted=MAX(is_deleted,?9) WHERE peer_kind=?1 AND peer_id=?2 AND message_id=?3;", db: db, ints: scope + [senderKind,sender,sent,thread,now,event == 2 ? 1 : 0])
                    if try lastSavedRevision(db: db, peerId: peer, messageId: id, peerKind: kind) == nil, let baseline {
                        try archiveSQL("INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,observed_at,revision_provenance,content) VALUES(?,?,?,0,?,?,?);", db: db, ints: scope + [now,known ? 1 : 2], text: baseline)
                    }
                    let last = try lastSavedRevision(db: db, peerId: peer, messageId: id, peerKind: kind)
                    // A delete receipt with no native body must never replace
                    // text already saved by an earlier observation in SQLite.
                    let hasContent = event != 2 || retained
                    if hasContent && last?.text != content {
                        guard last?.index != Int64.max else { throw StorageError.sqlite(SQLITE_TOOBIG) }
                        try archiveSQL("INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,observed_at,server_edit_at,revision_provenance,content) VALUES(?,?,?,?,?,NULLIF(?,0),3,?);", db: db, ints: scope + [(last?.index ?? -1)+1,now,edited], text: content)
                    }
                    let source = event == 2 && retained ? "goldgram_native_retained_v1" : event == 1 ? "goldgram_native_live_v2" : "goldgram_native_v1"
                    // source is a fixed enum above, never a user-supplied SQL fragment.
                    if event != 0 {
                        try archiveSQL("INSERT OR IGNORE INTO events(peer_kind,peer_id,message_id,event_kind,source,server_time,observed_at,event_key) VALUES(?,?,?,?, '\(source)',NULLIF(?,0),?,?);", db: db, ints: scope + [Int64(event),edited,now], text: key)
                    }
                    try archiveSQL("COMMIT;", db: db, ints: [])
                } catch {
                    try? archiveSQL("ROLLBACK;", db: db, ints: []); throw error
                }
            } catch { /* No message content or identifiers in logs. */ }
        }
        return true // enqueued, not a synchronous claim of SQLite commit
    }
}

@_cdecl("goldgram_capture_event_v1")
public func goldgramCaptureEventV1(_ raw: UnsafePointer<CChar>?) -> Int32 {
    guard let raw, let data = String(cString: raw).data(using: .utf8), data.count <= 300000,
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
    return GoldgramHistoryStore.nativeEvent(payload) ? 1 : 0
}
