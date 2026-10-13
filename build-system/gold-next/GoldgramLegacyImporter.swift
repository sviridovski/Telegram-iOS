// Goldgram #65 — opt-in, provenance-gated Mx history migration.
// NEVER run at app launch. Legacy Mx defaults contain no Telegram account ID.
// A future host integration must validate historical account ownership first.
import Foundation
import SQLite3

enum GoldgramLegacyImporter {
    enum MigrationError: Error {
        case unverifiedAccount
        case database(Int32)
    }

    struct Report {
        let examinedMessages: Int
        let examinedVersions: Int
        let ambiguousMessages: Int
        let stagedDeletions: Int
    }

    // validatedLegacyOwner must identify the authenticated account proven to
    // own ALL of the old shared MX data, not just the currently selected one.
    // channelKinds maps packed negative MX peer IDs to 2=supergroup, 3=channel.
    // Unknown channel peer kinds are intentionally skipped.
    static func migrate(
        accountId: Int64,
        validatedLegacyOwner: Int64?,
        channelKinds: [Int64: Int32],
        completion: @escaping (Result<Report, Error>) -> Void
    ) {
        GoldgramHistoryStore.storageQueue.async {
            let outcome: Result<Report, Error>
            do {
                guard accountId > 0, validatedLegacyOwner == accountId else {
                    throw MigrationError.unverifiedAccount
                }
                let url = try GoldgramHistoryStore.createOrOpen(accountId: accountId)
                outcome = .success(try importLegacy(into: url, channelKinds: channelKinds))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private enum Value {
        case int(Int64)
        case string(String)
    }

    private struct Address {
        let kind: Int64
        let peer: Int64
        let message: Int64
    }

    private static func parseAddress(
        _ key: String, kinds: [Int64: Int32]
    ) -> Address? {
        let parts = key.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let packed = Int64(parts[0]), packed != 0,
              let id = Int32(parts[1]), id > 0 else { return nil }
        if packed > 0 {
            return Address(kind: 0, peer: packed, message: Int64(id))
        }
        if packed > -1_000_000_000_000 {
            return Address(kind: 1, peer: -packed, message: Int64(id))
        }
        guard packed != Int64.min,
              let kind = kinds[packed], kind == 2 || kind == 3 else { return nil }
        let rawPeer = -packed - 1_000_000_000_000
        guard rawPeer > 0 else { return nil }
        return Address(kind: Int64(kind), peer: rawPeer, message: Int64(id))
    }

    private static func run(
        _ sql: String, db: OpaquePointer, values: [Value] = []
    ) throws {
        var stmt: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepared == SQLITE_OK, let statement = stmt else {
            if let stmt = stmt { sqlite3_finalize(stmt) }
            throw MigrationError.database(prepared)
        }
        defer { sqlite3_finalize(statement) }
        // SQLite destructor -1 means copy text before Swift releases its buffer.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, item) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch item {
            case let .int(value):
                status = sqlite3_bind_int64(statement, index, value)
            case let .string(value):
                status = value.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, transient)
                }
            }
            guard status == SQLITE_OK else {
                throw MigrationError.database(status)
            }
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw MigrationError.database(result)
        }
    }

    private static func importLegacy(
        into url: URL, channelKinds: [Int64: Int32]
    ) throws -> Report {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(
            url.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard opened == SQLITE_OK, let db = handle else {
            if let handle = handle { sqlite3_close(handle) }
            throw MigrationError.database(opened)
        }
        defer { sqlite3_close(db) }
        try run("PRAGMA foreign_keys = ON;", db: db)

        let defaults = UserDefaults.standard
        let modern = defaults.dictionary(forKey: "MxEditHistoryByPeer") as? [String: [String]]
        let old = defaults.dictionary(forKey: "MxEditHistory") as? [String: [String]]
        let oldPeers = defaults.dictionary(forKey: "MxEditHistoryPeers") as? [String: NSNumber]
        let deleted = defaults.dictionary(forKey: "MxDeletedMsgIds")
        var versionsByKey = [String: [String]]()
        if let modern = modern, !modern.isEmpty {
            versionsByKey = modern
        } else if let old = old {
            for (id, versions) in old {
                if let peer = oldPeers?[id]?.int64Value {
                    versionsByKey["\(peer):\(id)"] = versions
                }
            }
        }

        let observedAt = Int64(Date().timeIntervalSince1970 * 1000)
        var messages = 0
        var versions = 0
        var ambiguous = 0
        var deletions = 0

        try run("BEGIN IMMEDIATE;", db: db)
        do {
            for (key, history) in versionsByKey {
                guard let first = history.first, !first.isEmpty else { continue }
                guard let address = parseAddress(key, kinds: channelKinds) else {
                    ambiguous += 1
                    continue
                }
                let peer: [Value] = [.int(address.kind), .int(address.peer)]
                try run(
                    "INSERT OR IGNORE INTO dialogs (peer_kind, peer_id) VALUES (?, ?);",
                    db: db, values: peer
                )
                // Legacy snapshots have no trustworthy server timestamps.
                // original_observed stays 0: first observed != proven original.
                try run(
                    "INSERT OR IGNORE INTO messages (peer_kind, peer_id, message_id, original_text, original_observed, first_seen_at, last_seen_at) VALUES (?, ?, ?, ?, 0, ?, ?);",
                    db: db,
                    values: peer + [
                        .int(address.message), .string(first),
                        .int(observedAt), .int(observedAt)
                    ]
                )
                messages += 1
                for (i, body) in history.enumerated() where !body.isEmpty {
                    try run(
                        "INSERT OR IGNORE INTO revisions (peer_kind, peer_id, message_id, version_index, content, observed_at) VALUES (?, ?, ?, ?, ?, ?);",
                        db: db,
                        values: peer + [
                            .int(address.message), .int(Int64(i)),
                            .string(body), .int(observedAt)
                        ]
                    )
                    versions += 1
                    if i > 0 {
                        let eventKey = "legacy-edit-\(address.kind)-\(address.peer)-\(address.message)-\(i)"
                        try run(
                            "INSERT OR IGNORE INTO events (peer_kind, peer_id, message_id, event_kind, source, event_key, observed_at) VALUES (?, ?, ?, 1, 'legacy_mx', ?, ?);",
                            db: db,
                            values: peer + [
                                .int(address.message), .string(eventKey),
                                .int(observedAt)
                            ]
                        )
                    }
                }
            }

            // Legacy deletions may have only an account-wide sequence (scope 0).
            // Do not mark a random personal chat message as deleted.
            if let deleted = deleted {
                for (key, raw) in deleted {
                    guard let id = Int32(key), id > 0 else { continue }
                    let scopes: [NSNumber]
                    if let all = raw as? [NSNumber] {
                        scopes = all
                    } else if let one = raw as? NSNumber {
                        scopes = [one]
                    } else {
                        continue
                    }
                    for scope in Set(scopes.map { $0.int64Value }) {
                        try run(
                            "INSERT OR IGNORE INTO unresolved_deletions (update_key, message_id, observed_at) VALUES (?, ?, ?);",
                            db: db,
                            values: [
                                .string("legacy-mx-scope-\(scope)"),
                                .int(Int64(id)), .int(observedAt)
                            ]
                        )
                        deletions += 1
                    }
                }
            }
            try run("COMMIT;", db: db)
        } catch {
            try? run("ROLLBACK;", db: db)
            throw error
        }

        // Old NSUserDefaults data stays fully intact after every import.
        // All INSERT OR IGNORE keys make explicit retries idempotent.
        return Report(
            examinedMessages: messages,
            examinedVersions: versions,
            ambiguousMessages: ambiguous,
            stagedDeletions: deletions
        )
    }
}
