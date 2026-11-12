// Goldgram SQLite foundation (#64).
// Deliberately inert: no message capture, database creation, or account lookup
// occurs until a future, independently tested atom calls prepare(accountId:).
// Never infer an account ID from a message ID or a chat peer ID.
import Foundation
import SQLite3
import CryptoKit
import Security
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        qos: .userInitiated
    )
    // Closing admission never waits for SQLite. Only the serial queue owns
    // the FIFO and runs its work. A later close invalidates a queued reopen.
    private static let admissionLock = NSLock()
    private static var generation: UInt64 = 0
    private static var admitted = true
    private static var deferred: [() -> Void] = []

    fileprivate static var archiveIsOpen: Bool {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        return admitted
    }

    static func enqueueArchiveWork(_ work: @escaping () -> Void) {
        storageQueue.async {
            if archiveIsOpen { work() } else { deferred.append(work) }
        }
    }

    fileprivate static func setAdmission(_ open: Bool, immediate: Bool) {
        admissionLock.lock()
        generation &+= 1
        let requested = generation
        if !open && immediate { admitted = false }
        admissionLock.unlock()
        if !open && immediate { return }
        storageQueue.async {
            admissionLock.lock()
            guard requested == generation else {
                admissionLock.unlock()
                return
            }
            admitted = open
            admissionLock.unlock()
            guard open else { return }
            let pending = deferred
            deferred.removeAll()
            for work in pending {
                if archiveIsOpen { work() } else { deferred.append(work) }
            }
            if archiveIsOpen { restoreDeferredOriginals() }
        }
    }

    private static let currentSchemaVersion: Int32 = 2

    // Account-specific DB, with peer type + peer ID + message ID scoping inside.
    // Completion intentionally runs on main; the SQLite work never does.
    static func prepare(
        accountId: Int64,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        enqueueArchiveWork {
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

        // #131: evidence lives INSIDE the existing account SQLite v2 database.
        // Additive idempotent table, not a new database or user_version bump.
        // Capture and audit are committed in the SAME SQLite transaction.
        try execute(schemaOriginalEvidence, on: db)
        // #133: additive, backward-compatible: old #131 audits retain unknown
        // commit state/time. No user_version bump and no archive rebuild.
        try ensureOriginalEvidenceColumns(on: db)

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

    // #131: first verified original audit; no message content is duplicated.
    // Scope is the same composite key as messages. Source and attempt are
    // source-of-observation hints, not proof of iOS scheduling causality.
    private static let schemaOriginalEvidence = """
    CREATE TABLE IF NOT EXISTS original_capture_evidence (
        peer_kind INTEGER NOT NULL,
        peer_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        captured_at INTEGER NOT NULL,
        source TEXT NOT NULL,
        attempt_token TEXT,
        edit_already_observed INTEGER NOT NULL CHECK(edit_already_observed IN (0,1)),
        committed_at INTEGER,
        enqueue_state TEXT,
        commit_state TEXT,
        PRIMARY KEY(peer_kind, peer_id, message_id),
        FOREIGN KEY(peer_kind, peer_id, message_id)
            REFERENCES messages(peer_kind, peer_id, message_id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS original_evidence_by_time
        ON original_capture_evidence(captured_at);
    CREATE TABLE IF NOT EXISTS original_capture_attempts (
        attempt_token TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        processed INTEGER NOT NULL DEFAULT 0,
        new_committed INTEGER NOT NULL DEFAULT 0,
        already_present INTEGER NOT NULL DEFAULT 0,
        failed INTEGER NOT NULL DEFAULT 0
    );
    """

    private static func ensureOriginalEvidenceColumns(on db: OpaquePointer) throws {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(original_capture_evidence);", -1, &pointer, nil) == SQLITE_OK,
              let stmt = pointer else {
            if let pointer { sqlite3_finalize(pointer) }
            throw StorageError.sqlite(sqlite3_errcode(db))
        }
        var names = Set<String>()
        var rc: Int32 = SQLITE_ROW
        while true {
            rc = sqlite3_step(stmt)
            if rc != SQLITE_ROW { break }
            if let raw = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: raw))
            }
        }
        sqlite3_finalize(stmt)
        guard rc == SQLITE_DONE else { throw StorageError.sqlite(rc) }
        for (name, type) in [("committed_at", "INTEGER"), ("enqueue_state", "TEXT"), ("commit_state", "TEXT")] {
            if !names.contains(name) {
                try execute("ALTER TABLE original_capture_evidence ADD COLUMN \(name) \(type);", on: db)
            }
        }
    }

    // Returns a lifecycle snapshot at the time of the actual SQLite operation.
    // It is diagnostic context, not a guarantee that iOS never suspended the app.
    private static func lifecycleState() -> String {
        let defaults = UserDefaults.standard
        guard let value = defaults.object(forKey: "GoldgramForegroundActiveV1") as? NSNumber else {
            return "unknown"
        }
        return value.boolValue ? "foreground" : "background"
    }

    private static func recordAttempt(
        db: OpaquePointer, token: String?, source: String, outcome: String
    ) throws {
        guard let token, UUID(uuidString: token) != nil else { return }
        let acceptedSource = ["geo_sensor", "geo_minimized", "geo_unclassified"].contains(source)
            ? source : "geo_unclassified"
        let sql = """
        INSERT INTO original_capture_attempts
            (attempt_token,source,processed,new_committed,already_present,failed)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(attempt_token) DO UPDATE SET
            processed=processed+excluded.processed,
            new_committed=new_committed+excluded.new_committed,
            already_present=already_present+excluded.already_present,
            failed=failed+excluded.failed;
        """
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let stmt = pointer else {
            if let pointer { sqlite3_finalize(pointer) }
            throw StorageError.sqlite(sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func bind(_ string: String, _ index: Int32) throws {
            let rc = string.utf8CString.withUnsafeBufferPointer {
                sqlite3_bind_text(stmt, index, $0.baseAddress, Int32($0.count - 1), transient)
            }
            guard rc == SQLITE_OK else { throw StorageError.sqlite(rc) }
        }
        try bind(token, 1)
        try bind(acceptedSource, 2)
        let values: [Int64] = [
            outcome == "failed" ? 0 : 1,
            outcome == "new" ? 1 : 0,
            outcome == "existing" ? 1 : 0,
            outcome == "failed" ? 1 : 0
        ]
        for (i, value) in values.enumerated() {
            let rc = sqlite3_bind_int64(stmt, Int32(i+3), value)
            guard rc == SQLITE_OK else { throw StorageError.sqlite(rc) }
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw StorageError.sqlite(rc) }
    }

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
fileprivate extension GoldgramHistoryStore {
    static var archiveConnections: [Int64: OpaquePointer] = [:]

    // Access and cleanup are both serialized with archive transactions.
    static var lastArchiveAccess = DispatchTime.now()
    static var archiveTrimScheduled = false

    static func scheduleArchiveTrim() {
        guard !archiveTrimScheduled else { return }
        archiveTrimScheduled = true
        storageQueue.asyncAfter(deadline: lastArchiveAccess + .seconds(10)) {
            archiveTrimScheduled = false
            guard archiveIsOpen else { return }
            if DispatchTime.now() < lastArchiveAccess + .seconds(10) {
                scheduleArchiveTrim()
                return
            }
            for db in archiveConnections.values {
                sqlite3_db_release_memory(db)
            }
        }
    }

    static func archiveConnection(for accountId: Int64) throws -> OpaquePointer {
        lastArchiveAccess = .now()
        scheduleArchiveTrim()
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

    // #131: only a TRUE first capture may claim a first-original audit row.
    // Existing pre-#131 baselines intentionally remain "unattributed".
    static func originalIsKnown(db: OpaquePointer, scope: [Int64]) throws -> Bool {
        var pointer: OpaquePointer?
        let sql = "SELECT 1 FROM messages WHERE peer_kind=? AND peer_id=? AND message_id=? AND original_observed=1 AND original_text IS NOT NULL LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let stmt = pointer else {
            if let pointer { sqlite3_finalize(pointer) }
            throw StorageError.sqlite(sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in scope.enumerated() {
            let rc = sqlite3_bind_int64(stmt, Int32(index + 1), value)
            guard rc == SQLITE_OK else { throw StorageError.sqlite(rc) }
        }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW || step == SQLITE_DONE else { throw StorageError.sqlite(step) }
        return step == SQLITE_ROW
    }

    static func recordFirstOriginalEvidence(
        db: OpaquePointer, scope: [Int64], at: Int64,
        source: String, attempt: String?, concurrentEdit: Bool,
        committedAt: Int64, enqueueState: String, commitState: String
    ) throws {
        // Only these labels can be persisted; never store arbitrary caller strings.
        let sources: Set<String> = [
            "live_update", "channel_difference", "os_bg_refresh",
            "geo_sensor", "geo_minimized", "geo_unclassified",
            "history_snapshot", "notification_postbox", "native_unclassified",
            "edit_with_before", "iphone8_telethon_initial_v1"
        ]
        let safeSource = sources.contains(source) ? source : "native_unclassified"
        // The value is generated by our app as a UUID. Do not log account,
        // sender, message content, credentials or actual coordinates.
        let safeAttempt: String? = {
            guard let attempt, UUID(uuidString: attempt) != nil else { return nil }
            return attempt
        }()
        let sql = """
        INSERT OR IGNORE INTO original_capture_evidence
        (peer_kind, peer_id, message_id, captured_at, source, attempt_token, edit_already_observed,
         committed_at, enqueue_state, commit_state)
        VALUES (?, ?, ?, ?, ?, ?, CASE WHEN ?=1 OR EXISTS(
            SELECT 1 FROM events e WHERE e.peer_kind=? AND e.peer_id=?
              AND e.message_id=? AND e.event_kind=1
        ) THEN 1 ELSE 0 END, ?, ?, ?);
        """
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let stmt = pointer else {
            if let pointer { sqlite3_finalize(pointer) }
            throw StorageError.sqlite(sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in (scope + [at]).enumerated() {
            let rc = sqlite3_bind_int64(stmt, Int32(i + 1), value)
            guard rc == SQLITE_OK else { throw StorageError.sqlite(rc) }
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func bindText(_ text: String, index: Int32) throws {
            let rc = text.utf8CString.withUnsafeBufferPointer {
                sqlite3_bind_text(stmt, index, $0.baseAddress, Int32($0.count - 1), transient)
            }
            guard rc == SQLITE_OK else { throw StorageError.sqlite(rc) }
        }
        try bindText(safeSource, index: 5)
        if let safeAttempt { try bindText(safeAttempt, index: 6) }
        else { guard sqlite3_bind_null(stmt, 6) == SQLITE_OK else { throw StorageError.sqlite(SQLITE_ERROR) } }
        let binds = [concurrentEdit ? Int64(1) : 0] + scope
        for (i, value) in binds.enumerated() {
            let rc = sqlite3_bind_int64(stmt, Int32(i + 7), value)
            guard rc == SQLITE_OK else { throw StorageError.sqlite(rc) }
        }
        guard sqlite3_bind_int64(stmt, 11, committedAt) == SQLITE_OK else { throw StorageError.sqlite(SQLITE_ERROR) }
        try bindText(["background","foreground","unknown"].contains(enqueueState) ? enqueueState : "unknown", index: 12)
        try bindText(["background","foreground","unknown"].contains(commitState) ? commitState : "unknown", index: 13)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw StorageError.sqlite(rc) }
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
        enqueueArchiveWork {
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
        enqueueArchiveWork {
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
        GoldgramHistoryStore.enqueueArchiveWork {
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
      AND (NULLIF(TRIM(COALESCE(m.original_text, '')), '') IS NOT NULL
             AND m.original_text != '[Содержимое не было получено]'
           OR EXISTS (SELECT 1 FROM revisions body WHERE body.peer_kind=m.peer_kind
             AND body.peer_id=m.peer_id AND body.message_id=m.message_id
             AND NULLIF(TRIM(body.content), '') IS NOT NULL
             AND body.content != '[Содержимое не было получено]'))
      -- #138: hide edit-only archive entries when no verified original was
      -- captured. Keep deletion entries with retained content, and do not
      -- modify stored revisions, missing-original counters, or diagnostics.
      AND (
          (m.original_observed = 1
           AND NULLIF(TRIM(COALESCE(m.original_text, '')), '') IS NOT NULL
           AND m.original_text != '[Содержимое не было получено]')
          OR m.is_deleted = 1
          OR EXISTS (SELECT 1 FROM events de
                     WHERE de.peer_kind=m.peer_kind AND de.peer_id=m.peer_id
                       AND de.message_id=m.message_id AND de.event_kind=2)
      )
      AND (m.is_deleted = 1 OR EXISTS (
           SELECT 1 FROM events e
           WHERE e.peer_kind = m.peer_kind AND e.peer_id = m.peer_id
             AND e.message_id = m.message_id AND (e.event_kind = 2 OR (e.event_kind = 1 AND (e.source IN ('goldgram_native_live_v2','goldgram_iphone8_bridge_v1') OR (e.source != 'goldgram_native_v1' AND e.server_time > 0 AND m.original_observed = 1 AND EXISTS (
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
            ORDER BY CASE WHEN r.content='[Содержимое не было получено]' THEN 1 ELSE 0 END ASC,
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
               AND e.message_id = m.message_id AND e.event_kind = 1 AND (e.source IN ('goldgram_native_live_v2','goldgram_iphone8_bridge_v1') OR (e.source != 'goldgram_native_v1' AND e.server_time > 0 AND m.original_observed = 1 AND EXISTS (
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
      AND (NULLIF(TRIM(COALESCE(m.original_text, '')), '') IS NOT NULL
             AND m.original_text != '[Содержимое не было получено]'
           OR EXISTS (SELECT 1 FROM revisions body WHERE body.peer_kind=m.peer_kind
             AND body.peer_id=m.peer_id AND body.message_id=m.message_id
             AND NULLIF(TRIM(body.content), '') IS NOT NULL
             AND body.content != '[Содержимое не было получено]'))
      -- #138: hide edit-only archive entries when no verified original was
      -- captured. Keep deletion entries with retained content, and do not
      -- modify stored revisions, missing-original counters, or diagnostics.
      AND (
          (m.original_observed = 1
           AND NULLIF(TRIM(COALESCE(m.original_text, '')), '') IS NOT NULL
           AND m.original_text != '[Содержимое не было получено]')
          OR m.is_deleted = 1
          OR EXISTS (SELECT 1 FROM events de
                     WHERE de.peer_kind=m.peer_kind AND de.peer_id=m.peer_id
                       AND de.message_id=m.message_id AND de.event_kind=2)
      )
      AND (m.is_deleted = 1 OR EXISTS (
           SELECT 1 FROM events e
           WHERE e.peer_kind = m.peer_kind AND e.peer_id = m.peer_id
             AND e.message_id = m.message_id AND (e.event_kind = 2 OR (e.event_kind = 1 AND (e.source IN ('goldgram_native_live_v2','goldgram_iphone8_bridge_v1') OR (e.source != 'goldgram_native_v1' AND e.server_time > 0 AND m.original_observed = 1 AND EXISTS (
               SELECT 1 FROM revisions vr WHERE vr.peer_kind=m.peer_kind AND vr.peer_id=m.peer_id
                 AND vr.message_id=m.message_id AND vr.content != m.original_text)))))))
    ORDER BY COALESCE(m.sent_at, m.last_seen_at) DESC, m.message_id DESC, m.peer_kind ASC, m.peer_id ASC
    LIMIT ? OFFSET ?;
    """

    // Deleted entries have a dedicated all-chat category. Apply this before
    // grouping and pagination so edited folders cannot contain empty pages.
    private static let editedOnlyPredicate = "AND m.is_deleted=0 AND NOT EXISTS (SELECT 1 FROM events de WHERE de.peer_kind=m.peer_kind AND de.peer_id=m.peer_id AND de.message_id=m.message_id AND de.event_kind=2) "

    static var countsSQL: String {
        let rows = messagesSQL.components(separatedBy: "ORDER BY COALESCE(m.sent_at, m.last_seen_at) DESC")[0]
            .replacingOccurrences(of: "WHERE m.peer_kind = ? AND m.peer_id = ?", with: "WHERE m.peer_kind IN (0,1,2,3)")
        return "SELECT COALESCE(SUM(edited),0), COALESCE(SUM(CASE WHEN is_deleted=1 OR delete_event=1 THEN 1 ELSE 0 END),0) FROM (\(rows));"
    }

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
              mode == "dialogs" || mode == "messages" || mode == "combined" || mode == "totals" || mode == "diagnostics" || (mode == "discussion_score" && peerId > 0 && scopedPeerKind == 2),
              offset >= 0, offset <= 5000,
              limit >= 1, limit <= 50,
              mode != "messages" ||
              (peerId > 0 && kinds.contains(scopedPeerKind)) else {
            completion(["status": "invalid_request", "items": []])
            return
        }
        let diagnosticSince = max(Int64(0), (request["since"] as? NSNumber)?.int64Value ?? 0)
        // #129 bounded geolocation window: SQL reads DISK contents, not a
        // claimed attribution to a specific CoreLocation callback.
        let geoSince = max(Int64(0), (request["geoSince"] as? NSNumber)?.int64Value ?? 0)
        let geoUntil = max(Int64(0), (request["geoUntil"] as? NSNumber)?.int64Value ?? 0)
        // Only accept bounded UUIDs from this same selected account/test.
        let attemptTokens = Array(Set((request["attemptTokens"] as? [String] ?? [])
            .filter { UUID(uuidString: $0) != nil })).prefix(24)
        GoldgramHistoryStore.enqueueArchiveWork {
            let response = self.read(
                accountId: accountId, mode: mode,
                kinds: kinds, peerId: peerId, peerKind: scopedPeerKind, sources: sources, deletedOnly: category == 3,
                offset: Int32(offset), limit: Int32(limit), diagnosticSince: diagnosticSince,
                geoSince: geoSince, geoUntil: geoUntil,
                attemptTokens: Array(attemptTokens)
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
        offset: Int32, limit: Int32, diagnosticSince: Int64,
        geoSince: Int64, geoUntil: Int64, attemptTokens: [String]
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

        if mode == "discussion_score" {
            let sql = """
            SELECT COUNT(*), COUNT(CASE WHEN a.committed_at < e.first_edit THEN 1 END)
            FROM (SELECT message_id, MIN(observed_at) AS first_edit FROM events
                  WHERE peer_kind=2 AND peer_id=? AND event_kind=1 GROUP BY message_id
                  HAVING MIN(observed_at)>=?) e
            LEFT JOIN original_capture_evidence a ON a.peer_kind=2 AND a.peer_id=? AND a.message_id=e.message_id
            """
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let stmt = pointer else {
                return ["status": "unavailable"]
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, peerId)
            sqlite3_bind_int64(stmt, 2, diagnosticSince)
            sqlite3_bind_int64(stmt, 3, peerId)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return ["status": "unavailable"] }
            return ["status": "ok", "edited": sqlite3_column_int64(stmt, 0), "before": sqlite3_column_int64(stmt, 1)]
        }
        if mode == "diagnostics" {
            // Read-only, parameter-bound aggregates of actual persisted rows.
            // This is an observational first_seen_at window, NOT evidence that
            // CoreLocation caused or durably flushed an original in that window.
            let diagnosticSQL = """
            SELECT COUNT(*),
                   COALESCE(SUM(CASE WHEN m.original_observed=1 AND m.original_text IS NOT NULL THEN 1 ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN m.original_observed=0 AND EXISTS
                     (SELECT 1 FROM events e WHERE e.peer_kind=m.peer_kind AND e.peer_id=m.peer_id
                        AND e.message_id=m.message_id AND e.event_kind=1) THEN 1 ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN EXISTS
                     (SELECT 1 FROM events e WHERE e.peer_kind=m.peer_kind AND e.peer_id=m.peer_id
                        AND e.message_id=m.message_id AND e.event_kind=1) THEN 1 ELSE 0 END), 0)
            FROM messages m WHERE m.first_seen_at >= ? AND m.first_seen_at < ?;
            """
            func readCounters(since: Int64, until: Int64) -> [String: Any]? {
                var pointer: OpaquePointer?
                guard sqlite3_prepare_v2(db, diagnosticSQL, -1, &pointer, nil) == SQLITE_OK,
                      let stmt = pointer else {
                    if let pointer { sqlite3_finalize(pointer) }
                    return nil
                }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_bind_int64(stmt, 1, since) == SQLITE_OK,
                      sqlite3_bind_int64(stmt, 2, until) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_ROW else {
                    return nil
                }
                return [
                    "observed": NSNumber(value: sqlite3_column_int64(stmt, 0)),
                    "known": NSNumber(value: sqlite3_column_int64(stmt, 1)),
                    "missingEdited": NSNumber(value: sqlite3_column_int64(stmt, 2)),
                    "edited": NSNumber(value: sqlite3_column_int64(stmt, 3))
                ]
            }
            guard var result = readCounters(since: diagnosticSince, until: Int64.max) else {
                return ["status": "unavailable", "items": []]
            }
            result["status"] = "ok"
            // #131 source/time evidence is created only for actual new
            // original commits after #131 installation. Old rows are unknown.
            // If the table has not yet been initialized, report unavailable.
            let evidenceSQL = """
            SELECT COUNT(*),
                COALESCE(SUM(CASE WHEN a.source='geo_sensor' THEN 1 ELSE 0 END),0),
                COALESCE(SUM(CASE WHEN a.source='geo_minimized' THEN 1 ELSE 0 END),0),
                COALESCE(SUM(CASE WHEN a.source='os_bg_refresh' THEN 1 ELSE 0 END),0),
                COALESCE(SUM(CASE WHEN a.source='live_update' THEN 1 ELSE 0 END),0),
                COALESCE(SUM(CASE WHEN a.source='notification_postbox' THEN 1 ELSE 0 END),0),
                COALESCE(SUM(CASE WHEN a.source='edit_with_before' THEN 1 ELSE 0 END),0),
                COALESCE(SUM(CASE WHEN a.edit_already_observed=0 AND EXISTS (
                    SELECT 1 FROM events e WHERE e.peer_kind=a.peer_kind AND e.peer_id=a.peer_id
                      AND e.message_id=a.message_id AND e.event_kind=1
                      AND e.observed_at > a.captured_at
                ) THEN 1 ELSE 0 END),0),
                COALESCE(SUM(CASE WHEN a.edit_already_observed=1 THEN 1 ELSE 0 END),0)
            FROM original_capture_evidence a
            WHERE a.captured_at >= ? AND a.captured_at < ?;
            """
            func evidence(since: Int64, until: Int64) -> [String: Any]? {
                var pointer: OpaquePointer?
                guard sqlite3_prepare_v2(db, evidenceSQL, -1, &pointer, nil) == SQLITE_OK,
                      let stmt = pointer else {
                    if let pointer { sqlite3_finalize(pointer) }
                    return nil
                }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_bind_int64(stmt, 1, since) == SQLITE_OK,
                      sqlite3_bind_int64(stmt, 2, until) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_ROW else { return nil }
                let keys = ["committed", "sensor", "minimized", "os", "live",
                            "notification", "withEdit", "beforeObservedEdit", "afterOrWithEdit"]
                var counts: [String: Any] = [:]
                for (index, key) in keys.enumerated() {
                    counts[key] = NSNumber(value: sqlite3_column_int64(stmt, Int32(index)))
                }
                return counts
            }
            if let audit = evidence(since: diagnosticSince, until: Int64.max) {
                result["evidence"] = audit
            }
            // #133: actual COMMIT state, never infer from queued timestamp.
            // NULL fields on earlier #131 captures are deliberately "unknown".
            let commitsSQL = """
            SELECT
                COUNT(*),
                COALESCE(SUM(CASE WHEN commit_state='background' THEN 1 ELSE 0 END),0),
                COALESCE(SUM(CASE WHEN commit_state='foreground' THEN 1 ELSE 0 END),0),
                COALESCE(SUM(CASE WHEN commit_state IS NULL OR commit_state='unknown' THEN 1 ELSE 0 END),0),
                COALESCE(SUM(CASE WHEN enqueue_state='background' AND commit_state='foreground' THEN 1 ELSE 0 END),0)
            FROM original_capture_evidence
            WHERE committed_at >= ? AND committed_at < ?;
            """
            func countCommitStates(since: Int64, until: Int64) -> [String: Any]? {
                var ptr: OpaquePointer?
                guard sqlite3_prepare_v2(db, commitsSQL, -1, &ptr, nil) == SQLITE_OK,
                      let stmt = ptr else {
                    if let ptr { sqlite3_finalize(ptr) }
                    return nil
                }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_bind_int64(stmt, 1, since) == SQLITE_OK,
                      sqlite3_bind_int64(stmt, 2, until) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_ROW else { return nil }
                let keys = ["total", "committedBg", "committedFg", "stateUnknown", "queuedBgCommittedFg"]
                var result: [String: Any] = [:]
                for (i, key) in keys.enumerated() {
                    result[key] = NSNumber(value: sqlite3_column_int64(stmt, Int32(i)))
                }
                return result
            }
            if let states = countCommitStates(since: diagnosticSince, until: Int64.max) {
                result["commitStates"] = states
            }
            // Link EACH edited message to its first recorded edit and
            // first-original evidence via primary key, returning AGGREGATES
            // only. No message IDs/content cross the UI boundary.
            let editedSQL = """
            WITH recent AS (
                SELECT DISTINCT peer_kind,peer_id,message_id
                FROM events WHERE event_kind=1 AND observed_at>=? AND observed_at<?
            ), edited AS (
                SELECT r.peer_kind,r.peer_id,r.message_id,
                  (SELECT MIN(e.observed_at) FROM events e
                   WHERE e.peer_kind=r.peer_kind AND e.peer_id=r.peer_id
                     AND e.message_id=r.message_id AND e.event_kind=1) AS first_edit_at
                FROM recent r
            )
            SELECT COUNT(*),
               COALESCE(SUM(CASE WHEN m.original_observed=1 AND m.original_text IS NOT NULL THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN a.committed_at IS NOT NULL AND a.committed_at < e.first_edit_at THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN a.committed_at IS NOT NULL AND a.committed_at >= e.first_edit_at THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN m.original_observed=1 AND a.committed_at IS NULL THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN m.original_observed=0 OR m.original_text IS NULL THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN a.committed_at<e.first_edit_at AND a.commit_state='background' THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN a.committed_at<e.first_edit_at AND a.commit_state='foreground' THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN a.committed_at<e.first_edit_at AND a.source='geo_sensor' THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN a.committed_at<e.first_edit_at AND a.source='geo_minimized' THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN a.committed_at<e.first_edit_at AND a.source='os_bg_refresh' THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN a.committed_at<e.first_edit_at AND a.source='live_update' THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN a.committed_at<e.first_edit_at AND a.source='history_snapshot' THEN 1 ELSE 0 END),0),
               -- #135: missing-original triage is strictly a local observation,
               -- NOT proof of the server's historical edit time.
               COALESCE(SUM(CASE WHEN (m.original_observed=0 OR m.original_text IS NULL)
                    AND m.first_seen_at BETWEEN e.first_edit_at-2000 AND e.first_edit_at+2000
                    THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN (m.original_observed=0 OR m.original_text IS NULL)
                    AND m.first_seen_at < e.first_edit_at-2000 THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN (m.original_observed=0 OR m.original_text IS NULL)
                    AND m.first_seen_at > e.first_edit_at+2000 THEN 1 ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN a.committed_at<e.first_edit_at
                    AND a.source NOT IN ('geo_sensor','geo_minimized','os_bg_refresh',
                                         'live_update','history_snapshot') THEN 1 ELSE 0 END),0)
            FROM edited e
            JOIN messages m USING(peer_kind,peer_id,message_id)
            LEFT JOIN original_capture_evidence a USING(peer_kind,peer_id,message_id);
            """
            func editedEvidence(since: Int64, until: Int64) -> [String: Any]? {
                var ptr: OpaquePointer?
                guard sqlite3_prepare_v2(db, editedSQL, -1, &ptr, nil) == SQLITE_OK,
                      let stmt = ptr else {
                    if let ptr { sqlite3_finalize(ptr) }
                    return nil
                }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_bind_int64(stmt, 1, since) == SQLITE_OK,
                      sqlite3_bind_int64(stmt, 2, until) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_ROW else { return nil }
                let keys = ["edited", "originalKnown", "provenBefore", "committedAfter",
                            "unattributedKnown", "missingOriginal", "beforeBg", "beforeFg", "fromGeoSensor",
                            "fromMinimized", "fromOS", "fromLive", "fromHistory",
                            "missingFirstSeenAtEdit", "missingSeenEarlier", "missingSeenLater",
                            "beforeOtherSource"]
                var result: [String: Any] = [:]
                for (i,key) in keys.enumerated() {
                    result[key] = NSNumber(value: sqlite3_column_int64(stmt, Int32(i)))
                }
                return result
            }
            if let joined = editedEvidence(since: diagnosticSince, until: Int64.max) {
                result["editedEvidence"] = joined
            }
            // Per-attempt counts represent PROCESSED SQLite writes, not just
            // API messages or enqueued payloads. Missing counts are unresolved.
            var attempts: [[String: Any]] = []
            let attemptsSQL = """
            SELECT processed,new_committed,already_present,failed
            FROM original_capture_attempts WHERE attempt_token=?;
            """
            for token in attemptTokens {
                var ptr: OpaquePointer?
                guard sqlite3_prepare_v2(db, attemptsSQL, -1, &ptr, nil) == SQLITE_OK,
                      let stmt = ptr else {
                    if let ptr { sqlite3_finalize(ptr) }
                    continue
                }
                defer { sqlite3_finalize(stmt) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                let bound = token.utf8CString.withUnsafeBufferPointer {
                    sqlite3_bind_text(stmt, 1, $0.baseAddress, Int32($0.count-1), transient)
                }
                if bound == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
                    attempts.append([
                        "token": token,
                        "processed": NSNumber(value: sqlite3_column_int64(stmt, 0)),
                        "newCommitted": NSNumber(value: sqlite3_column_int64(stmt, 1)),
                        "alreadyKnown": NSNumber(value: sqlite3_column_int64(stmt, 2)),
                        "failed": NSNumber(value: sqlite3_column_int64(stmt, 3))
                    ])
                }
            }
            result["attemptOutcomes"] = attempts
            // 30-minute experiment plus small latitude for manual-stop tests.
            if geoSince > 0, geoUntil > geoSince,
               geoUntil - geoSince <= 2 * 60 * 60 * 1000,
               let window = readCounters(since: geoSince, until: geoUntil) {
                result["geoObserved"] = window["observed"]
                result["geoKnown"] = window["known"]
                result["geoMissingEdited"] = window["missingEdited"]
                result["geoEdited"] = window["edited"]
                if let audit = evidence(since: geoSince, until: geoUntil) {
                    result["geoEvidence"] = audit
                }
                if let states = countCommitStates(since: geoSince, until: geoUntil) {
                    result["geoCommitStates"] = states
                }
                if let joined = editedEvidence(since: geoSince, until: geoUntil) {
                    result["geoEditedEvidence"] = joined
                }
                // #135: 5-minute COMMIT buckets, bounded to the consented
                // 30-minute geo window. No peer IDs, texts or coordinates.
                let geoBucketsSQL = """
                SELECT ((committed_at - ?)/300000), COUNT(*),
                    COALESCE(SUM(CASE WHEN commit_state='background' THEN 1 ELSE 0 END),0),
                    COALESCE(SUM(CASE WHEN source='geo_sensor' THEN 1 ELSE 0 END),0),
                    COALESCE(SUM(CASE WHEN source='geo_minimized' THEN 1 ELSE 0 END),0),
                    COALESCE(SUM(CASE WHEN source='live_update' THEN 1 ELSE 0 END),0)
                FROM original_capture_evidence
                WHERE committed_at >= ? AND committed_at < ?
                GROUP BY 1 ORDER BY 1 LIMIT 6;
                """
                var geoStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, geoBucketsSQL, -1, &geoStmt, nil) == SQLITE_OK,
                   let stmt = geoStmt {
                    defer { sqlite3_finalize(stmt) }
                    if sqlite3_bind_int64(stmt, 1, geoSince) == SQLITE_OK,
                       sqlite3_bind_int64(stmt, 2, geoSince) == SQLITE_OK,
                       sqlite3_bind_int64(stmt, 3, geoUntil) == SQLITE_OK {
                        var buckets: [[String: Any]] = []
                        while sqlite3_step(stmt) == SQLITE_ROW {
                            let slot = sqlite3_column_int64(stmt, 0)
                            guard (0...5).contains(slot) else { continue }
                            buckets.append([
                                "slot": NSNumber(value: slot),
                                "total": NSNumber(value: sqlite3_column_int64(stmt, 1)),
                                "background": NSNumber(value: sqlite3_column_int64(stmt, 2)),
                                "sensor": NSNumber(value: sqlite3_column_int64(stmt, 3)),
                                "minimized": NSNumber(value: sqlite3_column_int64(stmt, 4)),
                                "live": NSNumber(value: sqlite3_column_int64(stmt, 5))
                            ])
                        }
                        result["geoBuckets"] = buckets
                    }
                } else if let geoStmt { sqlite3_finalize(geoStmt) }
            }
            return result
        }

        var sql = mode == "totals" ? countsSQL : mode == "dialogs" ? dialogsSQL : messagesSQL
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
        if !deletedOnly && mode != "totals" {
            let anchor = mode == "dialogs" ? "GROUP BY d.peer_kind" : "ORDER BY COALESCE(m.sent_at, m.last_seen_at) DESC"
            sql = sql.replacingOccurrences(of: anchor, with: editedOnlyPredicate + anchor)
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
        let parameters: [Int64] = mode == "totals" ? [] : scope + [Int64(limit), Int64(offset)]
        for (index, value) in parameters.enumerated() {
            guard sqlite3_bind_int64(stmt, Int32(index + 1), value) == SQLITE_OK else {
                return ["status": "unavailable", "items": []]
            }
        }

        if mode == "totals" {
            guard sqlite3_step(stmt) == SQLITE_ROW else { return ["status": "unavailable", "items": []] }
            return ["status": "ok", "edited": NSNumber(value: sqlite3_column_int64(stmt, 0)), "deleted": NSNumber(value: sqlite3_column_int64(stmt, 1))]
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
fileprivate extension GoldgramHistoryStore {
    static var nativeWriteFailed = false

    private static var pendingDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoldgramPendingOriginals", isDirectory: true)
    }

    // An original arriving after admission closes can outlive the process.
    // The first body for its account/peer/message wins, just as in SQLite.
    private static func stageOriginal(_ payload: [String: Any], key: String, observed: Int64) throws -> URL {
        let directory = pendingDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(key).appendingPathExtension("pending")
        if !FileManager.default.fileExists(atPath: url.path) {
            var entry = payload
            entry["pendingObservedAt"] = observed
            let data = try JSONSerialization.data(withJSONObject: entry)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        }
        return url
    }

    private static func restoreDeferredOriginals() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: pendingDirectory,
            includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "pending" {
            guard archiveIsOpen else { return }
            guard let data = try? Data(contentsOf: file),
                  var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            // Repair only the baseline when a newer edit is already committed.
            payload["baselineOnly"] = true
            payload["originalText"] = payload["originalText"] ?? payload["text"]
            _ = nativeEvent(payload, replayFile: file)
        }
    }

    static func nativeEvent(_ payload: [String: Any], replayFile: URL? = nil) -> Bool {
        guard let account = (payload["accountId"] as? NSNumber)?.int64Value, account > 0,
              let kind = (payload["peerKind"] as? NSNumber)?.int32Value,
              let peer = (payload["peerId"] as? NSNumber)?.int64Value,
              let rawId = (payload["messageId"] as? NSNumber)?.int64Value,
              let id = Int32(exactly: rawId), id > 0,
              let event = (payload["eventKind"] as? NSNumber)?.int32Value, (0...2).contains(event),
              UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled") else { return false }
        let now = (replayFile == nil ? nil : (payload["pendingObservedAt"] as? NSNumber)?.int64Value)
            ?? Int64(Date().timeIntervalSince1970 * 1000)
        if kind == -1 && peer == 0 && event == 2 {
            enqueueArchiveWork {
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
        let original = payload["originalText"] as? String
        let baselineOnly = payload["baselineOnly"] as? Bool == true
        guard original == nil || (known && original!.utf8.count <= 65536),
              !baselineOnly || (event == 0 && known && original != nil) else { return false }
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
        let enqueueState = lifecycleState()
        let key = event == 2 ? "native.delete.\(kind).\(peer).\(id)" : "native.edit.\(kind).\(peer).\(id).\(hash)"
        let write: (URL?) -> Void = { pendingFile in
            do {
                let db = try archiveConnection(for: account)
                try archiveSQL("BEGIN IMMEDIATE;", db: db, ints: [])
                do {
                    let scope = [Int64(kind), peer, Int64(id)]
                    let alreadyKnown = try originalIsKnown(db: db, scope: scope)
                    try archiveSQL("INSERT OR IGNORE INTO dialogs(peer_kind,peer_id) VALUES(?,?);", db: db, ints: [Int64(kind),peer])
                    let baseline = original ?? before ?? (event != 1 ? content : nil)
                    try archiveSQL("INSERT OR IGNORE INTO messages(peer_kind,peer_id,message_id,first_seen_at,last_seen_at,original_observed,original_text) VALUES(?,?,?,?,?,?,?);", db: db, ints: scope + [now,now,known ? 1 : 0], text: known ? baseline : nil)
                    if known, let baseline {
                        try archiveSQL("UPDATE messages SET original_observed=1, original_text=?4 WHERE peer_kind=?1 AND peer_id=?2 AND message_id=?3 AND original_observed=0;", db: db, ints: scope, text: baseline)
                        if !alreadyKnown {
                            // First-baseline audit shares the COMMIT with the original.
                            // A baseline supplied with an edit is NOT evidence
                            // that the client had it before the server edit.
                            let source = event == 1 ? "edit_with_before" :
                                ((payload["evidenceSource"] as? String) ?? "native_unclassified")
                            try recordFirstOriginalEvidence(db: db, scope: scope,
                                at: now, source: source,
                                attempt: payload["evidenceAttempt"] as? String,
                                concurrentEdit: event == 1,
                                committedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                enqueueState: enqueueState, commitState: lifecycleState())
                        }
                    }
                    try archiveSQL("UPDATE messages SET sender_kind=COALESCE(sender_kind,CASE WHEN ?4 BETWEEN 0 AND 3 THEN ?4 ELSE NULL END),sender_id=COALESCE(sender_id,NULLIF(?5,0)),sent_at=COALESCE(sent_at,NULLIF(?6,0)),thread_id=COALESCE(thread_id,NULLIF(?7,0)),last_seen_at=MAX(last_seen_at,?8),is_deleted=MAX(is_deleted,?9) WHERE peer_kind=?1 AND peer_id=?2 AND message_id=?3;", db: db, ints: scope + [senderKind,sender,sent,thread,now,event == 2 ? 1 : 0])
                    if try lastSavedRevision(db: db, peerId: peer, messageId: id, peerKind: kind) == nil, let baseline {
                        try archiveSQL("INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,observed_at,revision_provenance,content) VALUES(?,?,?,0,?,?,?);", db: db, ints: scope + [now,known ? 1 : 2], text: baseline)
                    }
                    let last = try lastSavedRevision(db: db, peerId: peer, messageId: id, peerKind: kind)
                    // A delete receipt with no native body must never replace
                    // text already saved by an earlier observation in SQLite.
                    let hasContent = !baselineOnly && (event != 2 || retained)
                    if hasContent && last?.text != content {
                        guard last?.index != Int64.max else { throw StorageError.sqlite(SQLITE_TOOBIG) }
                        try archiveSQL("INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,observed_at,server_edit_at,revision_provenance,content) VALUES(?,?,?,?,?,NULLIF(?,0),3,?);", db: db, ints: scope + [(last?.index ?? -1)+1,now,edited], text: content)
                    }
                    let source = event == 2 && retained ? "goldgram_native_retained_v1" : event == 1 ? "goldgram_native_live_v2" : "goldgram_native_v1"
                    // source is a fixed enum above, never a user-supplied SQL fragment.
                    if event != 0 {
                        try archiveSQL("INSERT OR IGNORE INTO events(peer_kind,peer_id,message_id,event_kind,source,server_time,observed_at,event_key) VALUES(?,?,?,?, '\(source)',NULLIF(?,0),?,?);", db: db, ints: scope + [Int64(event),edited,now], text: key)
                    }
                    if event == 0 && known && baseline != nil {
                        try recordAttempt(db: db, token: payload["evidenceAttempt"] as? String,
                            source: payload["evidenceSource"] as? String ?? "geo_unclassified",
                            outcome: alreadyKnown ? "existing" : "new")
                    }
                    try archiveSQL("COMMIT;", db: db, ints: [])
                    if let pendingFile { try? FileManager.default.removeItem(at: pendingFile) }
                    if event != 0 { DispatchQueue.main.async { NotificationCenter.default.post(name: Notification.Name("GoldgramArchiveChanged"), object: NSNumber(value: account)) } }
                } catch {
                    try? archiveSQL("ROLLBACK;", db: db, ints: [])
                    // Failed writes are best-effort diagnostics after rollback.
                    // If the DB is unavailable the client shows unresolved
                    // accepted writes, never mislabels them as committed.
                    if event == 0 {
                        try? recordAttempt(db: db, token: payload["evidenceAttempt"] as? String,
                            source: payload["evidenceSource"] as? String ?? "geo_unclassified",
                            outcome: "failed")
                    }
                    throw error
                }
            } catch { nativeWriteFailed = true /* Keep the durable extension handoff for retry. */ }
        }
        if let replayFile {
            // Called exclusively by restoreDeferredOriginals on storageQueue.
            if archiveIsOpen { write(replayFile) }
        } else {
            storageQueue.async {
                if archiveIsOpen { write(nil); return }
                if event == 0 && known {
                    do {
                        let file = try stageOriginal(payload, key: "\(account)_\(kind)_\(peer)_\(id)", observed: now)
                        deferred.append { write(file) }
                        return
                    } catch { nativeWriteFailed = true }
                }
                deferred.append { write(nil) }
            }
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

// Notification events are committed before their Postbox handoff is removed.
// #136: cheap read-only first-original check before costly geo history replay.
// 1 = confirmed committed original, 0 = absent, -1 = unavailable/unknown.
// Unknown must NEVER be treated as proof that the original exists.
@_cdecl("goldgram_has_original_v1")
public func goldgramHasOriginalV1(_ account: Int64, _ kind: Int32, _ peer: Int64, _ id: Int32) -> Int32 {
    guard account > 0, (0...3).contains(kind), peer > 0, id > 0 else { return -1 }
    return GoldgramHistoryStore.storageQueue.sync {
        guard GoldgramHistoryStore.archiveIsOpen, let db = try? GoldgramHistoryStore.archiveConnection(for: account),
              let known = try? GoldgramHistoryStore.originalIsKnown(db: db,
                  scope: [Int64(kind), peer, Int64(id)]) else { return -1 }
        return known ? 1 : 0
    }
}

@_cdecl("goldgram_flush_capture_v1")
public func goldgramFlushCaptureV1() -> Int32 {
    return GoldgramHistoryStore.storageQueue.sync {
        guard GoldgramHistoryStore.archiveIsOpen else { return 0 }
        let failed = GoldgramHistoryStore.nativeWriteFailed
        GoldgramHistoryStore.nativeWriteFailed = false
        return failed ? 0 : 1
    }
}

// Only a positively observed original may repair inline history after eviction.
// The caller owns the returned JSON buffer and releases it with free().
@_cdecl("goldgram_read_original_v1")
public func goldgramReadOriginalV1(_ account: Int64, _ kind: Int32, _ peer: Int64, _ id: Int32) -> UnsafeMutablePointer<CChar>? {
    guard account > 0, (0...3).contains(kind), peer > 0, id > 0 else { return nil }
    return GoldgramHistoryStore.storageQueue.sync {
        guard GoldgramHistoryStore.archiveIsOpen, let db = try? GoldgramHistoryStore.archiveConnection(for: account) else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT original_text FROM messages WHERE peer_kind=? AND peer_id=? AND message_id=? AND original_observed=1 AND original_text IS NOT NULL;", -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            if let statement { sqlite3_finalize(statement) }; return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, kind); sqlite3_bind_int64(stmt, 2, peer); sqlite3_bind_int(stmt, 3, id)
        guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_text(stmt, 0) else { return nil }
        let text = String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(stmt, 0))), as: UTF8.self)
        guard let data = try? JSONSerialization.data(withJSONObject: ["text": text]), let json = String(data: data, encoding: .utf8) else { return nil }
        return strdup(json)
    }
}


@_cdecl("goldgram_archive_admission_v1")
public func goldgramArchiveAdmissionV1(_ open: Int32) {
    GoldgramHistoryStore.setAdmission(open > 0, immediate: open < 0)
}

@_cdecl("goldgram_archive_barrier_v1")
public func goldgramArchiveBarrierV1(_ context: UnsafeMutableRawPointer,
                                     _ done: @escaping @convention(c) (UnsafeMutableRawPointer) -> Void) {
    GoldgramHistoryStore.storageQueue.async { done(context) }
}


// Goldgram Bridge Smart Merge V2 (base #187).
// All mutations share storageQueue + the existing per-account SQLite transaction.
// Inbox/receipts are ADDITIVE TABLES in that same DB, not a second database.
// v1 snapshots lack edit chronology; never invent intermediate edit order.
private enum GoldgramPhone8Bridge {
    private static func bind(_ value: String, to stmt: OpaquePointer, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let rc = value.utf8CString.withUnsafeBufferPointer { chars in
            sqlite3_bind_text(stmt, index, chars.baseAddress,
                              Int32(chars.count - 1), transient)
        }
        guard rc == SQLITE_OK else { throw GoldgramHistoryStore.StorageError.sqlite(rc) }
    }

    private static func receiptStatus(db: OpaquePointer, key: String) throws -> String? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db,
            "SELECT status FROM bridge_merge_receipts_v2 WHERE event_key=? LIMIT 1;",
            -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw GoldgramHistoryStore.StorageError.sqlite(rc)
        }
        defer { sqlite3_finalize(stmt) }
        try bind(key, to: stmt, at: 1)
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else {
            throw GoldgramHistoryStore.StorageError.sqlite(step)
        }
        return String(cString: raw)
    }

    private static func saveReceipt(db: OpaquePointer, key: String, status: String,
                                    payload: String?) throws {
        guard ["applied", "already_present", "pending"].contains(status) else {
            throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_MISUSE)
        }
        let sql = """
        INSERT INTO bridge_merge_receipts_v2(event_key,status,payload,updated_at)
        VALUES(?,?,?,?)
        ON CONFLICT(event_key) DO UPDATE SET
           status=excluded.status,payload=excluded.payload,updated_at=excluded.updated_at;
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw GoldgramHistoryStore.StorageError.sqlite(rc)
        }
        defer { sqlite3_finalize(stmt) }
        try bind(key, to: stmt, at: 1)
        try bind(status, to: stmt, at: 2)
        if let payload { try bind(payload, to: stmt, at: 3) }
        else {
            guard sqlite3_bind_null(stmt, 3) == SQLITE_OK else {
                throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_ERROR)
            }
        }
        guard sqlite3_bind_int64(stmt, 4, Int64(Date().timeIntervalSince1970 * 1000)) == SQLITE_OK
        else { throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_ERROR) }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE else {
            throw GoldgramHistoryStore.StorageError.sqlite(step)
        }
    }

    // A source edit older than the first local observation cannot certify
    // the claimed original. Hold the entire message scope for manual chronology
    // reconciliation without inserting any misleading original/revision.
    private static func holdChronology(db: OpaquePointer, scope: [Int64],
                                       first: Int64, eventKey: String) throws {
        try GoldgramHistoryStore.archiveSQL(
            "INSERT OR IGNORE INTO bridge_chronology_holds_v1(peer_kind,peer_id,message_id,first_seen_at,event_key) VALUES(?,?,?,?,?);",
            db: db, ints: scope + [first], text: eventKey)
    }

    private static func isChronologyHeld(db: OpaquePointer, scope: [Int64]) throws -> Bool {
        var ptr: OpaquePointer?
        let sql = "SELECT 1 FROM bridge_chronology_holds_v1 WHERE peer_kind=? AND peer_id=? AND message_id=? LIMIT 1;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &ptr, nil)
        guard rc == SQLITE_OK, let stmt = ptr else {
            if let ptr { sqlite3_finalize(ptr) }
            throw GoldgramHistoryStore.StorageError.sqlite(rc)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in scope.enumerated() {
            guard sqlite3_bind_int64(stmt, Int32(i + 1), value) == SQLITE_OK else {
                throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_ERROR)
            }
        }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW || step == SQLITE_DONE else {
            throw GoldgramHistoryStore.StorageError.sqlite(step)
        }
        return step == SQLITE_ROW
    }

    private static func originalInArchive(db: OpaquePointer, scope: [Int64]) throws -> String? {
        var stmt: OpaquePointer?
        let sql = "SELECT original_text FROM messages WHERE peer_kind=? AND peer_id=? AND message_id=? AND original_observed=1 LIMIT 1;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw GoldgramHistoryStore.StorageError.sqlite(rc)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, id) in scope.enumerated() {
            guard sqlite3_bind_int64(stmt, Int32(i+1), id) == SQLITE_OK else {
                throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_ERROR)
            }
        }
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw GoldgramHistoryStore.StorageError.sqlite(step)
        }
        guard let raw = sqlite3_column_text(stmt, 0) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: raw,
            count: Int(sqlite3_column_bytes(stmt, 0))), as: UTF8.self)
    }

    // Last revision and its trustworthy SERVER edit time (not import time).
    private static func lastRevisionTime(db: OpaquePointer, scope: [Int64]) throws -> Int64? {
        var stmt: OpaquePointer?
        let sql = "SELECT server_edit_at FROM revisions WHERE peer_kind=? AND peer_id=? AND message_id=? ORDER BY version_index DESC LIMIT 1;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw GoldgramHistoryStore.StorageError.sqlite(rc)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, id) in scope.enumerated() {
            guard sqlite3_bind_int64(stmt, Int32(i+1), id) == SQLITE_OK else {
                throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_ERROR)
            }
        }
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw GoldgramHistoryStore.StorageError.sqlite(step)
        }
        return sqlite3_column_type(stmt, 0) == SQLITE_NULL
            ? nil : sqlite3_column_int64(stmt, 0)
    }

    private static func hasEdit(db: OpaquePointer, scope: [Int64]) throws -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM events WHERE peer_kind=? AND peer_id=? AND message_id=? AND event_kind=1 LIMIT 1;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw GoldgramHistoryStore.StorageError.sqlite(rc)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, id) in scope.enumerated() {
            guard sqlite3_bind_int64(stmt, Int32(i+1), id) == SQLITE_OK else {
                throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_ERROR)
            }
        }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw GoldgramHistoryStore.StorageError.sqlite(step)
        }
        return step == SQLITE_ROW
    }


    private static func containsRevision(db: OpaquePointer, scope: [Int64],
                                         content: String) throws -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM revisions WHERE peer_kind=? AND peer_id=? AND message_id=? AND content=? LIMIT 1;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw GoldgramHistoryStore.StorageError.sqlite(rc)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in scope.enumerated() {
            guard sqlite3_bind_int64(stmt, Int32(i + 1), value) == SQLITE_OK else {
                throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_ERROR)
            }
        }
        try bind(content, to: stmt, at: 4)
        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw GoldgramHistoryStore.StorageError.sqlite(step)
        }
        return step == SQLITE_ROW
    }

    private static func hasEventKey(db: OpaquePointer, key: String) throws -> Bool {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db,
            "SELECT 1 FROM events WHERE event_key=? LIMIT 1;", -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw GoldgramHistoryStore.StorageError.sqlite(rc)
        }
        defer { sqlite3_finalize(stmt) }
        try bind(key, to: stmt, at: 1)
        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw GoldgramHistoryStore.StorageError.sqlite(step)
        }
        return step == SQLITE_ROW
    }


    private static func importDelete(_ row: [String: Any], db: OpaquePointer,
                                     now: Int64, parse: (String) -> Date?) throws -> String {
        guard row["source"] as? String == "iphone8_telethon",
              row["record_kind"] as? String == "delete",
              let kindText = row["peer_kind"] as? String,
              let chat = row["chat_id"] as? String,
              let message = row["message_id"] as? String,
              let mid = Int32(message), mid > 0,
              let token = row["edit_event_id"] as? String,
              token.hasPrefix("delete:"), token.utf8.count <= 128,
              let atText = row["event_observed_at"] as? String,
              let atDate = parse(atText) else { return "invalid" }
        let at = Int64(atDate.timeIntervalSince1970 * 1000)
        guard at > 0, at <= now + 300000 else { return "invalid" }
        let peerId: Int64
        let peerKind: Int32
        if kindText == "PeerUser", let id = Int64(chat), id > 0 {
            peerId = id
            peerKind = 0
        } else if kindText == "PeerChannel", chat.hasPrefix("-100"),
                  let id = Int64(chat.dropFirst(4)), id > 0 {
            peerId = id
            var ptr: OpaquePointer?
            let sql = "SELECT peer_kind FROM dialogs WHERE peer_id=? AND peer_kind IN (2,3) LIMIT 2;"
            let rc = sqlite3_prepare_v2(db, sql, -1, &ptr, nil)
            guard rc == SQLITE_OK, let stmt = ptr else {
                if let ptr { sqlite3_finalize(ptr) }
                throw GoldgramHistoryStore.StorageError.sqlite(rc)
            }
            sqlite3_bind_int64(stmt, 1, peerId)
            var kinds: [Int32] = []
            var step = sqlite3_step(stmt)
            while step == SQLITE_ROW {
                kinds.append(sqlite3_column_int(stmt, 0))
                step = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            guard step == SQLITE_DONE else {
                throw GoldgramHistoryStore.StorageError.sqlite(step)
            }
            guard kinds.count == 1 else { return "unknownChannels" }
            peerKind = kinds[0]
        } else {
            return "invalid"
        }
        let scope: [Int64] = [Int64(peerKind), peerId, Int64(mid)]
        // This ID is per original deletion event, not a message-wide cursor.
        let identity = "\(peerKind):\(peerId):\(mid):\(token)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let key = "iphone8.delete.v2.\(digest)"
        if let status = try receiptStatus(db: db, key: key),
           status == "applied" || status == "already_present" {
            return "duplicates"
        }
        let original = (row["original_text"] as? String) ?? ""
        let atFirst: Int64
        if let raw = row["first_seen_at"] as? String, let first = parse(raw) {
            atFirst = Int64(first.timeIntervalSince1970 * 1000)
        } else {
            atFirst = at
        }
        // Deletions remain useful even for a held message, but they must not
        // promote a potentially post-edit text to "verified original".
        let held = try isChronologyHeld(db: db, scope: scope)
        let safeOriginal = !held &&
            !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            original != "[Содержимое не было получено]" &&
            original.utf8.count <= 65536 && atFirst > 0 && atFirst <= at
        let knownOriginal = try originalInArchive(db: db, scope: scope)
        if safeOriginal && knownOriginal != nil && knownOriginal != original {
            let packet = String(data: try JSONSerialization.data(
                withJSONObject: row, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
            try saveReceipt(db: db, key: key, status: "pending", payload: packet)
            return "pending"
        }
        try GoldgramHistoryStore.archiveSQL(
            "INSERT OR IGNORE INTO dialogs(peer_kind,peer_id) VALUES(?,?);",
            db: db, ints: [Int64(peerKind), peerId])
        // Unknown originals are *not* declared verified. The native collector
        // may fill this placeholder if the original is independently observed.
        try GoldgramHistoryStore.archiveSQL(
            "INSERT OR IGNORE INTO messages(peer_kind,peer_id,message_id,first_seen_at,last_seen_at,original_observed,capture_provenance,is_deleted) VALUES(?,?,?,?,?,0,0,1);",
            db: db, ints: scope + [atFirst, now])
        if safeOriginal && knownOriginal == nil {
            try GoldgramHistoryStore.archiveSQL(
                "UPDATE messages SET original_text=?4,original_observed=1,capture_provenance=CASE WHEN capture_provenance=0 THEN 3 ELSE capture_provenance END WHERE peer_kind=?1 AND peer_id=?2 AND message_id=?3 AND original_observed=0;",
                db: db, ints: scope, text: original)
            try GoldgramHistoryStore.recordFirstOriginalEvidence(
                db: db, scope: scope, at: atFirst, source: "iphone8_telethon_initial_v1",
                attempt: nil, concurrentEdit: false, committedAt: now,
                enqueueState: "unknown", commitState: "unknown")
        }
        let duplicate = try existsDelete(db: db, scope: scope)
        try GoldgramHistoryStore.archiveSQL(
            "UPDATE messages SET is_deleted=1,last_seen_at=MAX(last_seen_at,?) WHERE peer_kind=? AND peer_id=? AND message_id=?;",
            db: db, ints: [now] + scope)
        if duplicate {
            try saveReceipt(db: db, key: key, status: "already_present", payload: nil)
            return "duplicates"
        }
        // archiveSQL(_:ints:text:) binds text at the LAST placeholder.
        try GoldgramHistoryStore.archiveSQL(
            "INSERT OR IGNORE INTO events(peer_kind,peer_id,message_id,event_kind,source,server_time,observed_at,event_key) VALUES(?,?,?,2,'goldgram_iphone8_bridge_v1',NULL,?,?);",
            db: db, ints: scope + [at], text: key)
        try saveReceipt(db: db, key: key, status: "applied", payload: nil)
        return "deletions"
    }

    private static func existsDelete(db: OpaquePointer, scope: [Int64]) throws -> Bool {
        var ptr: OpaquePointer?
        let sql = "SELECT 1 FROM events WHERE peer_kind=? AND peer_id=? AND message_id=? AND event_kind=2 LIMIT 1;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &ptr, nil)
        guard rc == SQLITE_OK, let stmt = ptr else {
            if let ptr { sqlite3_finalize(ptr) }
            throw GoldgramHistoryStore.StorageError.sqlite(rc)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in scope.enumerated() {
            guard sqlite3_bind_int64(stmt, Int32(i + 1), value) == SQLITE_OK else {
                throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_ERROR)
            }
        }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW || step == SQLITE_DONE else {
            throw GoldgramHistoryStore.StorageError.sqlite(step)
        }
        return step == SQLITE_ROW
    }

    static func importBundle(_ data: Data, accountId: Int64,
                             completion: @escaping ([String: Int]) -> Void) {
        func finish(_ result: [String: Int]) {
            DispatchQueue.main.async { completion(result) }
        }
        guard data.count <= 1_000_000, accountId > 0,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let format = payload["format"] as? String,
              ["goldgram_bridge_test_v1", "goldgram_bridge_v2"].contains(format),
              let rows = payload["records"] as? [[String: Any]],
              !rows.isEmpty, rows.count <= 50 else {
            finish(["invalid": 1]); return
        }
        // Never import into a different account even for otherwise valid rows.
        guard rows.allSatisfy({ ($0["account_id"] as? String).flatMap(Int64.init) == accountId }) else {
            finish(["wrongAccount": 1]); return
        }
        GoldgramHistoryStore.enqueueArchiveWork {
            guard GoldgramArchiveReader.activeAccountId()?.int64Value == accountId,
                  UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled"),
                  GoldgramHistoryStore.archiveIsOpen else {
                finish(["disabled": 1]); return
            }
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX")
            date.timeZone = TimeZone(secondsFromGMT: 0)
            date.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // Telegram server_edit_at often has whole-second precision,
            // unlike the microsecond-precision local observed_at timestamp.
            let isoWholeSeconds = ISO8601DateFormatter()
            isoWholeSeconds.formatOptions = [.withInternetDateTime]
            func parse(_ value: String) -> Date? {
                date.date(from: value) ??
                    iso.date(from: value) ??
                    isoWholeSeconds.date(from: value)
            }
            var counts = ["imported": 0, "edits": 0, "deletions": 0,
                          "duplicates": 0, "unknownChannels": 0, "conflicts": 0,
                          "pending": 0, "chronologyPending": 0, "invalid": 0]
            do {
                let db = try GoldgramHistoryStore.archiveConnection(for: accountId)
                try GoldgramHistoryStore.archiveSQL("BEGIN IMMEDIATE;", db: db, ints: [])
                do {
                    try GoldgramHistoryStore.archiveSQL("""
                    CREATE TABLE IF NOT EXISTS bridge_merge_receipts_v2 (
                        event_key TEXT PRIMARY KEY,
                        status TEXT NOT NULL CHECK(status IN ('applied','already_present','pending')),
                        payload TEXT,
                        updated_at INTEGER NOT NULL
                    );
                    """, db: db, ints: [])
                    try GoldgramHistoryStore.archiveSQL("""
                    CREATE TABLE IF NOT EXISTS bridge_chronology_holds_v1 (
                        peer_kind INTEGER NOT NULL,
                        peer_id INTEGER NOT NULL,
                        message_id INTEGER NOT NULL,
                        first_seen_at INTEGER NOT NULL,
                        event_key TEXT NOT NULL,
                        PRIMARY KEY(peer_kind, peer_id, message_id)
                    );
                    """, db: db, ints: [])
                    // V2 packets may include multiple edits of one message. Sort
                    // only where both contain comparable event timestamps.
                    let ordered: [[String: Any]]
                    if format == "goldgram_bridge_v2" {
                        ordered = rows.enumerated().sorted { lhs, rhs in
                            // Process source edits before deletions so a new
                            // chronology hold prevents a deletion from promoting
                            // the same uncertain text to a verified original.
                            let aDeleted = lhs.element["record_kind"] as? String == "delete"
                            let bDeleted = rhs.element["record_kind"] as? String == "delete"
                            if aDeleted != bDeleted { return !aDeleted }
                            let a = (lhs.element["server_edit_at"] as? String) ?? ""
                            let b = (rhs.element["server_edit_at"] as? String) ?? ""
                            return a == b ? lhs.offset < rhs.offset : a < b
                        }.map { $0.element }
                    } else {
                        ordered = rows
                    }
                    for row in ordered {
                        if row["record_kind"] as? String == "delete" {
                            let status = try importDelete(
                                row, db: db, now: Int64(Date().timeIntervalSince1970 * 1000),
                                parse: parse)
                            counts[status, default: 0] += 1
                            if status == "pending" {
                                counts["conflicts", default: 0] += 1
                            }
                            continue
                        }
                        guard row["source"] as? String == "iphone8_telethon",
                              let kindText = row["peer_kind"] as? String,
                              let rawChat = row["chat_id"] as? String,
                              let midText = row["message_id"] as? String,
                              let idValue = Int64(midText),
                              let id = Int32(exactly: idValue), id > 0,
                              let firstAtText = row["first_seen_at"] as? String,
                              let firstDate = parse(firstAtText),
                              let original = row["original_text"] as? String,
                              let latest = row["latest_text"] as? String,
                              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              original != latest,
                              original.utf8.count <= 65536, latest.utf8.count <= 65536 else {
                            counts["invalid", default: 0] += 1; continue
                        }
                        // The exporter must supply a unique source event ID and
                        // an actual server edit timestamp for full multi-edit merge.
                        let token = (row["edit_event_id"] as? String) ?? ""
                        let serverEditDate = (row["server_edit_at"] as? String).flatMap(parse)
                        let eventSeenDate = (row["event_observed_at"] as? String).flatMap(parse)
                        if format == "goldgram_bridge_v2" &&
                            (token.isEmpty || token.utf8.count > 128 ||
                             serverEditDate == nil || eventSeenDate == nil) {
                            counts["invalid", default: 0] += 1; continue
                        }
                        let peerId: Int64
                        let peerKind: Int32
                        if kindText == "PeerUser", let value = Int64(rawChat), value > 0 {
                            peerId = value; peerKind = 0
                        } else if kindText == "PeerChannel", rawChat.hasPrefix("-100"),
                                  let value = Int64(rawChat.dropFirst(4)), value > 0 {
                            peerId = value
                            // Telethon's PeerChannel maps to both channel and supergroup.
                            // An already observed native dialog is required.
                            var ptr: OpaquePointer?
                            let sql = "SELECT peer_kind FROM dialogs WHERE peer_id=? AND peer_kind IN (2,3) LIMIT 2;"
                            guard sqlite3_prepare_v2(db, sql, -1, &ptr, nil) == SQLITE_OK,
                                  let stmt = ptr else {
                                if let ptr { sqlite3_finalize(ptr) }
                                throw GoldgramHistoryStore.StorageError.sqlite(sqlite3_errcode(db))
                            }
                            sqlite3_bind_int64(stmt, 1, peerId)
                            var kinds: [Int32] = []
                            while sqlite3_step(stmt) == SQLITE_ROW {
                                kinds.append(sqlite3_column_int(stmt, 0))
                            }
                            sqlite3_finalize(stmt)
                            guard kinds.count == 1 else {
                                counts["unknownChannels", default: 0] += 1; continue
                            }
                            peerKind = kinds[0]
                        } else {
                            counts["invalid", default: 0] += 1; continue
                        }
                        let first = Int64(firstDate.timeIntervalSince1970 * 1000)
                        let now = Int64(Date().timeIntervalSince1970 * 1000)
                        let edited = serverEditDate.map { Int64($0.timeIntervalSince1970 * 1000) }
                        let observed = eventSeenDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? now
                        guard first > 0, first <= now + 300000,
                              observed >= first, observed <= now + 300000,
                              edited == nil || (edited! > 0 && edited! <= observed + 300000) else {
                            counts["invalid", default: 0] += 1; continue
                        }
                        let scope = [Int64(peerKind), peerId, Int64(id)]
                        // Cryptographically stable fingerprint. With V2 the source
                        // event ID + server time differentiates A→B→A transitions;
                        // V1 has no way to prove such repeated transitions.
                        let identity = [String(peerKind), String(peerId), String(id),
                            String(original.utf8.count), original,
                            String(latest.utf8.count), latest,
                            String(edited ?? 0), token].joined(separator: "\u{1f}")
                        let digest = SHA256.hash(data: Data(identity.utf8))
                            .map { String(format: "%02x", $0) }.joined()
                        let key = "iphone8.merge.v2.\(digest)"
                        let oldKey = "iphone8.edit.\(peerKind).\(peerId).\(id)"
                        let receipt = try receiptStatus(db: db, key: key)
                        if receipt == "applied" || receipt == "already_present" {
                            counts["duplicates", default: 0] += 1; continue
                        }
                        // If Telegram's server edit predates the FIRST observation
                        // on iPhone 8, there is no reliable proof that the supplied
                        // "original_text" was observed before the edit. Keep the
                        // entire remote event in the SAME SQLite for later review,
                        // without declaring a verified original or adding a revision.
                        // Saving the pending receipt in this transaction allows the
                        // live cursor to advance after COMMIT and unblock safe rows.
                        let chronologyBroken = edited != nil && edited! < first
                        let chronologyHeld = try isChronologyHeld(db: db, scope: scope)
                        if chronologyBroken || chronologyHeld {
                            if chronologyBroken {
                                try holdChronology(db: db, scope: scope,
                                                   first: first, eventKey: key)
                            }
                            if receipt != "pending" {
                                let payload = String(data: try JSONSerialization.data(
                                    withJSONObject: row, options: [.sortedKeys]),
                                    encoding: .utf8) ?? "{}"
                                try saveReceipt(db: db, key: key,
                                                status: "pending", payload: payload)
                                counts["chronologyPending", default: 0] += 1
                                counts["pending", default: 0] += 1
                            } else {
                                counts["duplicates", default: 0] += 1
                            }
                            continue
                        }
                        let knownOriginal = try originalInArchive(db: db, scope: scope)
                        let previous = try GoldgramHistoryStore.lastSavedRevision(
                            db: db, peerId: peerId, messageId: id, peerKind: peerKind)
                        let previousTime = try lastRevisionTime(db: db, scope: scope)
                        // Classify the transition BEFORE any live archive mutation.
                        // If history diverges and order is not provable, retain the
                        // entire remote payload in the same DB for later resolution.
                        let originalConflict = knownOriginal != nil && knownOriginal != original
                        let latestAlreadySeen = previous?.text == latest
                        let previousIsBaseline = previous?.text == original && previous?.index == 0
                        let newerServerEdit = edited != nil && previousTime != nil &&
                            edited! > previousTime!
                        let canAppend = previous == nil || previousIsBaseline || newerServerEdit
                        // A legacy #187 import has no per-edit event ID. Recognize
                        // a previously saved revision + its legacy event even after
                        // newer native revisions arrive, rather than queueing it.
                        // Swift's && operator is rethrows; evaluate the
                        // fallible SQLite lookups independently before combining.
                        if receipt == nil && !originalConflict {
                            let legacyEventSeen = try hasEventKey(db: db, key: oldKey)
                            if legacyEventSeen {
                                let legacyRevisionSeen = try containsRevision(
                                    db: db, scope: scope, content: latest)
                                if legacyRevisionSeen {
                                    try saveReceipt(db: db, key: key,
                                                    status: "already_present", payload: nil)
                                    counts["duplicates", default: 0] += 1
                                    continue
                                }
                            }
                        }
                        if originalConflict {
                            let packet = String(data: try JSONSerialization.data(
                                withJSONObject: row, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
                            try saveReceipt(db: db, key: key, status: "pending", payload: packet)
                            counts["conflicts", default: 0] += 1
                            counts["pending", default: 0] += 1
                            continue
                        }
                        let firstOriginal = knownOriginal == nil
                        try GoldgramHistoryStore.archiveSQL(
                            "INSERT OR IGNORE INTO dialogs(peer_kind,peer_id) VALUES(?,?);",
                            db: db, ints: [Int64(peerKind), peerId])
                        try GoldgramHistoryStore.archiveSQL(
                            "INSERT OR IGNORE INTO messages(peer_kind,peer_id,message_id,first_seen_at,last_seen_at,original_observed,capture_provenance,original_text) VALUES(?,?,?,?,?,1,3,?);",
                            db: db, ints: scope + [first, now], text: original)
                        if firstOriginal {
                            try GoldgramHistoryStore.archiveSQL(
                                "UPDATE messages SET original_observed=1,original_text=?4,capture_provenance=CASE WHEN capture_provenance=0 THEN 3 ELSE capture_provenance END WHERE peer_kind=?1 AND peer_id=?2 AND message_id=?3 AND original_observed=0;",
                                db: db, ints: scope, text: original)
                            try GoldgramHistoryStore.recordFirstOriginalEvidence(
                                db: db, scope: scope, at: first,
                                source: "iphone8_telethon_initial_v1",
                                attempt: nil, concurrentEdit: false, committedAt: now,
                                enqueueState: "unknown", commitState: "unknown")
                            counts["imported", default: 0] += 1
                        }
                        // A pre-edit original is independently useful even when
                        // the remote latest edit cannot be safely ordered against
                        // native history. Save it, but queue that edit for review.
                        if !latestAlreadySeen && !canAppend {
                            let packet = String(data: try JSONSerialization.data(
                                withJSONObject: row, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
                            try saveReceipt(db: db, key: key, status: "pending", payload: packet)
                            counts["conflicts", default: 0] += 1
                            counts["pending", default: 0] += 1
                            continue
                        }
                        if previous == nil {
                            try GoldgramHistoryStore.archiveSQL(
                                "INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,observed_at,revision_provenance,content) VALUES(?,?,?,0,?,1,?);",
                                db: db, ints: scope + [first], text: original)
                        }
                        // With a newer authenticated Telegram edit timestamp,
                        // even an A→B→A return to identical text is a distinct
                        // transition. V1 cannot establish this and stays conservative.
                        let timedRepeat = latestAlreadySeen && newerServerEdit
                        if !latestAlreadySeen || timedRepeat {
                            let current = try GoldgramHistoryStore.lastSavedRevision(
                                db: db, peerId: peerId, messageId: id, peerKind: peerKind)
                            try GoldgramHistoryStore.archiveSQL(
                                "INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,observed_at,server_edit_at,revision_provenance,content) VALUES(?,?,?,?,?,NULLIF(?,0),3,?);",
                                db: db, ints: scope + [(current?.index ?? 0) + 1,
                                                        observed, edited ?? 0], text: latest)
                        }
                        // If Swiftgram already saw this edit, do not create a
                        // duplicate edit event, regardless of bridge event key.
                        if latestAlreadySeen && !timedRepeat {
                            let nativeEditSeen = try hasEdit(db: db, scope: scope)
                            if nativeEditSeen {
                                try saveReceipt(db: db, key: key,
                                                status: "already_present", payload: nil)
                                counts["duplicates", default: 0] += 1
                                continue
                            }
                        }
                        try GoldgramHistoryStore.archiveSQL(
                            "INSERT OR IGNORE INTO events(peer_kind,peer_id,message_id,event_kind,source,server_time,observed_at,event_key) VALUES(?,?,?,1,'goldgram_iphone8_bridge_v1',NULLIF(?,0),?,?);",
                            db: db, ints: scope + [edited ?? 0, observed], text: key)
                        if sqlite3_changes(db) > 0 {
                            counts["edits", default: 0] += 1
                        } else {
                            counts["duplicates", default: 0] += 1
                        }
                        try saveReceipt(db: db, key: key,
                                        status: "applied", payload: nil)
                    }
                    try GoldgramHistoryStore.archiveSQL("COMMIT;", db: db, ints: [])
                } catch {
                    try? GoldgramHistoryStore.archiveSQL("ROLLBACK;", db: db, ints: [])
                    throw error
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("GoldgramArchiveChanged"),
                        object: NSNumber(value: accountId))
                }
                finish(counts)
            } catch {
                finish(["error": 1])
            }
        }
    }
}

extension GoldgramHistoryStore {
    static func importPhone8Bundle(_ data: Data, accountId: Int64,
                                   completion: @escaping ([String: Int]) -> Void) {
        GoldgramPhone8Bridge.importBundle(data, accountId: accountId, completion: completion)
    }
}


// Goldgram Live receiver: foreground-only TLS-pinned pull from jailbroken iPhone 8.
// No second SQLite; receipts and edits use the existing Goldgram import transaction.
// No reliance on a persistent SSH/Termius session or on iOS running while suspended.
final class GoldgramLiveBridge: NSObject, URLSessionDelegate {
    static let shared = GoldgramLiveBridge()
    private let defaults = UserDefaults.standard
    private let tokenService = "com.goldgram.livebridge.iphone8"
    private var timer: DispatchSourceTimer?
    private var session: URLSession?
    private var runningAccount: Int64?
    private var inFlight = false
    private var runToken: UInt64 = 0
    private var expectedPin = ""
    private(set) var lastStatus = "Live не настроен"

    private override init() {
        super.init()
        #if os(iOS)
        NotificationCenter.default.addObserver(self,
            selector: #selector(activated),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        #endif
    }

    private func key(_ account: Int64, _ name: String) -> String {
        "GoldgramLiveV1.\(account).\(name)"
    }

    static func privateIPv4(_ value: String) -> Bool {
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 4 else { return false }
        let octets = segments.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    func configuredHost(account: Int64) -> String {
        defaults.string(forKey: key(account, "host")) ?? ""
    }

    func configuredPin(account: Int64) -> String {
        defaults.string(forKey: key(account, "pin")) ?? ""
    }

    func isEnabled(account: Int64) -> Bool {
        defaults.bool(forKey: key(account, "enabled"))
    }

    // Stored only in iOS Keychain, never in UserDefaults, logs, crash reports,
    // the server URL, or the SQLite archive.
    private func storeSecret(_ secret: String, account: Int64) -> Bool {
        let accountName = String(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: accountName
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = Data(secret.utf8)
        #if os(iOS)
        insert[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private func readSecret(account: Int64) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: String(account),
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var data: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess,
              let bytes = data as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    func configure(account: Int64, host: String, pin: String, token: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPin = pin.lowercased().filter { !$0.isWhitespace && $0 != ":" }
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account > 0, Self.privateIPv4(normalizedHost),
              normalizedPin.count == 64,
              normalizedPin.allSatisfy({ $0.isHexDigit }),
              normalizedToken.count == 64,
              normalizedToken.allSatisfy({ $0.isHexDigit }),
              storeSecret(normalizedToken, account: account) else {
            lastStatus = "Неверный IP, отпечаток сертификата или код подключения"
            return false
        }
        let oldHost = configuredHost(account: account)
        let oldPin = configuredPin(account: account)
        if oldHost != normalizedHost || oldPin != normalizedPin {
            defaults.removeObject(forKey: key(account, "editsCursor"))
            defaults.removeObject(forKey: key(account, "deletionsCursor"))
        }
        defaults.set(normalizedHost, forKey: key(account, "host"))
        defaults.set(normalizedPin, forKey: key(account, "pin"))
        defaults.set(true, forKey: key(account, "enabled"))
        stop()
        start(account: account)
        return true
    }

    func stop() {
        runToken &+= 1
        timer?.cancel()
        timer = nil
        session?.invalidateAndCancel()
        session = nil
        runningAccount = nil
        inFlight = false
    }

    func disable(account: Int64) {
        defaults.set(false, forKey: key(account, "enabled"))
        stop()
        lastStatus = "Live отключён; архив не изменён"
    }

    func start(account: Int64) {
        guard account > 0, isEnabled(account: account),
              Self.privateIPv4(configuredHost(account: account)),
              configuredPin(account: account).count == 64,
              readSecret(account: account) != nil else {
            return
        }
        if runningAccount == account && timer != nil { return }
        stop()
        runningAccount = account
        expectedPin = configuredPin(account: account)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration,
                             delegate: self, delegateQueue: nil)
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .seconds(12),
                        leeway: .seconds(2))
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
        lastStatus = "Live включён: ожидаем HTTPS-соединение"
    }

    func tryStartForVisibleArchive() {
        guard let account = GoldgramArchiveReader.activeAccountId()?.int64Value,
              account > 0 else { return }
        start(account: account)
    }

    @objc private func activated() {
        guard let account = GoldgramArchiveReader.activeAccountId()?.int64Value,
              account > 0 else { return }
        start(account: account)
        poll()
    }

    func pollNow() {
        guard let account = GoldgramArchiveReader.activeAccountId()?.int64Value,
              account > 0 else { return }
        start(account: account)
        poll()
    }

    private func status(_ new: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastStatus = new
            NotificationCenter.default.post(
                name: Notification.Name("GoldgramLiveBridgeChanged"), object: nil)
        }
    }

    private func poll() {
        guard !inFlight, let account = runningAccount,
              GoldgramArchiveReader.activeAccountId()?.int64Value == account,
              defaults.bool(forKey: "GoldgramSQLiteCaptureEnabled"),
              let token = readSecret(account: account),
              let session else { return }
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        #endif
        let edits = max(0, defaults.integer(forKey: key(account, "editsCursor")))
        let deletions = max(0, defaults.integer(forKey: key(account, "deletionsCursor")))
        let host = configuredHost(account: account)
        guard let url = URL(string: "https://\(host):8873/v1/events?edits_after=\(edits)&deletions_after=\(deletions)") else {
            return
        }
        inFlight = true
        let ticket = runToken
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Goldgram-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.runningAccount == account, self.runToken == ticket else { return }
                if let error {
                    self.inFlight = false
                    self.status("Сбой HTTPS: \(error.localizedDescription)")
                    return
                }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, data.count <= 1_000_000,
                      let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      payload["format"] as? String == "goldgram_bridge_v2",
                      let rows = payload["records"] as? [[String: Any]],
                      rows.count <= 40,
                      let nextEdits = payload["next_edit_cursor"] as? Int,
                      let nextDeletes = payload["next_delete_cursor"] as? Int,
                      nextEdits >= edits, nextDeletes >= deletions else {
                    self.inFlight = false
                    self.status("Live: неверный или отклонённый HTTPS-ответ")
                    return
                }
                func commitCursor(_ result: [String: Int]) {
                    guard self.runningAccount == account, self.runToken == ticket else { return }
                    self.inFlight = false
                    if result["error"] != nil || result["wrongAccount"] != nil ||
                       result["disabled"] != nil || result["invalid", default: 0] > 0 ||
                       result["unknownChannels", default: 0] > 0 {
                        let invalid = result["invalid", default: 0]
                        let unknown = result["unknownChannels", default: 0]
                        let accountMismatch = result["wrongAccount", default: 0]
                        let disabled = result["disabled", default: 0]
                        let databaseError = result["error", default: 0]
                        self.status("Live: не принят пакет (формат: \(invalid), каналы: \(unknown), аккаунт: \(accountMismatch), SQLite выключен: \(disabled), ошибка БД: \(databaseError)); курсор не сдвинут")
                        return
                    }
                    // The importer callback follows the SQLite COMMIT.
                    self.defaults.set(nextEdits, forKey: self.key(account, "editsCursor"))
                    self.defaults.set(nextDeletes, forKey: self.key(account, "deletionsCursor"))
                    let changes = (result["edits"] ?? 0) + (result["deletions"] ?? 0)
                    let imported = result["imported"] ?? 0
                    let pending = result["pending"] ?? 0
                    let chronologyPending = result["chronologyPending"] ?? 0
                    self.status("Live: +\(changes) событий, +\(imported) оригиналов, спорных \(pending) (хронология: \(chronologyPending)), курсоры \(nextEdits)/\(nextDeletes)")
                    // Catch up the old archive quickly without waiting one
                    // 12-second interval per historical batch. Limited by
                    // the importer transaction and its single in-flight gate.
                    if nextEdits > edits || nextDeletes > deletions {
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) { [weak self] in
                            guard let self, self.runToken == ticket else { return }
                            self.poll()
                        }
                    }
                }
                if rows.isEmpty {
                    commitCursor([:])
                    return
                }
                GoldgramHistoryStore.importPhone8Bundle(data, accountId: account,
                                                        completion: commitCursor)
            }
        }
        task.resume()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod ==
                  NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let cert = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(cert) as Data)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == expectedPin else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Intentional certificate pin for a single self-signed certificate.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
