import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#endif

// Run the actual production C writer, its asynchronous queue and real SQLite.
@main
struct NativeCaptureFixture {
    static func main() throws {
        // #227: deterministic route choice, shared cursor, one poll at a time.
        precondition(GoldgramLiveRoutePolicy.selectedHost(
            wifi: true, localHost: "192.168.1.102", now: 1_000, localRetryAt: 0)
            == "192.168.1.102")
        precondition(GoldgramLiveRoutePolicy.selectedHost(
            wifi: false, localHost: "192.168.1.102", now: 1_000, localRetryAt: 0)
            == "179.253.88.30")
        precondition(GoldgramLiveRoutePolicy.selectedHost(
            wifi: true, localHost: "192.168.1.102", now: 1_000, localRetryAt: 1_120)
            == "179.253.88.30")
        precondition(GoldgramLiveRoutePolicy.selectedHost(
            wifi: true, localHost: "192.168.1.102", now: 1_120, localRetryAt: 1_120)
            == "192.168.1.102")
        precondition(GoldgramLiveRoutePolicy.localRetrySeconds == 120)
        precondition(GoldgramLiveRoutePolicy.localPinRetrySeconds == 600)
        // #226: the F3 migration keeps the old public relay as fallback;
        // only the explicitly approved public IPs use TLS passthrough 443.
        precondition(GoldgramLiveBridge.supportedHost("192.168.1.102"))
        precondition(GoldgramLiveBridge.supportedHost("194.87.235.144"))
        precondition(GoldgramLiveBridge.supportedHost("179.253.88.30"))
        precondition(!GoldgramLiveBridge.supportedHost("179.253.88.31"))
        precondition(!GoldgramLiveBridge.supportedHost("8.8.8.8"))
        precondition(GoldgramLiveBridge.port(for: "192.168.1.102") == 8873)
        precondition(GoldgramLiveBridge.port(for: "194.87.235.144") == 443)
        precondition(GoldgramLiveBridge.port(for: "179.253.88.30") == 443)
        precondition(GoldgramLiveBridge.catchupDelayMs(host: "179.253.88.30") == 150)
        // #225: HTTP limits must be respected across route/TLS retries.
        precondition(GoldgramLiveRetryPolicy.httpDelay(
            429, retryAfter: "120", failures: 1) == 120)
        precondition(GoldgramLiveRetryPolicy.httpDelay(
            429, retryAfter: "1", failures: 1) == 30)
        precondition(GoldgramLiveRetryPolicy.httpDelay(
            429, retryAfter: nil, failures: 2) == 60)
        precondition(GoldgramLiveRetryPolicy.httpDelay(
            503, retryAfter: nil, failures: 1) == 8)
        precondition(GoldgramLiveRetryPolicy.httpDelay(
            503, retryAfter: "90", failures: 1) == 90)
        precondition(GoldgramLiveRetryPolicy.httpDelay(
            401, retryAfter: nil, failures: 1) == 300)
        precondition(GoldgramLiveRetryPolicy.networkDelay(1) == 3)
        precondition(GoldgramLiveRetryPolicy.networkDelay(10) == 120)
        precondition(GoldgramLiveRetryPolicy.isTLSError(-1200))
        precondition(GoldgramLiveRetryPolicy.isConnectionError(-1005))
        precondition(!GoldgramLiveRetryPolicy.isConnectionError(-1202))
        // #224: LAN catch-up is fast; the public relay retains backoff.
        precondition(GoldgramLiveBridge.catchupDelayMs(host: "192.168.1.102") == 40)
        precondition(GoldgramLiveBridge.catchupDelayMs(host: "10.8.0.1") == 40)
        precondition(GoldgramLiveBridge.catchupDelayMs(host: "194.87.235.144") == 600)
        let account = Int64.random(in: 7_000_000_000_000 ... 8_000_000_000_000)
        let url = try GoldgramHistoryStore.createOrOpen(accountId: account)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: "GoldgramSQLiteCaptureEnabled")
        defaults.set(true, forKey: "GoldgramSQLiteCaptureEnabled")
        defer {
            if let prior { defaults.set(prior, forKey: "GoldgramSQLiteCaptureEnabled") }
            else { defaults.removeObject(forKey: "GoldgramSQLiteCaptureEnabled") }
        }
        func send(_ id: Int, event: Int, text: String, known: Bool = false, retained: Bool = false, sender: Int = 42, before: String? = nil, original: String? = nil, baselineOnly: Bool = false) throws {
            var payload: [String: Any] = ["accountId": account, "peerKind": 2, "peerId": 99, "messageId": id,
                "eventKind": event, "text": text, "originalObserved": known, "retained": retained,
                "senderId": sender, "senderKind": sender == 0 ? -1 : 0, "sentAt": sender == 0 ? 0 : 1000,
                "visibleEdit": true, "changed": true, "editedAt": event == 1 ? 2000 : 0]
            if let before { payload["beforeText"] = before }
            if let original { payload["originalText"] = original }
            payload["baselineOnly"] = baselineOnly
            let data = try JSONSerialization.data(withJSONObject: payload)
            let result = String(data: data, encoding: .utf8)!.withCString { goldgramCaptureEventV1($0) }
            precondition(result == 1)
        }
        try send(1, event: 0, text: "Оригинал", known: true)
        try send(1, event: 0, text: "Оригинал", known: true) // duplicate observation
        try send(2, event: 0, text: "Первое полученное изменение") // no invented original
        try send(3, event: 1, text: "Полученная правка без локальной строки")
        GoldgramHistoryStore.storageQueue.sync {}
        var pointer: OpaquePointer?
        precondition(sqlite3_open(url.path, &pointer) == SQLITE_OK)
        let db = pointer!
        defer { sqlite3_close(db) }
        func row(_ sql: String) -> [String] {
            var stmt: OpaquePointer?
            precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, "fixture query: \(String(cString: sqlite3_errmsg(db)))")
            defer { sqlite3_finalize(stmt) }
            precondition(sqlite3_step(stmt) == SQLITE_ROW)
            return (0 ..< sqlite3_column_count(stmt)).map { index in
                sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? "NULL"
            }
        }
        precondition(row("SELECT COUNT(*) FROM events") == ["1"], "observations aren't edits")
        precondition(row("SELECT COUNT(*) FROM revisions WHERE message_id=1") == ["1"], "no duplicate observed version")
        try send(1, event: 1, text: "Изменение", known: true, before: "Оригинал")
        try send(1, event: 2, text: "[Содержимое не было получено]", sender: 0)
        try send(2, event: 2, text: "[Содержимое не было получено]", sender: 0)
        try send(4, event: 2, text: "[Содержимое не было получено]", sender: 0)
        GoldgramHistoryStore.storageQueue.sync {}
        precondition(row("SELECT original_text,sender_id,sent_at,is_deleted FROM messages WHERE message_id=1") == ["Оригинал","42","1000","1"])
        precondition(row("SELECT content FROM revisions WHERE message_id=1 ORDER BY version_index DESC LIMIT 1") == ["Изменение"], "ID-only deletion must not erase saved text")
        precondition(row("SELECT content FROM revisions WHERE message_id=2 ORDER BY version_index DESC LIMIT 1") == ["Первое полученное изменение"])
        precondition(row("SELECT original_observed,original_text FROM messages WHERE message_id=2") == ["0","NULL"])
        precondition(row("SELECT sender_id,sent_at FROM messages WHERE message_id=4") == ["NULL","NULL"], "receipt doesn't invent an author")
        precondition(row("SELECT COUNT(*) FROM events WHERE event_kind=0") == ["0"])
        precondition(goldgramFlushCaptureV1() == 1)
        let original = goldgramReadOriginalV1(account, 2, 99, 1)!
        defer { free(original) }
        let originalJSON = try JSONSerialization.jsonObject(with: String(cString: original).data(using: .utf8)!) as! [String: String]
        precondition(originalJSON["text"] == "Оригинал", "recover only an actually observed original")
        precondition(goldgramReadOriginalV1(account, 2, 99, 2) == nil, "unknown original must stay unknown")
        precondition(goldgramReadOriginalV1(account, 3, 99, 1) == nil, "peer-kind isolation")
        try send(5, event: 0, text: "Оригинал\0с переносом\nстроки", known: true)
        let escaped = goldgramReadOriginalV1(account, 2, 99, 5)!
        defer { free(escaped) }
        let escapedJSON = try JSONSerialization.jsonObject(with: String(cString: escaped).data(using: .utf8)!) as! [String: String]
        precondition(escapedJSON["text"] == "Оригинал\0с переносом\nстроки", "C bridge preserves embedded NUL and Unicode")
        // Actual edit arrived first; a delayed original must not become latest.
        try send(6, event: 1, text: "Текущая правка")
        try send(6, event: 0, text: "Поздно доставленный оригинал", known: true, original: "Поздно доставленный оригинал", baselineOnly: true)
        GoldgramHistoryStore.storageQueue.sync {}
        precondition(row("SELECT original_text,original_observed FROM messages WHERE message_id=6") == ["Поздно доставленный оригинал", "1"])
        precondition(row("SELECT content FROM revisions WHERE message_id=6 ORDER BY version_index DESC LIMIT 1") == ["Текущая правка"])
        precondition(row("SELECT COUNT(*) FROM events WHERE message_id=6") == ["1"], "baseline repair is not another edit")
        precondition(row("SELECT COUNT(*) FROM revisions WHERE message_id=6") == ["1"], "late original must not append a fake revision")
        // Direct server-new path: baseline-only original is stored even when
        // the Postbox snapshot is never made, with no false edit event.
        try send(7, event: 0, text: "Оригинал из updateNewMessage", known: true,
                 original: "Оригинал из updateNewMessage", baselineOnly: true)
        GoldgramHistoryStore.storageQueue.sync {}
        precondition(row("SELECT original_text, original_observed FROM messages WHERE message_id=7") == ["Оригинал из updateNewMessage", "1"])
        precondition(row("SELECT COUNT(*) FROM revisions WHERE message_id=7") == ["1"])
        precondition(row("SELECT COUNT(*) FROM events WHERE message_id=7") == ["0"])
        // A transient failure keeps a handoff for retry, then can recover.
        precondition(sqlite3_exec(db, "CREATE TRIGGER fixture_fail BEFORE INSERT ON revisions WHEN NEW.message_id=999 BEGIN SELECT RAISE(ABORT, 'fixture'); END;", nil, nil, nil) == SQLITE_OK)
        try send(999, event: 0, text: "Повтор после ошибки", known: true)
        precondition(goldgramFlushCaptureV1() == 0)
        precondition(sqlite3_exec(db, "DROP TRIGGER fixture_fail;", nil, nil, nil) == SQLITE_OK)
        try send(999, event: 0, text: "Повтор после ошибки", known: true)
        precondition(goldgramFlushCaptureV1() == 1)
        precondition(row("SELECT original_text FROM messages WHERE message_id=999") == ["Повтор после ошибки"])
        precondition(row(GoldgramArchiveReader.countsSQL) == ["2", "2"], "journal totals include edits 1 and 6 and deletions 1 and 2")
        GoldgramArchiveReader.updateSelectedAccount(account)
        var totals: NSDictionary?
        GoldgramArchiveReader.query(["accountId": NSNumber(value: account), "category": 3, "mode": "totals"]) { totals = $0 }
        let deadline = Date().addingTimeInterval(10)
        while totals == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(totals?["status"] as? String == "ok", "totals reader status: \(String(describing: totals))")
        precondition((totals?["edited"] as? NSNumber)?.intValue == 2, "edit 3 has no verified original and is hidden from journal totals")
        precondition((totals?["deleted"] as? NSNumber)?.intValue == 2, "exclude empty receipts and ordinary originals")
        // Diagnostic report is limited to local aggregate evidence from
        // the test window; no message content or identity leaves the reader.
        var diagnostic: NSDictionary?
        GoldgramArchiveReader.query(["accountId": NSNumber(value: account), "category": 3,
                                     "mode": "diagnostics", "since": NSNumber(value: 0)]) { diagnostic = $0 }
        let diagDeadline = Date().addingTimeInterval(10)
        while diagnostic == nil && Date() < diagDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(diagnostic?["status"] as? String == "ok")
        precondition((diagnostic?["known"] as? NSNumber)?.intValue == 5, "real original count")
        precondition((diagnostic?["missingEdited"] as? NSNumber)?.intValue == 1, "missing-original edits remain distinct")
        precondition((diagnostic?["edited"] as? NSNumber)?.intValue == 3, "edited diagnostic subset")
        // Simulate a complete original fetched by the notification extension
        // before any edit: bounded handoff has the same writer schema.
        try send(1001, event: 0, text: "Полный оригинал из Postbox уведомления",
                 known: true, original: "Полный оригинал из Postbox уведомления", baselineOnly: true)
        GoldgramHistoryStore.storageQueue.sync {}
        precondition(row("SELECT original_text,original_observed FROM messages WHERE message_id=1001") ==
            ["Полный оригинал из Postbox уведомления", "1"], "extension handoff must persist real original")
        precondition(row("SELECT COUNT(*) FROM events WHERE message_id=1001") == ["0"],
                     "extension original must not create a false edit")
        // #106: getChannelDifference can supply both a genuine new_messages
        // original and its subsequent other_updates edit in the same reply.
        // TelegramCore must enqueue the pre-edit body BEFORE replaying edits.
        // Exercise the real writer/SQLite merge with precisely that ordering.
        try send(1002, event: 0, text: "Исходный комментарий до правки",
                 known: true, original: "Исходный комментарий до правки", baselineOnly: true)
        try send(1002, event: 1, text: "Исправленный комментарий")
        GoldgramHistoryStore.storageQueue.sync {}
        precondition(row("SELECT original_text, original_observed FROM messages WHERE message_id=1002") ==
            ["Исходный комментарий до правки", "1"],
            "catch-up new_messages must preserve a verified pre-edit original")
        precondition(row("SELECT content FROM revisions WHERE message_id=1002 ORDER BY version_index DESC LIMIT 1") ==
            ["Исправленный комментарий"],
            "catch-up edit must remain the latest version")
        precondition(row("SELECT COUNT(*) FROM events WHERE message_id=1002 AND event_kind=1") == ["1"],
            "catch-up edit creates exactly one real edit event")
        try send(1003, event: 1, text: "Редакция, исходный текст не получен")
        GoldgramHistoryStore.storageQueue.sync {}
        precondition(row("SELECT original_text, original_observed FROM messages WHERE message_id=1003") ==
            ["NULL", "0"],
            "an edited-only catch-up must NOT fabricate an original")
        // Hold an actual SQLite write transaction while admission closes. The
        // system expiration path must return before the worker is released.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        GoldgramHistoryStore.enqueueArchiveWork {
            precondition(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
            entered.signal()
            precondition(release.wait(timeout: .now() + 5) == .success)
            precondition(sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK)
        }
        precondition(entered.wait(timeout: .now() + 5) == .success)
        goldgramArchiveAdmissionV1(-1)
        try send(1503, event: 0, text: "До блокировки", known: true)
        release.signal()
        precondition(goldgramFlushCaptureV1() == 0)
        precondition(row("SELECT COUNT(*) FROM messages WHERE message_id=1503") == ["0"])
        let pending = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoldgramPendingOriginals/\(account)_2_99_1503.pending")
        let persisted = try Data(contentsOf: pending)
        goldgramArchiveAdmissionV1(1)
        precondition(goldgramFlushCaptureV1() == 1)
        precondition(row("SELECT original_text FROM messages WHERE message_id=1503") == ["До блокировки"])
        precondition(!FileManager.default.fileExists(atPath: pending.path))
        // Crash between commit and unlink: only the file survives; idempotent
        // replay must preserve the newer revision and acknowledge the spool.
        try send(1503, event: 1, text: "После правки")
        precondition(goldgramFlushCaptureV1() == 1)
        try persisted.write(to: pending, options: .atomic)
        goldgramArchiveAdmissionV1(0)
        goldgramArchiveAdmissionV1(1)
        precondition(goldgramFlushCaptureV1() == 1)
        precondition(row("SELECT COUNT(*) FROM revisions WHERE message_id=1503") == ["2"])
        precondition(row("SELECT content FROM revisions WHERE message_id=1503 ORDER BY version_index DESC LIMIT 1") == ["После правки"])
        precondition(!FileManager.default.fileExists(atPath: pending.path))

        // #203: production writer triggers maintain an exact, materialized
        // projection IN THE SAME SQLite. Neither a second DB nor a JSON cache.
        precondition(row("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='goldgram_ui_fast_rows_v1'") == ["1"],
                     "Fast index migration must finish atomically")
        precondition(row("SELECT edited,deleted FROM goldgram_ui_fast_totals_v1 WHERE id=1") ==
                     row(GoldgramArchiveReader.countsSQL), "fast totals equal legacy full-scan query")
        precondition(row("SELECT COUNT(*) FROM goldgram_ui_fast_rows_v1") ==
                     row("SELECT COUNT(*) FROM messages"), "every baseline has one fast projection")

        // Edit and delete updates must change counters without scanning the
        // complete archive, and restoring visibility must recover the exact
        // previous totals. This is a reversible fixture mutation.
        let beforeHide = row("SELECT edited,deleted FROM goldgram_ui_fast_totals_v1 WHERE id=1")
        precondition(sqlite3_exec(db,
            "UPDATE messages SET original_observed=0 WHERE peer_kind=2 AND peer_id=99 AND message_id=1002;",
            nil, nil, nil) == SQLITE_OK)
        precondition(row("SELECT edited,deleted FROM goldgram_ui_fast_totals_v1 WHERE id=1") ==
                     row(GoldgramArchiveReader.countsSQL), "original revocation updates totals")
        precondition(sqlite3_exec(db,
            "UPDATE messages SET original_observed=1 WHERE peer_kind=2 AND peer_id=99 AND message_id=1002;",
            nil, nil, nil) == SQLITE_OK)
        precondition(row("SELECT edited,deleted FROM goldgram_ui_fast_totals_v1 WHERE id=1") == beforeHide,
                     "restoring a baseline restores totals")

        var folders: NSDictionary?
        GoldgramArchiveReader.query([
            "accountId": NSNumber(value: account), "category": 1,
            "mode": "dialogs", "offset": 0, "limit": 30
        ]) { folders = $0 }
        let foldersDeadline = Date().addingTimeInterval(10)
        while folders == nil && Date() < foldersDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(folders?["status"] as? String == "ok",
                     "fast dialogs SQL must prepare and return without an aggregate scan")
        precondition(!((folders?["items"] as? [[String: Any]]) ?? []).isEmpty,
                     "real edited/deleted group folder visible")

        var combined: NSDictionary?
        GoldgramArchiveReader.query([
            "accountId": NSNumber(value: account), "category": 3,
            "mode": "combined", "offset": 0, "limit": 30,
            "sources": [["peerKind": 2, "peerId": 99]]
        ]) { combined = $0 }
        let combinedDeadline = Date().addingTimeInterval(10)
        while combined == nil && Date() < combinedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(combined?["status"] as? String == "ok",
                     "deleted archive must use materialized predicates")
        let deletedIDs = Set(((combined?["items"] as? [[String: Any]]) ?? [])
            .compactMap { ($0["messageId"] as? NSNumber)?.intValue })
        precondition(deletedIDs == Set([1, 2]),
                     "fast deleted folder excludes hidden receipts and nondeleted edits")

        var editedPage: NSDictionary?
        GoldgramArchiveReader.query([
            "accountId": NSNumber(value: account), "category": 1,
            "mode": "messages", "peerKind": 2, "peerId": 99,
            "offset": 0, "limit": 30
        ]) { editedPage = $0 }
        let editedDeadline = Date().addingTimeInterval(10)
        while editedPage == nil && Date() < editedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(editedPage?["status"] as? String == "ok")
        let editedIDs = Set(((editedPage?["items"] as? [[String: Any]]) ?? [])
            .compactMap { ($0["messageId"] as? NSNumber)?.intValue })
        precondition(editedIDs == Set([6, 1002, 1503]),
                     "fast edit folder must exclude deleted and unverified originals")


        // Bridge regression: an unknown PeerChannel MUST NOT block the entire
        // Live cursor or be silently lost. It is durable in this account's
        // SQLite and replays only after native dialog classification is unique.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let first = formatter.string(from: Date().addingTimeInterval(-180))
        let editedAt = formatter.string(from: Date().addingTimeInterval(-100))
        let observed = formatter.string(from: Date().addingTimeInterval(-90))
        let unknownEdit: [String: Any] = [
            "record_kind": "edit", "source": "iphone8_telethon",
            "account_id": String(account), "peer_kind": "PeerChannel",
            "chat_id": "-100770077", "message_id": "2001",
            "edit_event_id": "edit:2001", "first_seen_at": first,
            "original_text": "Unmodified pre-edit text",
            "latest_text": "Modified channel text", "sender_id": "424242",
            "server_edit_at": editedAt, "event_observed_at": observed
        ]
        let unknownDelete: [String: Any] = [
            "record_kind": "delete", "source": "iphone8_telethon",
            "account_id": String(account), "peer_kind": "PeerChannel",
            "chat_id": "-100770077", "message_id": "2002",
            "edit_event_id": "delete:2002", "first_seen_at": first,
            "original_text": "Unmodified deleted text", "sender_id": "434343",
            "event_observed_at": observed
        ]
        func bridgeResult(_ records: [[String: Any]]) throws -> [String: Int] {
            let data = try JSONSerialization.data(withJSONObject: [
                "format": "goldgram_bridge_v2", "records": records
            ])
            var reply: [String: Int]?
            GoldgramHistoryStore.importPhone8Bundle(data, accountId: account) { reply = $0 }
            let until = Date().addingTimeInterval(10)
            while reply == nil && Date() < until {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(reply != nil, "bridge import completion timed out")
            return reply!
        }
        func replayResult() -> [String: Int] {
            var reply: [String: Int]?
            GoldgramHistoryStore.replayPhone8Unknown(accountId: account) { reply = $0 }
            let until = Date().addingTimeInterval(10)
            while reply == nil && Date() < until {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(reply != nil, "pending replay completion timed out")
            return reply!
        }
        let deferred = try bridgeResult([unknownEdit, unknownDelete])
        precondition(deferred["deferredChannels"] == 2 && deferred["unknownChannels", default: 0] == 0,
                     "unknown PeerChannel packets must be durably queued, not reject Live cursor")
        precondition(row("SELECT COUNT(*) FROM bridge_unknown_channels_v1") == ["2"],
                     "unresolved bridge events remain in same archive SQLite")
        precondition(row("SELECT COUNT(*) FROM messages WHERE peer_id=770077") == ["0"],
                     "do not guess channel or supergroup while mapping unknown")
        let repeated = try bridgeResult([unknownEdit, unknownDelete])
        precondition(repeated["duplicates"] == 2, "replay of unresolved batch is idempotent")
        precondition(row("SELECT COUNT(*) FROM bridge_unknown_channels_v1") == ["2"])
        precondition(replayResult().isEmpty, "unknown peer kinds must remain safely held")

        precondition(sqlite3_exec(db,
            "INSERT INTO dialogs(peer_kind,peer_id) VALUES(2,770077);",
            nil, nil, nil) == SQLITE_OK)
        let recovered = replayResult()
        precondition(recovered["edits"] == 1 && recovered["deletions"] == 1 &&
                     recovered["imported"] == 1, "known dialog replays edit and deletion")
        precondition(row("SELECT COUNT(*) FROM bridge_unknown_channels_v1") == ["0"],
                     "successful merge must clear pending in same transaction")
        precondition(row("SELECT original_text, original_observed FROM messages WHERE peer_kind=2 AND peer_id=770077 AND message_id=2001") ==
                     ["Unmodified pre-edit text","1"], "real original survives deferred replay")
        precondition(row("SELECT is_deleted FROM messages WHERE peer_kind=2 AND peer_id=770077 AND message_id=2002") == ["1"])
        precondition(row("SELECT COUNT(*) FROM events WHERE peer_kind=2 AND peer_id=770077") == ["2"])
        precondition(row("SELECT sender_id,sender_kind,sent_at FROM messages WHERE peer_kind=2 AND peer_id=770077 AND message_id=2001") ==
                     ["424242","0","NULL"], "Bridge sender ID must not fabricate a send timestamp")
        precondition(row("SELECT sender_id,sender_kind,sent_at FROM messages WHERE peer_kind=2 AND peer_id=770077 AND message_id=2002") ==
                     ["434343","0","NULL"], "deletion must retain independently observed author only")
        // A retransmitted event with contradictory sender metadata must not
        // overwrite a sender from a previous committed import.
        var changedSender = unknownEdit
        changedSender["sender_id"] = "999999"
        // #214: metadata may arrive after an earlier Live receipt. Only
        // verified server send date and actual reply IDs can fill NULL fields.
        let serverSentAt = formatter.string(from: Date().addingTimeInterval(-900))
        let expectedSentMs = Int64(formatter.date(from: serverSentAt)!.timeIntervalSince1970 * 1000)
        changedSender["telegram_sent_at"] = serverSentAt
        changedSender["reply_to_message_id"] = "1999"
        changedSender["topic_top_message_id"] = "1900"
        let senderDuplicate = try bridgeResult([changedSender])
        precondition(senderDuplicate["duplicates"] == 1)
        precondition(row("SELECT sender_id FROM messages WHERE peer_kind=2 AND peer_id=770077 AND message_id=2001") == ["424242"])
        let expectedMetadata = [String(expectedSentMs), "1999", "1900"]
        let metadataSQL = "SELECT sent_at,reply_to_message_id,thread_id FROM messages WHERE peer_kind=2 AND peer_id=770077 AND message_id=2001"
        precondition(row(metadataSQL) == expectedMetadata,
                     "duplicate Live receipt enriches missing server date and reply metadata")
        var competingMetadata = changedSender
        competingMetadata["telegram_sent_at"] = formatter.string(from: Date().addingTimeInterval(-800))
        competingMetadata["reply_to_message_id"] = "1998"
        competingMetadata["topic_top_message_id"] = "1800"
        let repeatedMetadata = try bridgeResult([competingMetadata])
        precondition(repeatedMetadata["duplicates"] == 1)
        precondition(row(metadataSQL) == expectedMetadata,
                     "retransmission cannot overwrite first trusted metadata")
        var invalidMetadata = unknownDelete
        invalidMetadata["telegram_sent_at"] = "not-a-server-date"
        invalidMetadata["reply_to_message_id"] = "-3"
        invalidMetadata["topic_top_message_id"] = "0"
        let invalidMetadataResult = try bridgeResult([invalidMetadata])
        precondition(invalidMetadataResult["duplicates"] == 1)
        precondition(row("SELECT sent_at,reply_to_message_id,thread_id FROM messages WHERE peer_kind=2 AND peer_id=770077 AND message_id=2002") == ["NULL","NULL","NULL"],
                     "invalid bridge metadata must not replace unknown values")
        precondition(replayResult().isEmpty, "idempotent after successful replay")

        // #218: native Swiftgram observes the FINAL edit before the Bridge
        // delivers the intermediate edit, then replays a #217 pending receipt.
        try send(3018, event: 0, text: "1", known: true)
        let nativeFinal = Date().addingTimeInterval(-35)
        // Exercise the same production native capture entrypoint as the
        // preceding tests instead of calling fileprivate archiveEdit.
        try send(3018, event: 1, text: "123", known: true, before: "1")
        GoldgramHistoryStore.storageQueue.sync {}
        let oldEdit: [String: Any] = [
            "record_kind": "edit", "source": "iphone8_telethon",
            "account_id": String(account), "peer_kind": "PeerChannel",
            "chat_id": "-10099", "message_id": "3018",
            "edit_event_id": "edit:3018",
            "first_seen_at": formatter.string(from: Date().addingTimeInterval(-120)),
            "original_text": "1", "latest_text": "12",
            "server_edit_at": formatter.string(from: Date().addingTimeInterval(-70)),
            "event_observed_at": formatter.string(from: Date().addingTimeInterval(-65))
        ]
        // Make the native timestamp temporarily unknowable to exercise
        // the exact pending receipt path from the installed #217.
        precondition(sqlite3_exec(db,
            "UPDATE revisions SET server_edit_at=NULL WHERE peer_kind=2 AND peer_id=99 AND message_id=3018 AND version_index=1;",
            nil, nil, nil) == SQLITE_OK)
        let initiallyPending = try bridgeResult([oldEdit])
        precondition(initiallyPending["pending"] == 1,
                     "unknown native timing must keep an older edit pending")
        precondition(row("SELECT COUNT(*) FROM revisions WHERE message_id=3018") == ["2"])
        let resetSQL = "UPDATE revisions SET server_edit_at=\(Int64(nativeFinal.timeIntervalSince1970 * 1000)) WHERE peer_kind=2 AND peer_id=99 AND message_id=3018 AND version_index=1;"
        precondition(sqlite3_exec(db, resetSQL, nil, nil, nil) == SQLITE_OK)
        let repaired = replayResult()
        precondition(repaired["edits"] == 1,
                     "replay must restore a held earlier Bridge edit without cursor reset")
        precondition(row("SELECT group_concat(content, '>') FROM (SELECT content FROM revisions WHERE message_id=3018 ORDER BY version_index)") == ["1>12>123"],
                     "Bridge backfills the historical revision before native latest")
        precondition(row("SELECT COUNT(*) FROM bridge_merge_receipts_v2 WHERE status='pending' AND event_key LIKE 'iphone8.merge.v2.%'") == ["0"],
                     "recovered edit receipt becomes applied")
        let replayedDuplicate = try bridgeResult([oldEdit])
        precondition(replayedDuplicate["duplicates"] == 1,
                     "repeated import of an earlier edit must not duplicate it")
        precondition(row("SELECT COUNT(*) FROM revisions WHERE message_id=3018") == ["3"])
        var versionResults: [[String: Any]]?
        GoldgramHistoryStore.readPhone8RevisionHistory(
            accountId: account, peerKind: 2, peerId: 99, messageId: 3018
        ) { versionResults = $0 }
        let versionsDeadline = Date().addingTimeInterval(10)
        while versionResults == nil && Date() < versionsDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(versionResults?.compactMap { $0["text"] as? String } ==
                     ["1", "12", "123"], "history viewer exposes every restored revision")
        // #221: the regular chat's pencil must show the same two edits as
        // the persisted Goldgram SQLite, even if the MX tracker saw only one.
        // The badge getter is cached and MUST NOT do SQLite I/O on layout.
        let channelPeerKey = -(Int64(1_000_000_000_000) + 99)
        let badgeDeadline = Date().addingTimeInterval(10)
        var badgeEdits = goldgramChatEditCountV1(channelPeerKey, 3018)
        while badgeEdits == -1 && Date() < badgeDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            badgeEdits = goldgramChatEditCountV1(channelPeerKey, 3018)
        }
        precondition(badgeEdits == 2, "chat badge must show two verified edits")
        precondition(goldgramChatEditCountV1(channelPeerKey, 3018) == 2,
                     "cached chat count is stable on layout")
        precondition(goldgramChatEditCountV1(channelPeerKey - 1, 3018) == -1,
                     "same message id in a different peer cannot inherit history")
        // #223: the actual chat inline-reader must return all intermediate edits
        // from the same verified SQLite, not just the native session's last edit.
        let inlinePointer = goldgramVerifiedInlineHistoryV1(account, 2, 99, 3018)
        precondition(inlinePointer != nil, "confirmed inline history is readable")
        let inlineJSON = String(cString: inlinePointer!)
        free(inlinePointer)
        let inline = try JSONSerialization.jsonObject(with: Data(inlineJSON.utf8))
            as! [String: Any]
        precondition(inline["baseline"] as? String == "1")
        precondition(inline["revisions"] as? [String] == ["12", "123"],
                     "chat displays both edits in chronological order")
        precondition(goldgramVerifiedInlineHistoryV1(account, 2, 98, 3018) == nil,
                     "identical message ID in another dialog must not leak")
        precondition(goldgramVerifiedInlineHistoryV1(account, 3, 99, 3018) == nil,
                     "different peer classification must not inherit history")
        precondition(goldgramVerifiedInlineHistoryV1(account, 2, 99, 2) == nil,
                     "never label an unverified first-seen edit as original")
        precondition(replayResult().isEmpty, "restored receipt is idempotent")

        // #231: capture the message-scoped notification emitted after COMMIT.
        var deliveredScopes: [[String: Int64]] = []
        let scopeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("GoldgramArchiveChanged"),
            object: nil, queue: nil) { note in
            guard (note.object as? NSNumber)?.int64Value == account,
                  let scopes = note.userInfo?["inlineScopes"] as? [[String: Int64]]
                  else { return }
            deliveredScopes.append(contentsOf: scopes)
        }
        defer { NotificationCenter.default.removeObserver(scopeObserver) }

        // #229: an authentic Raw-new original arrives after the first edit,
        // although Telegram's Message.date correctly predates both edits.
        let lateSent = formatter.string(from: Date().addingTimeInterval(-120))
        let lateEditAt = formatter.string(from: Date().addingTimeInterval(-70))
        let lateFirstSeen = formatter.string(from: Date().addingTimeInterval(-53))
        let lateSecondAt = formatter.string(from: Date().addingTimeInterval(-25))
        let lateObserved = formatter.string(from: Date().addingTimeInterval(-10))
        var lateEdit: [String: Any] = [
            "record_kind": "edit", "source": "iphone8_telethon",
            "account_id": String(account), "peer_kind": "PeerChannel",
            "chat_id": "-10099", "message_id": "3329",
            "edit_event_id": "edit:3329",
            "first_seen_at": lateFirstSeen,
            "original_text": "Verified original", "latest_text": "Edit one",
            "server_edit_at": lateEditAt, "event_observed_at": lateObserved,
            "telegram_sent_at": lateSent
        ]
        let heldFirst = try bridgeResult([lateEdit])
        precondition(heldFirst["chronologyPending"] == 1)
        precondition(row("SELECT COUNT(*) FROM bridge_chronology_holds_v1 WHERE message_id=3329") == ["1"])
        var secondEdit = lateEdit
        secondEdit["edit_event_id"] = "edit:3330"
        secondEdit["latest_text"] = "Edit two"
        secondEdit["server_edit_at"] = lateSecondAt
        let heldSecond = try bridgeResult([secondEdit])
        precondition(heldSecond["pending"] == 1)
        // Neither metadata alone, nor an arbitrary snapshot, can unlock it.
        lateEdit["original_evidence_source"] = "group_history_snapshot"
        lateEdit["original_evidence_kind"] = "new_unedited"
        _ = try bridgeResult([lateEdit])
        precondition(row("SELECT COUNT(*) FROM bridge_chronology_holds_v1 WHERE message_id=3329") == ["1"])
        lateEdit["original_evidence_source"] = "raw_update_new_message"
        lateEdit["telegram_sent_at"] = lateSecondAt
        _ = try bridgeResult([lateEdit])
        precondition(row("SELECT COUNT(*) FROM bridge_chronology_holds_v1 WHERE message_id=3329") == ["1"])
        // V216 proof replay has the same edit ID but authenticated evidence.
        lateEdit["telegram_sent_at"] = lateSent
        let restored = try bridgeResult([lateEdit])
        precondition(restored["imported"] == 1 && restored["edits"] == 1,
                     "genuine late original unlocks first edit")
        precondition(row("SELECT COUNT(*) FROM bridge_chronology_holds_v1 WHERE message_id=3329") == ["0"])
        precondition(replayResult()["edits"] == 1,
                     "second edit backfills without resetting existing cursors")
        precondition(row("SELECT group_concat(content,'>') FROM (SELECT content FROM revisions WHERE message_id=3329 ORDER BY version_index)") ==
                     ["Verified original>Edit one>Edit two"], "all edits survive in order")
        let finalDuplicate = try bridgeResult([lateEdit])
        precondition(finalDuplicate["duplicates"] == 1)
        precondition(row("SELECT COUNT(*) FROM revisions WHERE message_id=3329") == ["3"])
        // #232: proof of a duplicate must retrigger display reconciliation,
        // and an idle Live poll must find old confirmed history locally.
        let scopeCountBeforeDuplicate = deliveredScopes.filter {
            $0["messageId"] == 3329
        }.count
        let redelivered = try bridgeResult([lateEdit])
        precondition(redelivered["duplicates"] == 1,
                     "repeat delivery must remain idempotent")
        precondition(deliveredScopes.filter { $0["messageId"] == 3329 }.count >
                     scopeCountBeforeDuplicate,
                     "committed receipt must re-notify Postbox after duplicate delivery")
        let beforeSweep = deliveredScopes.filter { $0["messageId"] == 3329 }.count
        GoldgramHistoryStore.notifyPreviouslyImportedInline(accountId: account)
        let sweepDeadline = Date().addingTimeInterval(10)
        while deliveredScopes.filter({ $0["messageId"] == 3329 }).count <= beforeSweep &&
                Date() < sweepDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(deliveredScopes.filter { $0["messageId"] == 3329 }.count > beforeSweep,
                     "idle local backfill includes previously imported confirmed history")
        precondition(row("SELECT COUNT(*) FROM revisions WHERE message_id=3329") == ["3"],
                     "local backfill must not insert duplicate revisions")
        precondition(deliveredScopes.contains(where: {
            $0["peerKind"] == 2 && $0["peerId"] == 99 && $0["messageId"] == 3329
        }), "scoped Postbox update must follow the archive COMMIT")
        precondition(!deliveredScopes.contains(where: { $0["messageId"] == 9999 }),
                     "only committed message IDs may be notified")
        print("Goldgram #229: verified late original and idempotent replay OK")
        print("Goldgram #231: post-COMMIT scoped reconciliation signal OK")

        // #233: category-specific journal clearing preserves the other
        // category and the baseline, even for an edited+deleted message.
        // #235: production schema and triggers, 2700 messages, each with an
        // edit, and every other message also deleted. Compare exact projected
        // counts after each bulk operation and verify normal triggers survive.
        GoldgramHistoryStore.storageQueue.sync {}
        let massSQL = """
        BEGIN IMMEDIATE;
        INSERT OR IGNORE INTO dialogs(peer_kind,peer_id) VALUES(2,235);
        WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<2700)
        INSERT INTO messages(peer_kind,peer_id,message_id,original_text,original_observed,first_seen_at,last_seen_at,is_deleted)
        SELECT 2,235,n,'base',1,1000,2000,n%2 FROM seq;
        INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,content,observed_at)
        SELECT 2,235,message_id,0,'base',1000 FROM messages WHERE peer_kind=2 AND peer_id=235;
        INSERT INTO revisions(peer_kind,peer_id,message_id,version_index,content,observed_at)
        SELECT 2,235,message_id,1,'edited',2000 FROM messages WHERE peer_kind=2 AND peer_id=235;
        INSERT INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at)
        SELECT 2,235,message_id,1,'goldgram_iphone8_bridge_v1','mass-edit-'||message_id,2000
        FROM messages WHERE peer_kind=2 AND peer_id=235;
        INSERT INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at)
        SELECT 2,235,message_id,2,'goldgram_iphone8_bridge_v1','mass-delete-'||message_id,3000
        FROM messages WHERE peer_kind=2 AND peer_id=235 AND is_deleted=1;
        COMMIT;
        """
        precondition(sqlite3_exec(db, massSQL, nil, nil, nil) == SQLITE_OK,
                     "mass journal fixture must seed production tables")
        precondition(row("SELECT COUNT(*) FROM goldgram_ui_fast_rows_v1 WHERE peer_id=235 AND edited=1") == ["2700"])
        precondition(row("SELECT COUNT(*) FROM goldgram_ui_fast_rows_v1 WHERE peer_id=235 AND deleted=1") == ["1350"])
        let triggerCountBefore = row("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'goldgram_ui_fast_source_%'")
        let deleteCountBefore = row("SELECT COUNT(*) FROM events WHERE event_kind=2")
        precondition(Int(deleteCountBefore[0]) ?? 0 > 0)
        precondition(Int(row("SELECT COUNT(*) FROM events WHERE event_kind=1")[0]) ?? 0 > 0)
        let originalBefore = row("SELECT original_text FROM messages WHERE message_id=1")
        func clearCategory(_ kind: Int) -> [String: Any] {
            var answer: NSDictionary?
            GoldgramArchiveReader.clearJournal(
                forAccount: NSNumber(value: account), category: kind) { result in
                    answer = result
            }
            let deadline = Date().addingTimeInterval(10)
            while answer == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(answer != nil, "journal clear completion timed out")
            return answer as? [String: Any] ?? [:]
        }
        let editClearStarted = ProcessInfo.processInfo.systemUptime
        precondition(clearCategory(1)["status"] as? String == "ok")
        print("Goldgram #235: mass edit clear seconds", ProcessInfo.processInfo.systemUptime - editClearStarted)
        precondition(row("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'goldgram_ui_fast_source_%'") == triggerCountBefore)
        precondition(row("SELECT COUNT(*) FROM goldgram_ui_fast_rows_v1 WHERE peer_id=235 AND deleted=1") == ["1350"])
        precondition(row("SELECT COUNT(*) FROM events WHERE event_kind=1") == ["0"])
        precondition(row("SELECT COUNT(*) FROM revisions WHERE version_index>0") == ["0"])
        precondition(row("SELECT COUNT(*) FROM events WHERE event_kind=2") == deleteCountBefore,
                     "clearing edits must retain deleted-message evidence")
        precondition(row("SELECT original_text FROM messages WHERE message_id=1") == originalBefore,
                     "clearing edits must retain original baseline")
        // Configure independent retention periods. The default is disabled;
        // setting one never silently changes the other.
        GoldgramArchiveReader.setJournalRetention(
            forAccount: NSNumber(value: account), category: 1, hours: 12)
        GoldgramArchiveReader.setJournalRetention(
            forAccount: NSNumber(value: account), category: 3, hours: 168)
        precondition(GoldgramArchiveReader.journalRetention(
            forAccount: NSNumber(value: account), category: 1) == 12)
        precondition(GoldgramArchiveReader.journalRetention(
            forAccount: NSNumber(value: account), category: 3) == 168)
        let deleteClearStarted = ProcessInfo.processInfo.systemUptime
        precondition(clearCategory(3)["status"] as? String == "ok")
        print("Goldgram #235: mass deletion clear seconds", ProcessInfo.processInfo.systemUptime - deleteClearStarted)
        precondition(row("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'goldgram_ui_fast_source_%'") == triggerCountBefore)
        // New writes after the purge must still update the restored projection.
        let afterClearSQL = "INSERT INTO events(peer_kind,peer_id,message_id,event_kind,source,event_key,observed_at) VALUES(2,235,1,1,'goldgram_iphone8_bridge_v1','after-purge',4000);"
        precondition(sqlite3_exec(db, afterClearSQL, nil, nil, nil) == SQLITE_OK)
        precondition(row("SELECT edited FROM goldgram_ui_fast_rows_v1 WHERE peer_id=235 AND message_id=1") == ["1"])
        precondition(sqlite3_exec(db, "DELETE FROM events WHERE event_key='after-purge';", nil, nil, nil) == SQLITE_OK)
        precondition(row("SELECT edited FROM goldgram_ui_fast_rows_v1 WHERE peer_id=235 AND message_id=1") == ["0"])
        precondition(row("SELECT COUNT(*) FROM events WHERE event_kind=2") == ["0"])
        precondition(row("SELECT COUNT(*) FROM messages WHERE is_deleted=1") == ["0"])
        precondition(row("SELECT original_text FROM messages WHERE message_id=1") == originalBefore)
        precondition(row("SELECT edited,deleted FROM goldgram_ui_fast_totals_v1 WHERE id=1") == ["0","0"],
                     "fast archive counters must reflect both category clears")
        GoldgramArchiveReader.setJournalRetention(
            forAccount: NSNumber(value: account), category: 1, hours: 0)
        GoldgramArchiveReader.setJournalRetention(
            forAccount: NSNumber(value: account), category: 3, hours: 0)
        print("Goldgram #233: separate journal clear/retention and preserved baseline OK")

        // Simulate the existing account-clear cascade on the same SQLite.
        precondition(sqlite3_exec(db, "PRAGMA foreign_keys=ON; DELETE FROM dialogs;",
                                  nil, nil, nil) == SQLITE_OK)
        precondition(row("SELECT COUNT(*) FROM goldgram_ui_fast_rows_v1") == ["0"],
                     "clear must cascade fast-row cleanup")
        precondition(row("SELECT edited,deleted FROM goldgram_ui_fast_totals_v1 WHERE id=1") == ["0","0"],
                     "clear must zero fast counters")
        print("Goldgram #203: transactional fast listing/totals, idempotence and clear OK")

        print("Goldgram #106: ordered difference original/edit writer regression passes")
        print("Goldgram #91: durable original bridge and selected-account archive totals passed against actual Swift writer/reader")
        print("Goldgram #89: production async writer preserves received content/authors on ID-only deletion; observations never become edit events")
    }
}
