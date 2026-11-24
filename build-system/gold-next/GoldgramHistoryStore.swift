// Goldgram SQLite foundation (#64).
// Deliberately inert: no message capture, database creation, or account lookup
// occurs until a future, independently tested atom calls prepare(accountId:).
// Never infer an account ID from a message ID or a chat peer ID.
import Foundation
import SQLite3
import CryptoKit
import Security
#if canImport(Network)
import Network
#endif
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
        // #235: every projection refresh queries events by the full message
        // scope. The previous dialog/time index could scan thousands of events
        // from a busy discussion for EACH edit, including on Live import.
        try? execute("CREATE INDEX IF NOT EXISTS goldgram_events_scope_kind_v235 ON events(peer_kind,peer_id,message_id,event_kind,observed_at);", on: db)
        // Additive transactional read projection; failure must never block capture.
        GoldgramArchiveReader.ensureFastIndex(on: db)

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

    // #233: independent, account-local journal clearing, one SQLite
    // transaction. Do not touch iPhone 8, Live cursors, import receipts or
    // verified originals needed by the *other* journal category.
    static func purgeJournal(accountId: Int64, category: Int) throws -> [[String: Any]] {
        guard accountId > 0, category == 1 || category == 3 else {
            throw StorageError.sqlite(SQLITE_MISUSE)
        }
        let db = try archiveConnection(for: accountId)
        // #235: choose affected scopes directly from event/revision indexes,
        // not an EXISTS scan across every original message in the archive.
        let selection = category == 1 ? """
            SELECT peer_kind,peer_id,message_id FROM events WHERE event_kind=1
            UNION SELECT peer_kind,peer_id,message_id FROM revisions WHERE version_index>0
            """ : """
            SELECT peer_kind,peer_id,message_id FROM events WHERE event_kind=2
            UNION SELECT peer_kind,peer_id,message_id FROM messages WHERE is_deleted=1
            """
        try archiveSQL("BEGIN IMMEDIATE;", db: db, ints: [])
        do {
            try execute("""
                CREATE TEMP TABLE IF NOT EXISTS goldgram_purge_scopes_v235(
                    peer_kind INTEGER NOT NULL,peer_id INTEGER NOT NULL,message_id INTEGER NOT NULL,
                    PRIMARY KEY(peer_kind,peer_id,message_id)) WITHOUT ROWID;
                DELETE FROM temp.goldgram_purge_scopes_v235;
                INSERT OR IGNORE INTO temp.goldgram_purge_scopes_v235(peer_kind,peer_id,message_id)
                \(selection);
                """, on: db)
            var scopes: [[String: Any]] = []
            do {
                var ptr: OpaquePointer?
                let rc = sqlite3_prepare_v2(db, "SELECT peer_kind,peer_id,message_id FROM temp.goldgram_purge_scopes_v235;", -1, &ptr, nil)
                guard rc == SQLITE_OK, let stmt = ptr else {
                    if let ptr { sqlite3_finalize(ptr) }
                    throw StorageError.sqlite(rc)
                }
                defer { sqlite3_finalize(stmt) }
                while true {
                    let step = sqlite3_step(stmt)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else { throw StorageError.sqlite(step) }
                    scopes.append([
                        "peerKind": NSNumber(value: sqlite3_column_int(stmt, 0)),
                        "peerId": NSNumber(value: sqlite3_column_int64(stmt, 1)),
                        "messageId": NSNumber(value: sqlite3_column_int64(stmt, 2))
                    ])
                }
            }

            // Only suspend the THREE known derived-index triggers that would
            // execute repeatedly during this bulk operation. Their exact SQL
            // definitions are restored in this SAME transaction. All other
            // triggers, foreign keys, receipts and capture rules stay active.
            let names = category == 1
                ? ["goldgram_ui_fast_source_event_delete_v1", "goldgram_ui_fast_source_revision_delete_v1"]
                : ["goldgram_ui_fast_source_event_delete_v1", "goldgram_ui_fast_source_message_update_v1"]
            var definitions: [(String, String)] = []
            do {
                var ptr: OpaquePointer?
                let rc = sqlite3_prepare_v2(db, "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name IN ('goldgram_ui_fast_source_event_delete_v1','goldgram_ui_fast_source_revision_delete_v1','goldgram_ui_fast_source_message_update_v1');", -1, &ptr, nil)
                guard rc == SQLITE_OK, let stmt = ptr else {
                    if let ptr { sqlite3_finalize(ptr) }
                    throw StorageError.sqlite(rc)
                }
                defer { sqlite3_finalize(stmt) }
                while true {
                    let step = sqlite3_step(stmt)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else { throw StorageError.sqlite(step) }
                    if let n = sqlite3_column_text(stmt, 0), let sql = sqlite3_column_text(stmt, 1) {
                        let name = String(cString: n)
                        if names.contains(name) { definitions.append((name, String(cString: sql))) }
                    }
                }
            }
            // Fall back to ordinary trigger execution if the projection is
            // unavailable or only partially installed. Never drop a subset.
            let bulk = definitions.count == names.count && GoldgramArchiveReader.fastIndexAvailable(db)
            if bulk {
                for (name, _) in definitions {
                    try execute("DROP TRIGGER \(name);", on: db)
                }
            }
            if category == 1 {
                try execute("DELETE FROM events WHERE event_kind=1;", on: db)
                try execute("DELETE FROM revisions WHERE version_index>0;", on: db)
            } else {
                try execute("DELETE FROM events WHERE event_kind=2;", on: db)
                try execute("UPDATE messages SET is_deleted=0 WHERE is_deleted=1;", on: db)
                try execute("DELETE FROM unresolved_deletions;", on: db)
            }
            if bulk {
                // Refresh each changed message exactly ONCE using the same
                // visibility predicate as normal capture, not guessed flags.
                try execute(GoldgramArchiveReader.bulkPurgeProjectionSQL, on: db)
                for (_, sql) in definitions { try execute(sql, on: db) }
            }
            try execute("DELETE FROM temp.goldgram_purge_scopes_v235;", on: db)
            try archiveSQL("COMMIT;", db: db, ints: [])
            return scopes
        } catch {
            // SQLite transactional DDL restores all dropped triggers on rollback.
            try? archiveSQL("ROLLBACK;", db: db, ints: [])
            throw error
        }
    }

    // OFF by default. A timer is a retention interval (clear this category
    // every N hours when the foreground app is next able to run).
    static func retentionKey(_ account: Int64, _ category: Int) -> String {
        "GoldgramJournalAutoclearHoursV1.\(account).\(category)"
    }
    static func retentionLastKey(_ account: Int64, _ category: Int) -> String {
        "GoldgramJournalLastClearV1.\(account).\(category)"
    }
    static func validRetentionHours(_ hours: Int) -> Bool {
        [0, 12, 24, 48, 72, 168].contains(hours)
    }

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
    private static let archiveReadQueue = DispatchQueue(label: "goldgram.history.read.v235", qos: .userInitiated)
    private static var selectedAccount: Int64 = 0
    private static var nativeNavigate: GoldgramNativeNavigate?
    private static var journalTimer: DispatchSourceTimer?

    // #234: a cheap foreground-only clock for the independent journal timers.
    // Checking two UserDefaults keys every five minutes does not query Telegram
    // or open SQLite until a configured deadline is actually due.
    private static func ensureJournalTimer() {
        DispatchQueue.main.async {
            guard journalTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .seconds(60),
                           repeating: .seconds(300), leeway: .seconds(20))
            timer.setEventHandler {
                #if canImport(UIKit)
                guard UIApplication.shared.applicationState == .active else { return }
                #endif
                guard let account = activeAccountId() else { return }
                runJournalAutoclearIfDue(forAccount: account)
            }
            journalTimer = timer
            timer.resume()
        }
    }

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
        if id > 0 {
            let settings = UserDefaults.standard
            if [1,3].contains(where: {
                settings.integer(forKey: GoldgramHistoryStore.retentionKey(id, $0)) > 0
            }) {
                ensureJournalTimer()
                DispatchQueue.main.async {
                    runJournalAutoclearIfDue(forAccount: NSNumber(value: id))
                }
            }
        }
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

    // #233: manually clear only one journal without resetting another.
    @objc(clearJournalForAccount:category:completion:)
    public static func clearJournal(forAccount account: NSNumber, category: Int,
                                    completion: @escaping (NSDictionary) -> Void) {
        let id = account.int64Value
        guard isSelected(id), category == 1 || category == 3 else {
            completion(["status": "account_changed"]); return
        }
        let started = ProcessInfo.processInfo.systemUptime
        GoldgramHistoryStore.enqueueArchiveWork {
            guard self.isSelected(id) else {
                DispatchQueue.main.async { completion(["status": "account_changed"]) }
                return
            }
            do {
                let scopes = try GoldgramHistoryStore.purgeJournal(accountId: id, category: category)
                let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                UserDefaults.standard.set(Date().timeIntervalSince1970,
                    forKey: GoldgramHistoryStore.retentionLastKey(id, category))
                DispatchQueue.main.async {
                    self.postJournalPurge(account: id, category: category, scopes: scopes)
                    completion(["status": "ok", "elapsedMs": milliseconds, "affected": scopes.count])
                }
            } catch {
                DispatchQueue.main.async { completion(["status": "unavailable"]) }
            }
        }
    }

    // Notification is emitted only AFTER SQLite COMMIT. The bound TelegramCore
    // account uses its existing Postbox to remove stale inline history/snapshots.
    private static func postJournalPurge(account: Int64, category: Int,
                                         scopes: [[String: Any]]) {
        NotificationCenter.default.post(name: Notification.Name("GoldgramArchivePurged"),
            object: NSNumber(value: account),
            userInfo: ["category": category, "scopes": scopes])
        NotificationCenter.default.post(name: Notification.Name("GoldgramArchiveChanged"),
            object: NSNumber(value: account), userInfo: ["journalPurge": true])
    }

    @objc(setJournalRetentionForAccount:category:hours:)
    public static func setJournalRetention(forAccount account: NSNumber,
                                           category: Int, hours: Int) {
        let id = account.int64Value
        guard isSelected(id), category == 1 || category == 3,
              GoldgramHistoryStore.validRetentionHours(hours) else { return }
        UserDefaults.standard.set(hours,
            forKey: GoldgramHistoryStore.retentionKey(id, category))
        UserDefaults.standard.set(Date().timeIntervalSince1970,
            forKey: GoldgramHistoryStore.retentionLastKey(id, category))
        if hours > 0 { ensureJournalTimer() }
    }

    @objc(journalRetentionForAccount:category:)
    public static func journalRetention(forAccount account: NSNumber, category: Int) -> Int {
        let id = account.int64Value
        guard isSelected(id), category == 1 || category == 3 else { return 0 }
        return UserDefaults.standard.integer(
            forKey: GoldgramHistoryStore.retentionKey(id, category))
    }

    @objc(runJournalAutoclearIfDueForAccount:)
    public static func runJournalAutoclearIfDue(forAccount account: NSNumber) {
        let id = account.int64Value
        guard isSelected(id) else { return }
        let now = Date().timeIntervalSince1970
        let defaults = UserDefaults.standard
        let due = [1,3].filter { category in
            let hours = defaults.integer(
                forKey: GoldgramHistoryStore.retentionKey(id, category))
            guard hours > 0, GoldgramHistoryStore.validRetentionHours(hours) else { return false }
            let last = defaults.double(
                forKey: GoldgramHistoryStore.retentionLastKey(id, category))
            return last > 0 && now - last >= Double(hours) * 3600
        }
        guard !due.isEmpty else { return }
        GoldgramHistoryStore.enqueueArchiveWork {
            guard self.isSelected(id) else { return }
            let settings = UserDefaults.standard
            for category in due {
                let hours = settings.integer(forKey: GoldgramHistoryStore.retentionKey(id, category))
                let last = settings.double(forKey: GoldgramHistoryStore.retentionLastKey(id, category))
                let now = Date().timeIntervalSince1970
                guard hours > 0, GoldgramHistoryStore.validRetentionHours(hours),
                      last > 0, now - last >= Double(hours) * 3600 else { continue }
                do {
                    let scopes = try GoldgramHistoryStore.purgeJournal(accountId: id, category: category)
                    settings.set(now, forKey: GoldgramHistoryStore.retentionLastKey(id, category))
                    DispatchQueue.main.async {
                        guard self.isSelected(id) else { return }
                        self.postJournalPurge(account: id, category: category, scopes: scopes)
                    }
                } catch { /* Retry at next foreground Live poll. */ }
            }
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


    // #203: A *projection* inside the existing account SQLite, not another
    // database, and not another source of truth. The projection is rebuilt once
    // for an old archive, then updated transactionally by source-table triggers.
    // Only IDs, flags and sort times are indexed: no message bodies duplicated.
    //
    // Keep the visibility expression exactly aligned with messagesSQL. A
    // versioned table name permits a later safe rebuild if the policy changes.
    private static let fastEditPredicate = """
    EXISTS (SELECT 1 FROM events e WHERE e.peer_kind=m.peer_kind
       AND e.peer_id=m.peer_id AND e.message_id=m.message_id
       AND e.event_kind=1 AND (e.source IN ('goldgram_native_live_v2','goldgram_iphone8_bridge_v1')
       OR (e.source != 'goldgram_native_v1' AND e.server_time > 0
       AND m.original_observed=1 AND EXISTS (
           SELECT 1 FROM revisions vr WHERE vr.peer_kind=m.peer_kind
           AND vr.peer_id=m.peer_id AND vr.message_id=m.message_id
           AND vr.content != m.original_text))))
    """

    private static let fastDeleteEventPredicate = """
    EXISTS (SELECT 1 FROM events de WHERE de.peer_kind=m.peer_kind
        AND de.peer_id=m.peer_id AND de.message_id=m.message_id
        AND de.event_kind=2)
    """

    private static var fastVisiblePredicate: String {
        let hasBody = """
        (NULLIF(TRIM(COALESCE(m.original_text,'')), '') IS NOT NULL
          AND m.original_text != '[Содержимое не было получено]'
         OR EXISTS (SELECT 1 FROM revisions body WHERE body.peer_kind=m.peer_kind
            AND body.peer_id=m.peer_id AND body.message_id=m.message_id
            AND NULLIF(TRIM(body.content), '') IS NOT NULL
            AND body.content != '[Содержимое не было получено]'))
        """
        let reliable = """
        (m.original_observed=1 AND NULLIF(TRIM(COALESCE(m.original_text,'')), '') IS NOT NULL
           AND m.original_text != '[Содержимое не было получено]'
          OR m.is_deleted=1 OR \(fastDeleteEventPredicate))
        """
        return "(\(hasBody) AND \(reliable) AND (m.is_deleted=1 OR \(fastDeleteEventPredicate) OR \(fastEditPredicate)))"
    }

    private static var fastSelectColumns: String {
        """
        m.peer_kind, m.peer_id, m.message_id,
        CASE WHEN \(fastVisiblePredicate) THEN 1 ELSE 0 END,
        CASE WHEN \(fastEditPredicate) THEN 1 ELSE 0 END,
        CASE WHEN m.is_deleted=1 OR \(fastDeleteEventPredicate) THEN 1 ELSE 0 END,
        COALESCE((SELECT MAX(e.observed_at) FROM events e WHERE
          e.peer_kind=m.peer_kind AND e.peer_id=m.peer_id AND e.message_id=m.message_id),
          m.last_seen_at),
        COALESCE((SELECT MIN(de.observed_at) FROM events de WHERE
          de.peer_kind=m.peer_kind AND de.peer_id=m.peer_id
          AND de.message_id=m.message_id AND de.event_kind=2),m.last_seen_at),
        COALESCE(m.sent_at,m.last_seen_at)
        """
    }

    private static func fastRefreshStatement(_ row: String) -> String {
        """
        INSERT INTO goldgram_ui_fast_rows_v1
          (peer_kind,peer_id,message_id,visible,edited,deleted,newest_at,deleted_at,sort_at)
        SELECT \(fastSelectColumns)
        FROM messages m WHERE m.peer_kind=\(row).peer_kind
          AND m.peer_id=\(row).peer_id AND m.message_id=\(row).message_id
        ON CONFLICT(peer_kind,peer_id,message_id) DO UPDATE SET
          visible=excluded.visible, edited=excluded.edited,
          deleted=excluded.deleted,newest_at=excluded.newest_at,
          deleted_at=excluded.deleted_at,sort_at=excluded.sort_at;
        """
    }

    // Executed on the archive writer queue while createOrOpen holds its
    // temporary write connection. Crash/failure rolls back *all* index DDL,
    // triggers and the backfill, leaving the original archive untouched.
    // A failed optimization always falls back to the previous SQL queries.
    fileprivate static func ensureFastIndex(on db: OpaquePointer) {
        var ptr: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='goldgram_ui_fast_rows_v1';",
                                 -1, &ptr, nil) == SQLITE_OK, let stmt = ptr else {
            if let ptr { sqlite3_finalize(ptr) }
            return
        }
        let exists = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        if exists { return }

        func exec(_ sql: String) -> Bool {
            sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        }
        guard exec("BEGIN IMMEDIATE;") else { return }
        var completed = false
        defer {
            if !completed { _ = exec("ROLLBACK;") }
        }
        let setup = """
        CREATE TABLE goldgram_ui_fast_rows_v1 (
          peer_kind INTEGER NOT NULL,peer_id INTEGER NOT NULL,
          message_id INTEGER NOT NULL,visible INTEGER NOT NULL,
          edited INTEGER NOT NULL,deleted INTEGER NOT NULL,
          newest_at INTEGER NOT NULL,deleted_at INTEGER NOT NULL,
          sort_at INTEGER NOT NULL,
          PRIMARY KEY(peer_kind,peer_id,message_id)
        );
        CREATE TABLE goldgram_ui_fast_totals_v1 (
          id INTEGER PRIMARY KEY CHECK(id=1),
          edited INTEGER NOT NULL DEFAULT 0,
          deleted INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO goldgram_ui_fast_totals_v1(id,edited,deleted) VALUES(1,0,0);
        CREATE INDEX goldgram_ui_fast_dialogs_v1
           ON goldgram_ui_fast_rows_v1(visible,deleted,peer_kind,peer_id,newest_at DESC);
        CREATE INDEX goldgram_ui_fast_dialog_dates_v1
           ON goldgram_ui_fast_rows_v1(visible,deleted,peer_kind,peer_id,deleted_at DESC);
        CREATE INDEX goldgram_ui_fast_message_order_v1
           ON goldgram_ui_fast_rows_v1(peer_kind,peer_id,visible,deleted,sort_at DESC,message_id DESC);
        CREATE INDEX goldgram_ui_fast_delete_order_v1
           ON goldgram_ui_fast_rows_v1(peer_kind,peer_id,visible,deleted,deleted_at DESC,message_id DESC);
        CREATE TRIGGER goldgram_ui_fast_insert_v1
        AFTER INSERT ON goldgram_ui_fast_rows_v1 BEGIN
          UPDATE goldgram_ui_fast_totals_v1
          SET edited=edited+(NEW.visible * NEW.edited),
              deleted=deleted+(NEW.visible * NEW.deleted) WHERE id=1;
        END;
        CREATE TRIGGER goldgram_ui_fast_update_v1
        AFTER UPDATE ON goldgram_ui_fast_rows_v1 BEGIN
          UPDATE goldgram_ui_fast_totals_v1 SET
            edited=edited+(NEW.visible*NEW.edited)-(OLD.visible*OLD.edited),
            deleted=deleted+(NEW.visible*NEW.deleted)-(OLD.visible*OLD.deleted)
          WHERE id=1;
        END;
        CREATE TRIGGER goldgram_ui_fast_delete_v1
        AFTER DELETE ON goldgram_ui_fast_rows_v1 BEGIN
          UPDATE goldgram_ui_fast_totals_v1 SET
            edited=edited-(OLD.visible*OLD.edited),
            deleted=deleted-(OLD.visible*OLD.deleted) WHERE id=1;
        END;
        """
        guard exec(setup) else { return }
        guard exec("""
          INSERT INTO goldgram_ui_fast_rows_v1
          (peer_kind,peer_id,message_id,visible,edited,deleted,newest_at,deleted_at,sort_at)
          SELECT \(fastSelectColumns) FROM messages m;
          """) else { return }

        let delete = """
          DELETE FROM goldgram_ui_fast_rows_v1
          WHERE peer_kind=OLD.peer_kind AND peer_id=OLD.peer_id
            AND message_id=OLD.message_id;
          """
        let specs: [(String,String,String,String)] = [
          ("message_insert","INSERT","messages","NEW"),
          ("message_update","UPDATE","messages","NEW"),
          ("event_insert","INSERT","events","NEW"),
          ("event_update","UPDATE","events","NEW"),
          ("event_delete","DELETE","events","OLD"),
          ("revision_insert","INSERT","revisions","NEW"),
          ("revision_update","UPDATE","revisions","NEW"),
          ("revision_delete","DELETE","revisions","OLD")
        ]
        for (name, operation, table, row) in specs {
            guard exec("""
                CREATE TRIGGER goldgram_ui_fast_source_\(name)_v1
                AFTER \(operation) ON \(table) BEGIN
                  \(fastRefreshStatement(row))
                END;
                """) else { return }
        }
        guard exec("""
            CREATE TRIGGER goldgram_ui_fast_source_message_delete_v1
            AFTER DELETE ON messages BEGIN \(delete) END;
            """) else { return }
        guard exec("COMMIT;") else { return }
        completed = true
    }

    // #235: drive by the temporary affected-scope table; totals triggers
    // remain live so the counter delta is committed with the source rows.
    fileprivate static var bulkPurgeProjectionSQL: String {
        """
        INSERT INTO goldgram_ui_fast_rows_v1
          (peer_kind,peer_id,message_id,visible,edited,deleted,newest_at,deleted_at,sort_at)
        SELECT \(fastSelectColumns)
        FROM temp.goldgram_purge_scopes_v235 p CROSS JOIN messages m
        WHERE m.peer_kind=p.peer_kind AND m.peer_id=p.peer_id AND m.message_id=p.message_id
        ON CONFLICT(peer_kind,peer_id,message_id) DO UPDATE SET
          visible=excluded.visible,edited=excluded.edited,deleted=excluded.deleted,
          newest_at=excluded.newest_at,deleted_at=excluded.deleted_at,sort_at=excluded.sort_at;
        """
    }

    fileprivate static func fastIndexAvailable(_ db: OpaquePointer) -> Bool {
        var ptr: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT id FROM goldgram_ui_fast_totals_v1 WHERE id=1 LIMIT 1;",
            -1, &ptr, nil) == SQLITE_OK, let stmt = ptr else {
            if let ptr { sqlite3_finalize(ptr) }
            return false
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static let fastDialogsSQL = """
    SELECT f.peer_kind, f.peer_id, COUNT(*) AS archived_count,
           MAX(f.newest_at) AS newest_at
    FROM goldgram_ui_fast_rows_v1 f
    WHERE f.visible=1 AND f.deleted=0 AND f.peer_kind IN (?, ?)
    GROUP BY f.peer_kind, f.peer_id
    ORDER BY newest_at DESC, f.peer_kind ASC, f.peer_id ASC
    LIMIT ? OFFSET ?;
    """

    private static let fastDeletedDialogsSQL = """
    SELECT f.peer_kind, f.peer_id, COUNT(*) AS archived_count,
           MAX(f.deleted_at) AS newest_at
    FROM goldgram_ui_fast_rows_v1 f
    WHERE f.visible=1 AND f.deleted=1 AND f.peer_kind IN (?, ?)
    GROUP BY f.peer_kind, f.peer_id
    ORDER BY newest_at DESC, f.peer_kind ASC, f.peer_id ASC
    LIMIT ? OFFSET ?;
    """

    private static func fastMessagesSQL(deletedOnly: Bool) -> String {
        // Reuse the exact legacy SELECT projection, so metadata, original
        // evidence and column ordinals remain ABI-compatible with the UI.
        let components = messagesSQL.components(separatedBy: "FROM messages m\n")
        guard components.count == 2 else { return messagesSQL }
        let order = deletedOnly ? "f.deleted_at" : "f.sort_at"
        return components[0] + """
            FROM goldgram_ui_fast_rows_v1 f
            JOIN messages m ON m.peer_kind=f.peer_kind AND m.peer_id=f.peer_id
              AND m.message_id=f.message_id
            WHERE m.peer_kind = ? AND m.peer_id = ?
              AND f.visible=1 AND f.deleted=\(deletedOnly ? 1 : 0)
            ORDER BY \(order) DESC, m.message_id DESC, m.peer_kind ASC, m.peer_id ASC
            LIMIT ? OFFSET ?;
        """
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
        case 4: kinds = [0, 1, 2, 3] // #242 all edited, including deleted later
        default: kinds = []
        }
        let requestedSources = request["sources"] as? [[String: Any]] ?? []
        var sources: [(kind: Int32, id: Int64)] = []
        if mode == "combined" {
            guard (category == 2 || category == 3 || category == 4), !requestedSources.isEmpty, requestedSources.count <= 2 else {
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
        let readWork = {
            guard self.isSelected(accountId) else {
                DispatchQueue.main.async { completion(["status": "account_changed", "items": []]) }
                return
            }
            let response = self.read(
                accountId: accountId, mode: mode,
                kinds: kinds, peerId: peerId, peerKind: scopedPeerKind, sources: sources, deletedOnly: category == 3,
                offset: Int32(offset), limit: Int32(limit), editedOnly: category == 4, diagnosticSince: diagnosticSince,
                geoSince: geoSince, geoUntil: geoUntil,
                attemptTokens: Array(attemptTokens)
            )
            DispatchQueue.main.async {
                completion(self.isSelected(accountId) ? response as NSDictionary : ["status": "account_changed", "items": []])
            }
        }
        // UI reads use a separate read-only WAL connection; diagnostics keep
        // their previous FIFO/admission behavior. A committed write notifies
        // the screen to refresh; an in-progress write is never exposed.
        if ["dialogs", "messages", "combined", "totals"].contains(mode) {
            archiveReadQueue.async {
                if GoldgramHistoryStore.archiveIsOpen { readWork() }
                else { GoldgramHistoryStore.enqueueArchiveWork(readWork) }
            }
        } else {
            GoldgramHistoryStore.enqueueArchiveWork(readWork)
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

    private static func decodeArchiveRow(_ stmt: OpaquePointer) -> [String: Any] {
        let observed = sqlite3_column_int(stmt, 4) == 1
        // A catch-up snapshot (observed=0) is never called original.
        return [
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
        ]
    }

    // #254: explicitly initiated search of the existing, visible local archive.
    // No capture, network request, DB creation, schema change or text duplication.
    private struct LocalSearch {
        let needle: String
        let sources: [(kind: Int32, id: Int64)]
        let event: Int
        let since: Int64
        let sentDateFilter: Bool
        let authorKind: Int32?
        let authorId: Int64?
    }

    static func searchLocal(accountId: Int64, needle: String, sources: [[String: Any]]?,
                            event: Int, since: Int64, authorKind: Int32?, authorId: Int64?,
                            offset: Int, sentDateFilter: Bool = false,
                            completion: @escaping (NSDictionary) -> Void) {
        let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSelected(accountId), needle.count <= 200, (0...2).contains(event),
              since >= 0, (0...5000).contains(offset),
              (authorKind == nil) == (authorId == nil),
              authorKind.map({ (0...3).contains($0) }) ?? true,
              authorId.map({ $0 > 0 }) ?? true else {
            completion(["status": "invalid_request", "items": []]); return
        }
        var scope: [(kind: Int32, id: Int64)] = []
        if let sources {
            guard (1...2).contains(sources.count) else {
                completion(["status": "invalid_request", "items": []]); return
            }
            for row in sources {
                guard let k = (row["peerKind"] as? NSNumber)?.int64Value,
                      let kind = Int32(exactly: k), (0...3).contains(kind),
                      let id = (row["peerId"] as? NSNumber)?.int64Value, id > 0 else {
                    completion(["status": "invalid_request", "items": []]); return
                }
                scope.append((kind, id))
            }
        }
        let request = LocalSearch(needle: needle, sources: scope, event: event, since: since,
                                  sentDateFilter: sentDateFilter, authorKind: authorKind, authorId: authorId)
        archiveReadQueue.async {
            guard isSelected(accountId) else {
                DispatchQueue.main.async { completion(["status": "account_changed", "items": []]) }
                return
            }
            let result = read(accountId: accountId, mode: "search", kinds: [0,1,2,3],
                              peerId: 0, peerKind: -1, sources: [], deletedOnly: false,
                              offset: Int32(offset), limit: 30, editedOnly: false,
                              diagnosticSince: 0, geoSince: 0, geoUntil: 0,
                              attemptTokens: [], localSearch: request)
            DispatchQueue.main.async {
                completion(isSelected(accountId) ? result as NSDictionary :
                           ["status": "account_changed", "items": []])
            }
        }
    }

    private static func readLocalSearch(db: OpaquePointer, search: LocalSearch,
                                        offset: Int32, limit: Int32) -> [String: Any] {
        // SQLite's built-in NOCASE only folds ASCII. This read-connection-only
        // scalar performs literal Unicode matching, including Cyrillic and е/ё.
        let registered = sqlite3_create_function_v2(db, "goldgram_contains_v1", 2,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, argc, values in
                guard argc == 2, let values,
                      let body = sqlite3_value_text(values[0]),
                      let term = sqlite3_value_text(values[1]) else {
                    sqlite3_result_int(context, 0); return
                }
                let haystack = String(decoding: UnsafeBufferPointer(start: body,
                    count: Int(sqlite3_value_bytes(values[0]))), as: UTF8.self)
                let needle = String(decoding: UnsafeBufferPointer(start: term,
                    count: Int(sqlite3_value_bytes(values[1]))), as: UTF8.self)
                let matches = haystack.range(of: needle,
                    options: [.caseInsensitive, .diacriticInsensitive]) != nil
                sqlite3_result_int(context, matches ? 1 : 0)
            }, nil, nil, nil)
        guard registered == SQLITE_OK else { return ["status": "unavailable", "items": []] }

        let projection = messagesSQL.components(separatedBy: "FROM messages m\n")
        guard projection.count == 2 else { return ["status": "unavailable", "items": []] }
        let fast = fastIndexAvailable(db)
        let source = fast
            ? "goldgram_ui_fast_rows_v1 f JOIN messages m ON m.peer_kind=f.peer_kind AND m.peer_id=f.peer_id AND m.message_id=f.message_id"
            : "messages m"
        let deleted = fast ? "f.deleted=1" : "(m.is_deleted=1 OR \(fastDeleteEventPredicate))"
        let edited = fast ? "f.edited=1" : fastEditPredicate
        let newest = fast ? "f.newest_at" : "COALESCE((SELECT MAX(e.observed_at) FROM events e WHERE e.peer_kind=m.peer_kind AND e.peer_id=m.peer_id AND e.message_id=m.message_id), m.last_seen_at)"
        let originalMatch = "(m.original_observed=1 AND m.original_text!='[Содержимое не было получено]' AND goldgram_contains_v1(m.original_text,terms.needle)=1)"
        let revisionMatch = """
        sr.peer_kind=m.peer_kind AND sr.peer_id=m.peer_id AND sr.message_id=m.message_id
        AND sr.content!='[Содержимое не было получено]'
        AND goldgram_contains_v1(sr.content,terms.needle)=1
        """
        var predicates = [fast ? "f.visible=1" : fastVisiblePredicate, "m.peer_kind IN (0,1,2,3)",
            "(terms.needle='' OR \(originalMatch) OR EXISTS (SELECT 1 FROM revisions sr WHERE \(revisionMatch)))"]
        var parameters: [Int64] = []
        if !search.sources.isEmpty {
            predicates.append("(" + search.sources.map { _ in "(m.peer_kind=? AND m.peer_id=?)" }.joined(separator: " OR ") + ")")
            parameters += search.sources.flatMap { [Int64($0.kind), $0.id] }
        }
        if search.event == 1 { predicates.append(edited) }
        if search.event == 2 { predicates.append(deleted) }
        if search.since > 0 {
            predicates.append(search.sentDateFilter ? "m.sent_at>=?" : "\(newest)>=?")
            parameters.append(search.since)
        }
        if let kind = search.authorKind, let id = search.authorId {
            predicates.append("m.sender_kind=? AND m.sender_id=?")
            parameters += [Int64(kind), id]
        }
        let sql = """
        WITH terms(needle) AS (VALUES (?))
        \(projection[0]),
        CASE WHEN terms.needle='' THEN NULL
             WHEN \(originalMatch) THEN m.original_text
             ELSE (SELECT sr.content FROM revisions sr WHERE \(revisionMatch)
                   ORDER BY sr.version_index DESC LIMIT 1) END AS matched_text
        FROM \(source) CROSS JOIN terms
        WHERE \(predicates.joined(separator: " AND "))
        ORDER BY \(newest) DESC, m.message_id DESC, m.peer_kind ASC, m.peer_id ASC
        LIMIT ? OFFSET ?;
        """
        var ptr: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &ptr, nil) == SQLITE_OK, let stmt = ptr else {
            if let ptr { sqlite3_finalize(ptr) }
            return ["status": "unavailable", "items": []]
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bound = search.needle.utf8CString.withUnsafeBufferPointer {
            sqlite3_bind_text(stmt, 1, $0.baseAddress, Int32($0.count - 1), transient)
        }
        guard bound == SQLITE_OK else { return ["status": "unavailable", "items": []] }
        parameters += [Int64(limit) + 1, Int64(offset)]
        for (index, value) in parameters.enumerated() {
            guard sqlite3_bind_int64(stmt, Int32(index + 2), value) == SQLITE_OK else {
                return ["status": "unavailable", "items": []]
            }
        }
        var rows: [[String: Any]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return ["status": "unavailable", "items": []] }
            var entry = decodeArchiveRow(stmt)
            entry["matchedText"] = text(stmt, 18)
            rows.append(entry)
        }
        let more = rows.count > Int(limit)
        if more { rows.removeLast() }
        return ["status": "ok", "items": rows, "hasMore": more]
    }

    private static func read(
        accountId: Int64, mode: String, kinds: [Int32],
        peerId: Int64, peerKind: Int32, sources: [(kind: Int32, id: Int64)], deletedOnly: Bool,
        offset: Int32, limit: Int32, editedOnly: Bool, diagnosticSince: Int64,
        geoSince: Int64, geoUntil: Int64, attemptTokens: [String], localSearch: LocalSearch? = nil
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

        // A single WAL snapshot for all the SELECTs in this UI response.
        guard sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK else {
            return ["status": "unavailable", "items": []]
        }
        defer { _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }

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

        if let localSearch {
            return readLocalSearch(db: db, search: localSearch, offset: offset, limit: limit)
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

        let useFastIndex = fastIndexAvailable(db) &&
            messagesSQL.components(separatedBy: "FROM messages m\n").count == 2
        var sql = useFastIndex
            ? (mode == "totals"
                ? "SELECT edited, deleted FROM goldgram_ui_fast_totals_v1 WHERE id=1;"
                : mode == "dialogs"
                    ? (deletedOnly ? fastDeletedDialogsSQL : fastDialogsSQL)
                    : fastMessagesSQL(deletedOnly: deletedOnly))
            : (mode == "totals" ? countsSQL : mode == "dialogs" ? dialogsSQL : messagesSQL)
        // #242 only alters the view filter; it never changes captured data.
        if editedOnly && useFastIndex && mode != "totals" {
            sql = sql.replacingOccurrences(of: "f.deleted=0", with: "f.edited=1")
        }
        if mode == "dialogs" {
            let placeholders = kinds.map { _ in "?" }.joined(separator: ", ")
            let target = useFastIndex ? "f" : "d"
            sql = sql.replacingOccurrences(of: "\(target).peer_kind IN (?, ?)",
                                           with: "\(target).peer_kind IN (\(placeholders))")
        }
        if !useFastIndex && deletedOnly {
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
        if !useFastIndex && !deletedOnly && mode != "totals" {
            let anchor = mode == "dialogs" ? "GROUP BY d.peer_kind" : "ORDER BY COALESCE(m.sent_at, m.last_seen_at) DESC"
            let predicate = editedOnly ? "AND (\(fastEditPredicate)) " : editedOnlyPredicate
            sql = sql.replacingOccurrences(of: anchor, with: predicate + anchor)
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
                rows.append(decodeArchiveRow(stmt))
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


    // The bridge must never guess whether PeerChannel means broadcast or
    // supergroup. Hold the whole packet in this account's existing SQLite,
    // atomically with cursor acknowledgement.
    private static func unresolvedKey(_ row: [String: Any]) -> String? {
        guard let account = row["account_id"] as? String,
              let kind = row["record_kind"] as? String,
              kind == "edit" || kind == "delete",
              let chat = row["chat_id"] as? String, chat.hasPrefix("-100"),
              let message = row["message_id"] as? String,
              let token = row["edit_event_id"] as? String,
              !token.isEmpty, token.utf8.count <= 128 else { return nil }
        let identity = [account, kind, chat, message, token].joined(separator: ":")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "iphone8.unknown.channel.v1." + digest
    }

    private static func deferUnknown(_ row: [String: Any], peerId: Int64,
                                     db: OpaquePointer) throws -> String {
        guard let key = unresolvedKey(row),
              let account = (row["account_id"] as? String).flatMap(Int64.init),
              account > 0,
              let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let payload = String(data: data, encoding: .utf8) else { return "invalid" }
        let sql = """
        INSERT OR IGNORE INTO bridge_unknown_channels_v1
            (event_key,account_id,peer_id,payload,created_at)
        VALUES(?,?,?,?,?);
        """
        var ptr: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &ptr, nil)
        guard rc == SQLITE_OK, let stmt = ptr else {
            if let ptr { sqlite3_finalize(ptr) }
            throw GoldgramHistoryStore.StorageError.sqlite(rc)
        }
        defer { sqlite3_finalize(stmt) }
        try bind(key, to: stmt, at: 1)
        guard sqlite3_bind_int64(stmt, 2, account) == SQLITE_OK,
              sqlite3_bind_int64(stmt, 3, peerId) == SQLITE_OK else {
            throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_ERROR)
        }
        try bind(payload, to: stmt, at: 4)
        guard sqlite3_bind_int64(stmt, 5, Int64(Date().timeIntervalSince1970 * 1000)) == SQLITE_OK else {
            throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_ERROR)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw GoldgramHistoryStore.StorageError.sqlite(sqlite3_errcode(db))
        }
        return sqlite3_changes(db) == 1 ? "deferredChannels" : "duplicates"
    }

    // Remove from the pending queue only inside the SAME successful import
    // transaction. A crash/ROLLBACK leaves the original payload for retry.
    private static func clearUnknown(_ row: [String: Any], db: OpaquePointer) throws {
        guard let key = unresolvedKey(row) else { return }
        var ptr: OpaquePointer?
        let rc = sqlite3_prepare_v2(db,
            "DELETE FROM bridge_unknown_channels_v1 WHERE event_key=?;", -1, &ptr, nil)
        guard rc == SQLITE_OK, let stmt = ptr else {
            if let ptr { sqlite3_finalize(ptr) }
            throw GoldgramHistoryStore.StorageError.sqlite(rc)
        }
        defer { sqlite3_finalize(stmt) }
        try bind(key, to: stmt, at: 1)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw GoldgramHistoryStore.StorageError.sqlite(sqlite3_errcode(db))
        }
    }

    // Only retry entries whose native dialog now has exactly ONE matching
    // peer kind. Bound each attempt to 40 records; no network or other DB.
    static func replayUnknown(accountId: Int64,
                              completion: @escaping ([String: Int]) -> Void) {
        func finish(_ result: [String: Int]) {
            DispatchQueue.main.async { completion(result) }
        }
        GoldgramHistoryStore.enqueueArchiveWork {
            guard GoldgramArchiveReader.activeAccountId()?.int64Value == accountId,
                  UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled"),
                  GoldgramHistoryStore.archiveIsOpen else {
                finish(["disabled": 1]); return
            }
            do {
                let db = try GoldgramHistoryStore.archiveConnection(for: accountId)
                let sql = """
                SELECT q.payload FROM bridge_unknown_channels_v1 q
                WHERE q.account_id=?
                  AND (SELECT COUNT(*) FROM dialogs d
                       WHERE d.peer_id=q.peer_id AND d.peer_kind IN (2,3))=1
                ORDER BY q.created_at,q.event_key LIMIT 20;
                """
                var ptr: OpaquePointer?
                let rc = sqlite3_prepare_v2(db, sql, -1, &ptr, nil)
                guard rc == SQLITE_OK, let stmt = ptr else {
                    if let ptr { sqlite3_finalize(ptr) }
                    if rc == SQLITE_ERROR &&
                        String(cString: sqlite3_errmsg(db)).contains("no such table") {
                        finish([:]); return
                    }
                    finish(["error": 1]); return
                }
                guard sqlite3_bind_int64(stmt, 1, accountId) == SQLITE_OK else {
                    sqlite3_finalize(stmt); finish(["error": 1]); return
                }
                var rows: [[String: Any]] = []
                var step: Int32 = SQLITE_DONE
                while true {
                    step = sqlite3_step(stmt)
                    if step != SQLITE_ROW { break }
                    if let raw = sqlite3_column_text(stmt, 0) {
                        let data = Data(bytes: raw, count: Int(sqlite3_column_bytes(stmt, 0)))
                        if let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                            rows.append(row)
                        }
                    }
                }
                sqlite3_finalize(stmt)
                guard step == SQLITE_DONE else { finish(["error": 1]); return }
                // #218: replay older #217 pending receipts without rewinding
                // the already committed Live cursors. Existing account,
                // original-evidence and chronology checks remain in force.
                let pendingSQL = """
                SELECT payload FROM bridge_merge_receipts_v2
                WHERE status='pending' AND payload IS NOT NULL
                ORDER BY updated_at,event_key LIMIT 20;
                """
                var pendingPtr: OpaquePointer?
                let pendingRC = sqlite3_prepare_v2(db, pendingSQL, -1, &pendingPtr, nil)
                if pendingRC == SQLITE_OK, let pendingStmt = pendingPtr {
                    var pendingStep: Int32 = SQLITE_DONE
                    while true {
                        pendingStep = sqlite3_step(pendingStmt)
                        if pendingStep != SQLITE_ROW { break }
                        guard let raw = sqlite3_column_text(pendingStmt, 0) else { continue }
                        let payload = Data(bytes: raw,
                            count: Int(sqlite3_column_bytes(pendingStmt, 0)))
                        guard let packet = (try? JSONSerialization.jsonObject(
                            with: payload)) as? [String: Any],
                            packet["account_id"] as? String == String(accountId),
                            packet["record_kind"] as? String == "edit" else { continue }
                        rows.append(packet)
                    }
                    sqlite3_finalize(pendingStmt)
                    guard pendingStep == SQLITE_DONE else { finish(["error": 1]); return }
                } else {
                    if let pendingPtr { sqlite3_finalize(pendingPtr) }
                    if !String(cString: sqlite3_errmsg(db)).contains("no such table") {
                        finish(["error": 1]); return
                    }
                }
                if rows.isEmpty { finish([:]); return }
                let data = try JSONSerialization.data(withJSONObject: [
                    "format": "goldgram_bridge_v2", "records": rows
                ])
                DispatchQueue.main.async {
                    importBundle(data, accountId: accountId, completion: completion)
                }
            } catch { finish(["error": 1]) }
        }
    }

    // #229: server-side send time and a real Raw-new provenance together
    // permit out-of-order receipt. A history snapshot is never enough.
    private static func verifiedLateRawOriginal(
        _ row: [String: Any], first: Int64, edited: Int64?,
        parse: (String) -> Date?
    ) -> Bool {
        guard let edited, edited > 0, edited < first,
              row["original_evidence_source"] as? String == "raw_update_new_message",
              row["original_evidence_kind"] as? String == "new_unedited",
              let sentText = row["telegram_sent_at"] as? String,
              let sentDate = parse(sentText) else { return false }
        let sent = Int64(sentDate.timeIntervalSince1970 * 1000)
        return sent > 0 && sent <= edited && sent <= first
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


    // #218: restore an older, timestamped Bridge edit BEFORE an already
    // stored newer native edit. Ambiguous chronology must remain pending.
    // All mutations run in the caller's single SQLite transaction.
    private static func restoreEarlierBridgeRevision(
        db: OpaquePointer, scope: [Int64], original: String, latest: String,
        edited: Int64, observed: Int64, key: String
    ) throws -> String? {
        guard edited > 0 else { return nil }
        let sql = """
        SELECT version_index,content,server_edit_at FROM revisions
        WHERE peer_kind=? AND peer_id=? AND message_id=?
        ORDER BY version_index ASC LIMIT 1002;
        """
        var ptr: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &ptr, nil)
        guard rc == SQLITE_OK, let stmt = ptr else {
            if let ptr { sqlite3_finalize(ptr) }
            throw GoldgramHistoryStore.StorageError.sqlite(rc)
        }
        var versions: [(index: Int64, text: String, time: Int64?)] = []
        for (i, value) in scope.enumerated() {
            guard sqlite3_bind_int64(stmt, Int32(i + 1), value) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_ERROR)
            }
        }
        var step: Int32 = SQLITE_DONE
        while true {
            step = sqlite3_step(stmt)
            if step != SQLITE_ROW { break }
            guard let raw = sqlite3_column_text(stmt, 1) else {
                sqlite3_finalize(stmt)
                throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_CORRUPT)
            }
            let text = String(decoding: UnsafeBufferPointer(
                start: raw, count: Int(sqlite3_column_bytes(stmt, 1))), as: UTF8.self)
            versions.append((
                sqlite3_column_int64(stmt, 0), text,
                sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(stmt, 2)
            ))
        }
        sqlite3_finalize(stmt)
        guard step == SQLITE_DONE else {
            throw GoldgramHistoryStore.StorageError.sqlite(step)
        }
        guard versions.count >= 2, versions.count <= 1000,
              versions[0].index == 0, versions[0].text == original,
              versions[0].time == nil else { return nil }
        var insertion: Int64?
        var previousTime: Int64 = 0
        for position in 1..<versions.count {
            let version = versions[position]
            guard version.index == Int64(position),
                  let time = version.time, time > previousTime else { return nil }
            if time == edited {
                if version.text == latest {
                    try saveReceipt(db: db, key: key,
                                    status: "already_present", payload: nil)
                    return "duplicates"
                }
                return nil
            }
            if time > edited && insertion == nil { insertion = version.index }
            previousTime = time
        }
        guard let slot = insertion, let last = versions.last?.index,
              last < Int64.max else { return nil }
        // Descending single-row shifts respect the composite UNIQUE key.
        for index in stride(from: last, through: slot, by: -1) {
            try GoldgramHistoryStore.archiveSQL("""
                UPDATE revisions SET version_index=version_index+1
                WHERE peer_kind=? AND peer_id=? AND message_id=?
                  AND version_index=?;
                """, db: db, ints: scope + [index])
            guard sqlite3_changes(db) == 1 else {
                throw GoldgramHistoryStore.StorageError.sqlite(SQLITE_CONSTRAINT)
            }
        }
        try GoldgramHistoryStore.archiveSQL("""
            INSERT INTO revisions
              (peer_kind,peer_id,message_id,version_index,observed_at,
               server_edit_at,revision_provenance,content)
            VALUES(?,?,?,?,?,?,3,?);
            """, db: db, ints: scope + [slot, observed, edited], text: latest)
        try GoldgramHistoryStore.archiveSQL("""
            INSERT OR IGNORE INTO events
              (peer_kind,peer_id,message_id,event_kind,source,
               server_time,observed_at,event_key)
            VALUES(?,?,?,1,'goldgram_iphone8_bridge_v1',?,?,?);
            """, db: db, ints: scope + [edited, observed], text: key)
        let inserted = sqlite3_changes(db) == 1
        try saveReceipt(db: db, key: key, status: "applied", payload: nil)
        return inserted ? "edits" : "duplicates"
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


    // A positive Telethon sender_id is a user peer. Negative channel sender
    // identities cannot be classified without their explicit peer type and
    // are intentionally not presented as user authors. Do not infer sent_at
    // from first_seen_at: first observation is NOT Telegram send time.
    private static func mergeVerifiedUserSender(_ row: [String: Any],
                                                db: OpaquePointer,
                                                scope: [Int64]) throws {
        guard let raw = row["sender_id"] as? String,
              let sender = Int64(raw), sender > 0 else { return }
        // Existing native metadata wins; imports only fill genuinely empty
        // fields. The update shares the importer transaction and account DB.
        try GoldgramHistoryStore.archiveSQL("""
        UPDATE messages
        SET sender_kind = CASE
                WHEN sender_id IS NULL AND sender_kind IS NULL THEN 0
                ELSE sender_kind END,
            sender_id = COALESCE(sender_id, ?)
        WHERE peer_kind=? AND peer_id=? AND message_id=?;
        """, db: db, ints: [sender] + scope)
    }

    // Bridge sends trusted Telethon Message.date (not first_seen_at or edit_date)
    // plus direct Telegram reply IDs. These are optional and never overwrite
    // verified native metadata. Original provenance and revision policy stay intact.
    private static func mergeTrustedBridgeMetadata(
        _ row: [String: Any], db: OpaquePointer, scope: [Int64],
        now: Int64, parse: (String) -> Date?
    ) throws {
        try mergeVerifiedUserSender(row, db: db, scope: scope)
        let sent: Int64 = {
            guard let iso = row["telegram_sent_at"] as? String,
                  let date = parse(iso) else { return 0 }
            let ms = date.timeIntervalSince1970 * 1000
            guard ms.isFinite, ms > 0, ms <= Double(now) + 300_000 else { return 0 }
            return Int64(ms)
        }()
        func messageId(_ key: String) -> Int64 {
            guard let raw = row[key] as? String,
                  let value = Int64(raw), value > 0,
                  value <= Int64(Int32.max) else { return 0 }
            return value
        }
        let replyId = messageId("reply_to_message_id")
        let topicTop = messageId("topic_top_message_id")
        guard sent > 0 || replyId > 0 || topicTop > 0 else { return }
        try GoldgramHistoryStore.archiveSQL("""
            UPDATE messages SET
                sent_at = COALESCE(sent_at, NULLIF(?, 0)),
                reply_to_message_id = COALESCE(reply_to_message_id, NULLIF(?, 0)),
                thread_id = COALESCE(thread_id, NULLIF(?, 0))
            WHERE peer_kind=? AND peer_id=? AND message_id=?;
        """, db: db, ints: [sent, replyId, topicTop] + scope)
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
            guard kinds.count == 1 else { return try deferUnknown(row, peerId: peerId, db: db) }
            peerKind = kinds[0]
        } else {
            return "invalid"
        }
        let scope: [Int64] = [Int64(peerKind), peerId, Int64(mid)]
        try clearUnknown(row, db: db)
        // This ID is per original deletion event, not a message-wide cursor.
        let identity = "\(peerKind):\(peerId):\(mid):\(token)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let key = "iphone8.delete.v2.\(digest)"
        if let status = try receiptStatus(db: db, key: key),
           status == "applied" || status == "already_present" {
            try mergeTrustedBridgeMetadata(row, db: db, scope: scope, now: now, parse: parse)
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
        try mergeTrustedBridgeMetadata(row, db: db, scope: scope, now: now, parse: parse)
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
            // #231: exact message scopes for post-COMMIT Postbox reconciliation.
            // No archive scan or additional Telegram request.
            var changedScopes: [[String: Int64]] = []
            var changedKeys = Set<String>()
            func markChanged(_ scope: [Int64]) {
                guard scope.count == 3, (0...3).contains(scope[0]),
                      scope[1] > 0, scope[2] > 0 else { return }
                let key = "\(scope[0]):\(scope[1]):\(scope[2])"
                if changedKeys.insert(key).inserted {
                    changedScopes.append([
                        "peerKind": scope[0], "peerId": scope[1], "messageId": scope[2]
                    ])
                }
            }
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
                    CREATE TABLE IF NOT EXISTS bridge_unknown_channels_v1 (
                        event_key TEXT PRIMARY KEY,
                        account_id INTEGER NOT NULL,
                        peer_id INTEGER NOT NULL,
                        payload TEXT NOT NULL,
                        created_at INTEGER NOT NULL
                    );
                    """, db: db, ints: [])
                    try GoldgramHistoryStore.archiveSQL("""
                    CREATE INDEX IF NOT EXISTS idx_bridge_unknown_peers_v1
                    ON bridge_unknown_channels_v1(account_id,peer_id,created_at);
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
                            } else if status == "deferredChannels" {
                                counts["pending", default: 0] += 1
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
                                let outcome = try deferUnknown(row, peerId: peerId, db: db)
                                counts[outcome, default: 0] += 1
                                if outcome == "deferredChannels" {
                                    counts["pending", default: 0] += 1
                                }
                                continue
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
                        try clearUnknown(row, db: db)
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
                            try mergeTrustedBridgeMetadata(row, db: db, scope: scope, now: now, parse: parse)
                            // #232: a committed receipt may have been delivered
                            // before the Postbox message was locally available.
                            // Retry inline reconciliation without duplicating
                            // the original, revisions or the Live cursor.
                            markChanged(scope)
                            counts["duplicates", default: 0] += 1; continue
                        }
                        // If Telegram's server edit predates the FIRST observation
                        // on iPhone 8, there is no reliable proof that the supplied
                        // "original_text" was observed before the edit. Keep the
                        // entire remote event in the SAME SQLite for later review,
                        // without declaring a verified original or adding a revision.
                        // Saving the pending receipt in this transaction allows the
                        // live cursor to advance after COMMIT and unblock safe rows.
                        let provenLate = verifiedLateRawOriginal(
                            row, first: first, edited: edited, parse: parse)
                        if provenLate {
                            // Replay a previously held real original without
                            // rewinding committed cursors or trusting snapshots.
                            let localOriginal = try originalInArchive(db: db, scope: scope)
                            if localOriginal == nil || localOriginal == original {
                                try GoldgramHistoryStore.archiveSQL(
                                    "DELETE FROM bridge_chronology_holds_v1 WHERE peer_kind=? AND peer_id=? AND message_id=?;",
                                    db: db, ints: scope)
                            }
                        }
                        let chronologyBroken = edited != nil && edited! < first && !provenLate
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
                        // #218: native Swiftgram may already know the final edit.
                        // Backfill only with a verified original and strict
                        // source/server chronology; no guesswork for ambiguous edits.
                        if !latestAlreadySeen && !canAppend &&
                            knownOriginal == original, let sourceTime = edited,
                            let recovered = try restoreEarlierBridgeRevision(
                                db: db, scope: scope, original: original,
                                latest: latest, edited: sourceTime, observed: observed,
                                key: key) {
                            try mergeTrustedBridgeMetadata(row, db: db, scope: scope,
                                                           now: now, parse: parse)
                            counts[recovered, default: 0] += 1
                            if recovered == "edits" { markChanged(scope) }
                            continue
                        }
                        let firstOriginal = knownOriginal == nil
                        try GoldgramHistoryStore.archiveSQL(
                            "INSERT OR IGNORE INTO dialogs(peer_kind,peer_id) VALUES(?,?);",
                            db: db, ints: [Int64(peerKind), peerId])
                        try GoldgramHistoryStore.archiveSQL(
                            "INSERT OR IGNORE INTO messages(peer_kind,peer_id,message_id,first_seen_at,last_seen_at,original_observed,capture_provenance,original_text) VALUES(?,?,?,?,?,1,3,?);",
                            db: db, ints: scope + [first, now], text: original)
                        try mergeTrustedBridgeMetadata(row, db: db, scope: scope, now: now, parse: parse)
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
                            markChanged(scope)
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
                        markChanged(scope)
                    }
                    try GoldgramHistoryStore.archiveSQL("COMMIT;", db: db, ints: [])
                } catch {
                    try? GoldgramHistoryStore.archiveSQL("ROLLBACK;", db: db, ints: [])
                    throw error
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("GoldgramArchiveChanged"),
                        object: NSNumber(value: accountId),
                        userInfo: changedScopes.isEmpty ? nil : ["inlineScopes": changedScopes])
                }
                finish(counts)
            } catch {
                finish(["error": 1])
            }
        }
    }
}


// Goldgram #223: a verified, bounded read for the existing gray inline
// "Изменение N" rows in chat. Called only from a background Postbox transaction,
// never from chat layout. The caller owns the returned JSON and frees it.
// No new database, cursor changes, or in-memory guess of missing versions.
@_cdecl("goldgram_verified_inline_history_v1")
public func goldgramVerifiedInlineHistoryV1(
    _ accountId: Int64, _ peerKind: Int32, _ peerId: Int64, _ messageId: Int32
) -> UnsafeMutablePointer<CChar>? {
    guard accountId > 0, (0...3).contains(peerKind), peerId > 0, messageId > 0,
          UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled"),
          GoldgramArchiveReader.activeAccountId()?.int64Value == accountId else { return nil }
    return GoldgramHistoryStore.storageQueue.sync {
        guard GoldgramHistoryStore.archiveIsOpen,
              let db = try? GoldgramHistoryStore.archiveConnection(for: accountId) else { return nil }
        var head: OpaquePointer?
        let headSQL = """
        SELECT original_text FROM messages
        WHERE peer_kind=? AND peer_id=? AND message_id=?
          AND original_observed=1 AND original_text IS NOT NULL LIMIT 1;
        """
        guard sqlite3_prepare_v2(db, headSQL, -1, &head, nil) == SQLITE_OK,
              let header = head else {
            if let head { sqlite3_finalize(head) }
            return nil
        }
        defer { sqlite3_finalize(header) }
        guard sqlite3_bind_int(header, 1, peerKind) == SQLITE_OK,
              sqlite3_bind_int64(header, 2, peerId) == SQLITE_OK,
              sqlite3_bind_int(header, 3, messageId) == SQLITE_OK,
              sqlite3_step(header) == SQLITE_ROW,
              let originalBytes = sqlite3_column_text(header, 0),
              sqlite3_column_bytes(header, 0) <= 65536 else { return nil }
        let original = String(decoding: UnsafeBufferPointer(
            start: originalBytes, count: Int(sqlite3_column_bytes(header, 0))), as: UTF8.self)

        var rows: OpaquePointer?
        let revisionsSQL = """
        SELECT version_index, content, server_edit_at FROM revisions
        WHERE peer_kind=? AND peer_id=? AND message_id=?
        ORDER BY version_index ASC LIMIT 250;
        """
        guard sqlite3_prepare_v2(db, revisionsSQL, -1, &rows, nil) == SQLITE_OK,
              let revisionsStmt = rows else {
            if let rows { sqlite3_finalize(rows) }
            return nil
        }
        defer { sqlite3_finalize(revisionsStmt) }
        guard sqlite3_bind_int(revisionsStmt, 1, peerKind) == SQLITE_OK,
              sqlite3_bind_int64(revisionsStmt, 2, peerId) == SQLITE_OK,
              sqlite3_bind_int(revisionsStmt, 3, messageId) == SQLITE_OK else { return nil }
        var revisions: [String] = []
        var dates: [Int32] = []
        var expectedIndex: Int64 = 0
        var totalBytes = original.utf8.count
        var outcome: Int32 = SQLITE_DONE
        while true {
            outcome = sqlite3_step(revisionsStmt)
            if outcome != SQLITE_ROW { break }
            guard sqlite3_column_int64(revisionsStmt, 0) == expectedIndex,
                  let bytes = sqlite3_column_text(revisionsStmt, 1),
                  sqlite3_column_bytes(revisionsStmt, 1) <= 65536 else { return nil }
            let body = String(decoding: UnsafeBufferPointer(
                start: bytes, count: Int(sqlite3_column_bytes(revisionsStmt, 1))), as: UTF8.self)
            totalBytes += body.utf8.count
            guard totalBytes <= 300000 else { return nil }
            if expectedIndex == 0 {
                // A confirmed original must occupy slot zero; never relabel an edit.
                guard original == body else { return nil }
            } else {
                revisions.append(body)
                let milliseconds = sqlite3_column_type(revisionsStmt, 2) == SQLITE_NULL
                    ? Int64(0) : sqlite3_column_int64(revisionsStmt, 2)
                dates.append(milliseconds > 0 ? Int32(clamping: milliseconds / 1000) : 0)
            }
            expectedIndex += 1
        }
        guard outcome == SQLITE_DONE, expectedIndex >= 2, !revisions.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: [
                  "baseline": original, "revisions": revisions, "dates": dates
              ]),
              json.count <= 350000,
              let text = String(data: json, encoding: .utf8) else { return nil }
        return strdup(text)
    }
}

extension GoldgramHistoryStore {
    // #218: full local history, read on the existing account SQLite queue.
    static func readPhone8RevisionHistory(
        accountId: Int64, peerKind: Int32, peerId: Int64, messageId: Int32,
        completion: @escaping ([[String: Any]]) -> Void
    ) {
        func finish(_ value: [[String: Any]]) {
            DispatchQueue.main.async { completion(value) }
        }
        guard accountId > 0, (0...3).contains(peerKind),
              peerId > 0, messageId > 0 else { finish([]); return }
        enqueueArchiveWork {
            guard GoldgramArchiveReader.activeAccountId()?.int64Value == accountId,
                  self.archiveIsOpen else { finish([]); return }
            do {
                let db = try archiveConnection(for: accountId)
                var ptr: OpaquePointer?
                let sql = """
                SELECT version_index,content,server_edit_at FROM revisions
                WHERE peer_kind=? AND peer_id=? AND message_id=?
                ORDER BY version_index ASC LIMIT 250;
                """
                let rc = sqlite3_prepare_v2(db, sql, -1, &ptr, nil)
                guard rc == SQLITE_OK, let stmt = ptr else {
                    if let ptr { sqlite3_finalize(ptr) }
                    finish([]); return
                }
                for (i, value) in [Int64(peerKind), peerId, Int64(messageId)].enumerated() {
                    if sqlite3_bind_int64(stmt, Int32(i + 1), value) != SQLITE_OK {
                        sqlite3_finalize(stmt); finish([]); return
                    }
                }
                var versions: [[String: Any]] = []
                var step: Int32 = SQLITE_DONE
                while true {
                    step = sqlite3_step(stmt)
                    if step != SQLITE_ROW { break }
                    guard let raw = sqlite3_column_text(stmt, 1) else { continue }
                    let body = String(decoding: UnsafeBufferPointer(start: raw,
                        count: Int(sqlite3_column_bytes(stmt, 1))), as: UTF8.self)
                    versions.append([
                        "index": NSNumber(value: sqlite3_column_int64(stmt, 0)),
                        "text": body,
                        "edited": sqlite3_column_type(stmt, 2) == SQLITE_NULL
                            ? NSNull() : NSNumber(value: sqlite3_column_int64(stmt, 2))
                    ])
                }
                sqlite3_finalize(stmt)
                finish(step == SQLITE_DONE ? versions : [])
            } catch { finish([]) }
        }
    }

    // #232: local-only, incremental catch-up of history imported before #231.
    // Walk newest archived messages first, never reset Live/MTProto cursors.
    // A poll touches at most 48 verified message IDs, not the entire history.
    // Candidate content stays in SQLite; only peer/message IDs enter the
    // already account-scoped GoldgramArchiveChanged notification.
    static func notifyPreviouslyImportedInline(accountId: Int64) {
        guard accountId > 0 else { return }
        storageQueue.async {
            guard GoldgramArchiveReader.activeAccountId()?.int64Value == accountId,
                  UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled"),
                  archiveIsOpen,
                  let db = try? archiveConnection(for: accountId) else { return }
            let key = "GoldgramInlineBackfillRowidV1.\(accountId)"
            let cursor = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value
                ?? Int64.max
            let sql = """
            SELECT m.rowid, m.peer_kind, m.peer_id, m.message_id
            FROM messages m
            WHERE m.rowid < ?
              AND m.original_observed=1 AND m.original_text IS NOT NULL
              AND EXISTS (
                  SELECT 1 FROM revisions r
                  WHERE r.peer_kind=m.peer_kind AND r.peer_id=m.peer_id
                    AND r.message_id=m.message_id AND r.version_index=1
              )
            ORDER BY m.rowid DESC LIMIT 48;
            """
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK,
                  let stmt = pointer else {
                if let pointer { sqlite3_finalize(pointer) }
                return
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_bind_int64(stmt, 1, cursor) == SQLITE_OK else { return }
            var scopes: [[String: Int64]] = []
            var lastRowid: Int64?
            var result: Int32 = SQLITE_DONE
            while true {
                result = sqlite3_step(stmt)
                guard result == SQLITE_ROW else { break }
                let rowid = sqlite3_column_int64(stmt, 0)
                let kind = sqlite3_column_int64(stmt, 1)
                let peer = sqlite3_column_int64(stmt, 2)
                let message = sqlite3_column_int64(stmt, 3)
                lastRowid = rowid
                if (0...3).contains(kind), peer > 0, message > 0 {
                    scopes.append([
                        "peerKind": kind, "peerId": peer, "messageId": message
                    ])
                }
            }
            guard result == SQLITE_DONE else { return }
            // The next idle poll starts at the newest record after the end.
            // This deliberately cycles: a suspended Postbox transaction gets
            // another opportunity without depending on the user scrolling.
            UserDefaults.standard.set(lastRowid ?? Int64.max, forKey: key)
            guard !scopes.isEmpty else { return }
            DispatchQueue.main.async {
                guard GoldgramArchiveReader.activeAccountId()?.int64Value == accountId else { return }
                NotificationCenter.default.post(
                    name: Notification.Name("GoldgramArchiveChanged"),
                    object: NSNumber(value: accountId),
                    userInfo: ["inlineScopes": scopes, "inlineOnly": true])
            }
        }
    }

    static func importPhone8Bundle(_ data: Data, accountId: Int64,
                                   completion: @escaping ([String: Int]) -> Void) {
        GoldgramPhone8Bridge.importBundle(data, accountId: accountId, completion: completion)
    }

    static func replayPhone8Unknown(accountId: Int64,
                                    completion: @escaping ([String: Int]) -> Void) {
        GoldgramPhone8Bridge.replayUnknown(accountId: accountId, completion: completion)
    }
}


// Goldgram Live receiver: foreground-only TLS-pinned pull from jailbroken iPhone 8.
// No second SQLite; receipts and edits use the existing Goldgram import transaction.
// No reliance on a persistent SSH/Termius session or on iOS running while suspended.

// #225: pure, bounded retry decisions for the existing pinned Live transport.
// A rate limit is never bypassed by rebuilding TLS or by changing networks.
enum GoldgramLiveRetryPolicy {
    static func retryAfterSeconds(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return min(86_400, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) {
            return min(86_400, max(0, date.timeIntervalSince(now)))
        }
        return nil
    }

    static func exponential(_ failureCount: Int, initial: Int, cap: Int) -> Int {
        let shift = max(0, min(7, failureCount - 1))
        return min(cap, initial * (1 << shift))
    }

    static func httpDelay(_ code: Int, retryAfter: String?,
                          failures: Int, now: Date = Date()) -> TimeInterval {
        let suggested = retryAfterSeconds(retryAfter, now: now)
        if code == 429 {
            return min(86_400, max(30, suggested ?? Double(exponential(
                failures, initial: 30, cap: 1_800))))
        }
        if (500...599).contains(code) {
            return min(86_400, max(
                Double(exponential(failures, initial: 8, cap: 300)),
                suggested ?? 0))
        }
        // Unauthorized or malformed response: don't hammer the endpoint.
        return 300
    }

    static func networkDelay(_ failures: Int) -> TimeInterval {
        Double(exponential(failures, initial: 3, cap: 120))
    }

    static func isTLSError(_ code: Int) -> Bool {
        (-1206 ... -1200).contains(code)
    }

    static func isConnectionError(_ code: Int) -> Bool {
        [-1001, -1003, -1004, -1005, -1009, -1200].contains(code)
    }
}

// #227: pure route selection. Both endpoints are the SAME pinned iPhone 8
// archive; no independent cursors or speculative parallel import.
enum GoldgramLiveRoutePolicy {
    static let f3Host = "179.253.88.30"
    static let defaultLANHost = "192.168.1.102"
    static let localRetrySeconds: TimeInterval = 120
    static let localPinRetrySeconds: TimeInterval = 600

    static func selectedHost(wifi: Bool, localHost: String,
                             now: TimeInterval, localRetryAt: TimeInterval) -> String {
        wifi && now >= localRetryAt ? localHost : f3Host
    }
}

final class GoldgramLiveBridge: NSObject, URLSessionDelegate {
    static let shared = GoldgramLiveBridge()
    private let defaults = UserDefaults.standard
    private let tokenService = "com.goldgram.livebridge.iphone8"
    private var timer: DispatchSourceTimer?
    private var session: URLSession?
    private var runningAccount: Int64?
    private var inFlight = false
    // Enabled only after a successful feature advertisement from V216.
    // This keeps V215 and the same account/pin working unchanged.
    private var proofCapable = false
    private var lastInlineSweep: TimeInterval = 0
    private var runToken: UInt64 = 0
    // Only the Main queue mutates the transport state; URLSession's challenge
    // delegate uses this lock solely for the expected certificate hash.
    private let pinLock = NSLock()
    private var expectedPin = ""
    private var pinRejected = false
    private var activePinnedSession: ObjectIdentifier?
    private var sessionHost: String?
    private var wifiAvailable = false
    private var localRetryAt: TimeInterval = 0
    private var retryNotBefore: TimeInterval = 0
    private var rateLimitedUntil: TimeInterval = 0
    private var consecutiveFailures = 0
    private var certificateBlocked = false
    #if canImport(Network) && os(iOS)
    private var networkMonitor: NWPathMonitor?
    private let networkMonitorQueue = DispatchQueue(label: "goldgram.live.path", qos: .utility)
    private var previousNetworkSignature: String?
    private var networkChangeWork: DispatchWorkItem?
    #endif
    private(set) var lastStatus = "Live не настроен"

    private override init() {
        super.init()
        #if os(iOS)
        NotificationCenter.default.addObserver(self,
            selector: #selector(activated),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        #endif
        #if canImport(Network) && os(iOS)
        // VPN/Wi-Fi/LTE route changes may not throw a URLSession error until
        // the next request. Rebuild the transport (not its SQLite cursors)
        // when the monitored route changes. Keep HTTP 429 backoff intact.
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status):\(path.usesInterfaceType(.wifi)):\(path.usesInterfaceType(.cellular)):\(path.usesInterfaceType(.other))"
            let available = path.status == .satisfied
            let wifi = available && path.usesInterfaceType(.wifi)
            DispatchQueue.main.async { [weak self] in
                self?.networkPathChanged(signature: signature,
                                         available: available, wifi: wifi)
            }
        }
        monitor.start(queue: networkMonitorQueue)
        #endif
    }

    #if canImport(Network) && os(iOS)
    private func networkPathChanged(signature: String, available: Bool, wifi: Bool) {
        let wasWiFi = wifiAvailable
        wifiAvailable = wifi
        if wifi && !wasWiFi { localRetryAt = 0 }
        let previous = previousNetworkSignature
        previousNetworkSignature = signature
        if previous == nil {
            // The first path event may arrive after a remote request started.
            // Restart it with the preferred route without moving cursors.
            if runningAccount != nil && !certificateBlocked {
                renewSession()
                poll()
            }
            return
        }
        guard previous != signature, runningAccount != nil,
              !certificateBlocked else { return }
        networkChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.runningAccount != nil else { return }
            self.renewSession()
            if available {
                // A change of route may clear a transport failure, but a
                // server-enforced rate limit survives the network change.
                let now = ProcessInfo.processInfo.systemUptime
                if self.rateLimitedUntil <= now {
                    self.retryNotBefore = 0
                    self.consecutiveFailures = 0
                }
                self.poll()
            } else {
                self.status("Live: сеть недоступна; HTTPS восстановится при подключении")
            }
        }
        networkChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
    }
    #endif

    private func setExpectedPin(_ pin: String) {
        pinLock.lock()
        expectedPin = pin
        pinRejected = false
        activePinnedSession = nil
        pinLock.unlock()
    }

    private func didRejectCertificate() -> Bool {
        pinLock.lock()
        defer { pinLock.unlock() }
        return pinRejected
    }

    private func clearPinRejection() {
        pinLock.lock()
        pinRejected = false
        pinLock.unlock()
    }

    // Recreate just URLSession; never touch the paired identity, archive,
    // imported records or event cursors. Old callbacks are rejected by token.
    private func createHTTPSession(host: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        let local = Self.privateIPv4(host)
        configuration.timeoutIntervalForRequest = local ? 10 : 20
        configuration.timeoutIntervalForResource = local ? 15 : 35
        configuration.waitsForConnectivity = !local
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let newSession = URLSession(configuration: configuration,
                                    delegate: self, delegateQueue: nil)
        pinLock.lock()
        activePinnedSession = ObjectIdentifier(newSession)
        pinRejected = false
        pinLock.unlock()
        return newSession
    }

    private func renewSession(host override: String? = nil) {
        guard let account = runningAccount else { return }
        let host = override ?? selectedHost(account: account)
        runToken &+= 1
        let old = session
        session = createHTTPSession(host: host)
        sessionHost = host
        inFlight = false
        old?.invalidateAndCancel()
    }

    private func failTransport(_ reason: String, errorCode: Int,
                               shouldRenew: Bool, attemptedHost: String) {
        inFlight = false
        let pinMismatch = didRejectCertificate()
        let now = ProcessInfo.processInfo.systemUptime
        if let account = runningAccount,
           automaticRoutingEnabled(account: account),
           attemptedHost == automaticLANHost(account: account),
           wifiAvailable {
            // On an unfamiliar Wi-Fi, 192.168.1.102 may not be our phone.
            // A failed TLS challenge sends no HTTP token. The next F3
            // connection independently requires the SAME pinned certificate.
            localRetryAt = now + (pinMismatch
                ? GoldgramLiveRoutePolicy.localPinRetrySeconds
                : GoldgramLiveRoutePolicy.localRetrySeconds)
            clearPinRejection()
            retryNotBefore = max(rateLimitedUntil, now + 2)
            renewSession(host: GoldgramLiveRoutePolicy.f3Host)
            let ticket = runToken
            status(pinMismatch
                ? "Live авто: чужой TLS-сертификат в локальной сети; пробуем F3 с прежним PIN"
                : "Live авто: локальный iPhone 8 недоступен [\(errorCode)]; подключаем F3")
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
                guard let self, self.runToken == ticket else { return }
                self.poll()
            }
            return
        }
        if pinMismatch {
            certificateBlocked = true
            status("Live TLS: сертификат не совпал с закреплённым SHA-256; автоматические повторы остановлены")
            return
        }
        consecutiveFailures = min(20, consecutiveFailures + 1)
        let delay = GoldgramLiveRetryPolicy.networkDelay(consecutiveFailures)
        retryNotBefore = max(rateLimitedUntil, now + delay)
        if shouldRenew { renewSession() }
        let category = GoldgramLiveRetryPolicy.isTLSError(errorCode) ? "TLS" : "HTTPS"
        status("Live \(category): \(reason) [\(errorCode)]; повтор через \(Int(delay)) с")
    }

    private func failHTTP(_ code: Int, retryAfter: String?) {
        inFlight = false
        consecutiveFailures = min(20, consecutiveFailures + 1)
        let delay = GoldgramLiveRetryPolicy.httpDelay(
            code, retryAfter: retryAfter, failures: consecutiveFailures)
        retryNotBefore = ProcessInfo.processInfo.systemUptime + delay
        if code == 429 {
            rateLimitedUntil = retryNotBefore
        }
        if code == 502 || code == 503 || code == 504 {
            renewSession()
        }
        let detail = code == 429 ? "лимит запросов" :
            (500...599).contains(code) ? "временная ошибка сервера" :
            (code == 401 || code == 403) ? "доступ запрещён" : "неожиданный ответ"
        status("Live HTTP \(code): \(detail); повтор через \(Int(ceil(delay))) с")
    }

    private func key(_ account: Int64, _ name: String) -> String {
        "GoldgramLiveV1.\(account).\(name)"
    }

    func automaticRoutingEnabled(account: Int64) -> Bool {
        defaults.bool(forKey: key(account, "automaticRoute"))
    }

    private func automaticLANHost(account: Int64) -> String {
        let stored = defaults.string(forKey: key(account, "lastLANHost")) ?? ""
        return Self.privateIPv4(stored) ? stored : GoldgramLiveRoutePolicy.defaultLANHost
    }

    private func selectedHost(account: Int64) -> String {
        guard automaticRoutingEnabled(account: account) else {
            return configuredHost(account: account)
        }
        return GoldgramLiveRoutePolicy.selectedHost(
            wifi: wifiAvailable, localHost: automaticLANHost(account: account),
            now: ProcessInfo.processInfo.systemUptime, localRetryAt: localRetryAt)
    }

    func currentRouteDescription(account: Int64) -> String {
        guard automaticRoutingEnabled(account: account) else {
            return "Ручной: \(configuredHost(account: account))"
        }
        let host = runningAccount == account ? (sessionHost ?? selectedHost(account: account)) :
            selectedHost(account: account)
        return host == GoldgramLiveRoutePolicy.f3Host ?
            "Авто: F3 Cloud (HTTPS/443)" : "Авто: локальный Wi-Fi (\(host):8873)"
    }

    @discardableResult
    func setAutomaticRouting(account: Int64, enabled: Bool) -> Bool {
        guard account > 0, isEnabled(account: account),
              readSecret(account: account) != nil else { return false }
        defaults.set(enabled, forKey: key(account, "automaticRoute"))
        stop()
        start(account: account)
        poll()
        return true
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

    // #226: two explicitly approved public TCP relays for the same pinned
    // iPhone 8 source. Each relay only forwards TLS; neither is trusted to
    // change the certificate, token, account or committed SQLite cursors.
    private static let publicRelays: Set<String> = [
        "194.87.235.144", // RUVDS — preserved fallback
        "179.253.88.30"   // F3 Cloud
    ]

    // #224: fast LAN catch-up only. Keep the gentler backoff for the VPS.
    // Both paths retain the single in-flight gate and cursor-after-COMMIT.
    static func catchupDelayMs(host: String) -> Int {
        // #235: same single in-flight gate and HTTP Retry-After policy.
        // Reserve RUVDS remains conservative; F3 and LAN catch up faster.
        privateIPv4(host) ? 40 : (host == GoldgramLiveRoutePolicy.f3Host ? 150 : 600)
    }

    static func supportedHost(_ value: String) -> Bool {
        privateIPv4(value) || publicRelays.contains(value)
    }

    static func port(for host: String) -> Int {
        publicRelays.contains(host) ? 443 : 8873
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
        guard account > 0, Self.supportedHost(normalizedHost),
              normalizedPin.count == 64,
              normalizedPin.allSatisfy({ $0.isHexDigit }) else {
            lastStatus = "Неверный IP или отпечаток сертификата"
            return false
        }
        // Re-pairing to the same pinned iPhone 8 through the VPS does not
        // require copying the existing Keychain secret again.
        if normalizedToken.isEmpty {
            guard readSecret(account: account) != nil else {
                lastStatus = "Не задан секрет подключения"
                return false
            }
        } else {
            guard normalizedToken.count == 64,
                  normalizedToken.allSatisfy({ $0.isHexDigit }),
                  storeSecret(normalizedToken, account: account) else {
                lastStatus = "Неверный секрет подключения"
                return false
            }
        }
        let oldPin = configuredPin(account: account)
        // The source identity is the certificate, not its LAN/WAN address.
        // Keep committed import cursors when switching to the same pinned host.
        if oldPin != normalizedPin {
            defaults.removeObject(forKey: key(account, "editsCursor"))
            defaults.removeObject(forKey: key(account, "deletionsCursor"))
        }
        defaults.set(normalizedHost, forKey: key(account, "host"))
        if Self.privateIPv4(normalizedHost) {
            defaults.set(normalizedHost, forKey: key(account, "lastLANHost"))
        }
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
        sessionHost = nil
        pinLock.lock()
        activePinnedSession = nil
        pinRejected = false
        pinLock.unlock()
        runningAccount = nil
        inFlight = false
        proofCapable = false
        lastInlineSweep = 0
        localRetryAt = 0
        retryNotBefore = 0
        rateLimitedUntil = 0
        consecutiveFailures = 0
        certificateBlocked = false
        #if canImport(Network) && os(iOS)
        networkChangeWork?.cancel()
        networkChangeWork = nil
        #endif
    }

    func disable(account: Int64) {
        defaults.set(false, forKey: key(account, "enabled"))
        stop()
        lastStatus = "Live отключён; архив не изменён"
    }

    func start(account: Int64) {
        guard account > 0, isEnabled(account: account),
              Self.supportedHost(configuredHost(account: account)),
              configuredPin(account: account).count == 64,
              readSecret(account: account) != nil else {
            return
        }
        if runningAccount == account && timer != nil { return }
        stop()
        runningAccount = account
        setExpectedPin(configuredPin(account: account))
        let host = selectedHost(account: account)
        session = createHTTPSession(host: host)
        sessionHost = host
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
        if certificateBlocked {
            status("Live TLS: сертификат не совпадает с сохранённым; проверь подключение")
            return
        }
        let remain = retryNotBefore - ProcessInfo.processInfo.systemUptime
        if remain > 0 {
            status("Live: повторный запрос через \(Int(ceil(remain))) с (ограничение сервера или восстановление сети)")
            return
        }
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
        guard !certificateBlocked,
              ProcessInfo.processInfo.systemUptime >= retryNotBefore,
              !inFlight, let account = runningAccount,
              GoldgramArchiveReader.activeAccountId()?.int64Value == account,
              defaults.bool(forKey: "GoldgramSQLiteCaptureEnabled"),
              let token = readSecret(account: account) else { return }
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        #endif
        let edits = max(0, defaults.integer(forKey: key(account, "editsCursor")))
        let deletions = max(0, defaults.integer(forKey: key(account, "deletionsCursor")))
        let proofs = max(0, defaults.integer(forKey: key(account, "proofCursor")))
        let proofSuffix = proofCapable ? "&proofs_after=\(proofs)" : ""
        let host = selectedHost(account: account)
        if sessionHost != host { renewSession(host: host) }
        guard let session, let url = URL(string:
            "https://\(host):\(Self.port(for: host))/v1/events?edits_after=\(edits)&deletions_after=\(deletions)\(proofSuffix)") else {
            return
        }
        inFlight = true
        let ticket = runToken
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Goldgram-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Bound the initial local attempt so a dead LAN doesn't stall F3.
        if automaticRoutingEnabled(account: account),
           host == automaticLANHost(account: account) {
            request.timeoutInterval = 5
        }
        let requestStartedAt = ProcessInfo.processInfo.systemUptime
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let responseReceivedAt = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.runningAccount == account, self.runToken == ticket else { return }
                if let error {
                    let nsError = error as NSError
                    self.failTransport(
                        nsError.domain == NSURLErrorDomain ? "ошибка соединения" : "ошибка транспорта",
                        errorCode: nsError.code,
                        shouldRenew: nsError.domain == NSURLErrorDomain &&
                            GoldgramLiveRetryPolicy.isConnectionError(nsError.code),
                        attemptedHost: host)
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.failHTTP(503, retryAfter: nil)
                    return
                }
                if httpResponse.statusCode != 200 {
                    self.failHTTP(httpResponse.statusCode,
                        retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After"))
                    return
                }
                guard let data, data.count <= 1_000_000,
                      let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      payload["format"] as? String == "goldgram_bridge_v2",
                      let rows = payload["records"] as? [[String: Any]],
                      rows.count <= 40,
                      let nextEdits = payload["next_edit_cursor"] as? Int,
                      let nextDeletes = payload["next_delete_cursor"] as? Int,
                      (payload["next_proof_cursor"] as? Int ?? proofs) >= proofs,
                      nextEdits >= edits, nextDeletes >= deletions else {
                    self.failHTTP(422, retryAfter: nil)
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
                    self.consecutiveFailures = 0
                    self.retryNotBefore = 0
                    self.rateLimitedUntil = 0
                    self.defaults.set(nextEdits, forKey: self.key(account, "editsCursor"))
                    self.defaults.set(nextDeletes, forKey: self.key(account, "deletionsCursor"))
                    let nextProofs = payload["next_proof_cursor"] as? Int ?? proofs
                    self.defaults.set(nextProofs, forKey: self.key(account, "proofCursor"))
                    self.proofCapable = (payload["proof_protocol"] as? Int == 1)
                    GoldgramArchiveReader.runJournalAutoclearIfDue(
                        forAccount: NSNumber(value: account))
                    // #235: new data still reconciles from its own COMMIT.
                    // The optional historical sweep must not compete with
                    // every 40-row catch-up packet. Keep it alive on idle
                    // polls and at most once per 30s during sustained backlog.
                    let advanced = nextEdits > edits || nextDeletes > deletions || nextProofs > proofs
                    let sweepNow = ProcessInfo.processInfo.systemUptime
                    if (!advanced && rows.isEmpty) || sweepNow - self.lastInlineSweep >= 30 {
                        self.lastInlineSweep = sweepNow
                        GoldgramHistoryStore.notifyPreviouslyImportedInline(accountId: account)
                    }
                    let changes = (result["edits"] ?? 0) + (result["deletions"] ?? 0)
                    let imported = result["imported"] ?? 0
                    let pending = result["pending"] ?? 0
                    let deferred = result["deferredChannels"] ?? 0
                    let chronologyPending = result["chronologyPending"] ?? 0
                    // Monotonic, content-free timings: receive + SQLite import/
                    // replay. No message text, credentials or peer IDs in status.
                    let now = ProcessInfo.processInfo.systemUptime
                    let networkMs = max(0, Int((responseReceivedAt - requestStartedAt) * 1000))
                    let importMs = max(0, Int((now - responseReceivedAt) * 1000))
                    let routeLabel = self.automaticRoutingEnabled(account: account) ?
                        (host == GoldgramLiveRoutePolicy.f3Host ? "F3 Cloud" : "Wi-Fi") : "ручной \(host)"
                    self.status("Live [\(routeLabel)]: +\(changes) событий, +\(imported) оригиналов, отложено каналов \(deferred), спорных \(pending) (хронология: \(chronologyPending)), курсоры \(nextEdits)/\(nextDeletes); сеть \(networkMs) мс, импорт \(importMs) мс")
                    // Catch up the old archive quickly without waiting one
                    // 12-second interval per historical batch. Limited by
                    // the importer transaction and its single in-flight gate.
                    if advanced {
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + .milliseconds(Self.catchupDelayMs(host: host))) { [weak self] in
                            guard let self, self.runToken == ticket else { return }
                            self.poll()
                        }
                    }
                }
                if rows.isEmpty {
                    GoldgramHistoryStore.replayPhone8Unknown(
                        accountId: account, completion: commitCursor)
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
        pinLock.lock()
        let currentSession = activePinnedSession == ObjectIdentifier(session)
        let matchingPin = currentSession && digest == expectedPin
        if currentSession && !matchingPin { pinRejected = true }
        pinLock.unlock()
        guard matchingPin else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Intentional certificate pin for a single self-signed certificate.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}


// Goldgram #221 — chat badge bridge. The UI never performs SQLite I/O
// during chat layout; the keyed cache loads on the existing archive queue.
// No Telegram requests, second database, duplicate message body storage,
// or changes to MX's independent edit-history tracker.
fileprivate enum GoldgramChatEditBadge {
    struct Entry {
        let count: Int32
        let peerKind: Int32
        let peerId: Int64
    }
    private static let lock = NSLock()
    private static var cache: [String: Entry] = [:]
    private static var pending = Set<String>()
    private static var epoch: UInt64 = 0

    static func reset() {
        lock.lock()
        epoch &+= 1
        cache.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    static func entry(peerKey: Int64, messageId: Int32) -> Entry? {
        guard let account = GoldgramArchiveReader.activeAccountId()?.int64Value,
              account > 0, peerKey != 0, messageId > 0,
              UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled") else { return nil }
        let key = "\(account):\(peerKey):\(messageId)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached.count >= 0 ? cached : nil
        }
        if pending.contains(key) {
            lock.unlock()
            return nil
        }
        pending.insert(key)
        let requestedEpoch = epoch
        lock.unlock()

        GoldgramHistoryStore.storageQueue.async {
            let result = try? load(account: account, peerKey: peerKey, messageId: messageId)
            lock.lock()
            let valid = epoch == requestedEpoch
            if valid {
                cache[key] = result ?? Entry(count: -1, peerKind: 0, peerId: 0)
                // Cap idle cache growth without touching the production SQLite.
                if cache.count > 2500 { cache.removeAll(keepingCapacity: true) }
                pending.remove(key)
            }
            lock.unlock()
            if valid {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("GoldgramChatHistoryBadgeChanged"),
                        object: nil, userInfo: ["ids": [NSNumber(value: messageId)]])
                }
            }
        }
        return nil
    }

    private static func load(
        account: Int64, peerKey: Int64, messageId: Int32
    ) throws -> Entry? {
        guard GoldgramHistoryStore.archiveIsOpen else { return nil }
        let db = try GoldgramHistoryStore.archiveConnection(for: account)
        let peerKind: Int32
        let peerId: Int64
        if peerKey > 0 {
            peerKind = 0
            peerId = peerKey
        } else if peerKey < -1_000_000_000_000 &&
                  peerKey > -2_000_000_000_000 {
            peerId = -(peerKey + 1_000_000_000_000)
            // PeerChannel may mean broadcast channel OR supergroup.
            // Require exactly one known native dialog classification.
            var kinds: OpaquePointer?
            let rc = sqlite3_prepare_v2(db,
                "SELECT peer_kind FROM dialogs WHERE peer_id=? AND peer_kind IN (2,3);",
                -1, &kinds, nil)
            guard rc == SQLITE_OK, let stmt = kinds else {
                if let kinds { sqlite3_finalize(kinds) }
                return nil
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_bind_int64(stmt, 1, peerId) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let found = sqlite3_column_int(stmt, 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            peerKind = found
        } else if peerKey < 0 {
            peerKind = 1
            peerId = -peerKey
        } else {
            return nil
        }
        var ptr: OpaquePointer?
        let sql = """
        SELECT m.original_observed,
               (SELECT COUNT(*) FROM revisions r
                WHERE r.peer_kind=m.peer_kind AND r.peer_id=m.peer_id
                  AND r.message_id=m.message_id)
        FROM messages m
        WHERE m.peer_kind=? AND m.peer_id=? AND m.message_id=?
        LIMIT 1;
        """
        let rc = sqlite3_prepare_v2(db, sql, -1, &ptr, nil)
        guard rc == SQLITE_OK, let stmt = ptr else {
            if let ptr { sqlite3_finalize(ptr) }
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int(stmt, 1, peerKind) == SQLITE_OK,
              sqlite3_bind_int64(stmt, 2, peerId) == SQLITE_OK,
              sqlite3_bind_int(stmt, 3, messageId) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_int(stmt, 0) == 1 else { return nil }
        let total = sqlite3_column_int(stmt, 1)
        return Entry(count: max(0, total - 1), peerKind: peerKind, peerId: peerId)
    }
}

@_cdecl("goldgram_chat_edit_count_v1")
public func goldgramChatEditCountV1(_ peerKey: Int64, _ messageId: Int32) -> Int32 {
    GoldgramChatEditBadge.entry(peerKey: peerKey, messageId: messageId)?.count ?? -1
}

@_cdecl("goldgram_chat_edit_cache_reset_v1")
public func goldgramChatEditCacheResetV1() {
    GoldgramChatEditBadge.reset()
}

// Only used on a genuine user tap, never during a chat layout pass.
@_cdecl("goldgram_chat_show_revisions_v1")
public func goldgramChatShowRevisionsV1(_ peerKey: Int64, _ messageId: Int32) -> Int32 {
    #if canImport(UIKit)
    guard let account = GoldgramArchiveReader.activeAccountId()?.int64Value,
          account > 0,
          let entry = GoldgramChatEditBadge.entry(peerKey: peerKey, messageId: messageId),
          entry.count > 0 else { return 0 }
    GoldgramHistoryStore.readPhone8RevisionHistory(
        accountId: account, peerKind: entry.peerKind,
        peerId: entry.peerId, messageId: messageId
    ) { versions in
        guard GoldgramArchiveReader.activeAccountId()?.int64Value == account,
              UIApplication.shared.applicationState == .active,
              versions.count > 1 else { return }
        let rows = versions.map { row -> String in
            let index = (row["index"] as? NSNumber)?.intValue ?? 0
            let label = index == 0 ? "Оригинал" : "Изменение \(index)"
            let date = (row["edited"] as? NSNumber).map { stamp in
                DateFormatter.localizedString(
                    from: Date(timeIntervalSince1970: stamp.doubleValue / 1000.0),
                    dateStyle: .short, timeStyle: .medium)
            }
            return label + (date.map { " · " + $0 } ?? "") +
                "\n" + (row["text"] as? String ?? "")
        }
        let controller = UIViewController()
        controller.title = "История редакций"
        controller.view.backgroundColor = .systemBackground
        let textView = UITextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.text = rows.joined(separator: "\n\n────────\n\n")
        textView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor)
        ])
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .pageSheet
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: nil, action: nil)
        controller.navigationItem.rightBarButtonItem?.primaryAction = UIAction(
            title: "Готово") { [weak nav] _ in nav?.dismiss(animated: true) }
        guard let root = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?
                .rootViewController else { return }
        var presenter = root
        while let next = presenter.presentedViewController { presenter = next }
        presenter.present(nav, animated: true)
    }
    return 1
    #else
    return 0
    #endif
}


// #255: same-process C boundary. Native UI has no link dependency on Mx.
// Request lives for this call; callback result lives until callback returns.
// The caller owns a retained opaque completion context; exactly one reply.
@_cdecl("goldgram_unified_search_v1")
public func goldgramUnifiedSearchV1(
    _ raw: UnsafeRawPointer?, _ opaque: UnsafeMutableRawPointer?,
    _ callback: (@convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void)?
) {
    guard let callback else { return }
    func finish(_ answer: NSDictionary) {
        callback(opaque, UnsafeRawPointer(Unmanaged.passUnretained(answer).toOpaque()))
    }
    guard let raw, Thread.isMainThread else {
        finish(["status": "invalid_request", "items": []]); return
    }
    let request = Unmanaged<NSDictionary>.fromOpaque(raw).takeUnretainedValue()
    guard let account = (request["accountId"] as? NSNumber)?.int64Value,
          let needle = request["needle"] as? String,
          let event = (request["event"] as? NSNumber)?.intValue,
          let since = (request["since"] as? NSNumber)?.int64Value,
          let offset = (request["offset"] as? NSNumber)?.intValue else {
        finish(["status": "invalid_request", "items": []]); return
    }
    let sources = request["sources"] as? [[String: Any]]
    if request["sources"] != nil && sources == nil {
        finish(["status": "invalid_request", "items": []]); return
    }
    let authorKind = (request["authorKind"] as? NSNumber).flatMap { Int32(exactly: $0.int64Value) }
    let authorId = (request["authorId"] as? NSNumber)?.int64Value
    if (request["authorKind"] != nil && authorKind == nil) ||
       (request["authorId"] != nil && authorId == nil) {
        finish(["status": "invalid_request", "items": []]); return
    }
    GoldgramArchiveReader.searchLocal(accountId: account, needle: needle, sources: sources,
        event: event, since: since, authorKind: authorKind, authorId: authorId,
        offset: offset, sentDateFilter: true, completion: finish)
}
