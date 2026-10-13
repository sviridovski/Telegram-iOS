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
    private static let currentSchemaVersion: Int32 = 1

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
        if version == 0 {
            do {
                try execute("BEGIN IMMEDIATE;", on: db)
                try execute(schemaV1, on: db)
                try execute("PRAGMA user_version = 1;", on: db)
                try execute("COMMIT;", on: db)
            } catch {
                // Keep the DB recoverable on unexpected schema/setup failures.
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
}
