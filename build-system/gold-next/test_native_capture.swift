import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#endif

// Run the actual production C writer, its asynchronous queue and real SQLite.
@main
struct NativeCaptureFixture {
    static func main() throws {
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
        try send(6, event: 0, text: "Текущая правка", known: true, original: "Поздно доставленный оригинал", baselineOnly: true)
        GoldgramHistoryStore.storageQueue.sync {}
        precondition(row("SELECT original_text,original_observed FROM messages WHERE message_id=6") == ["Поздно доставленный оригинал", "1"])
        precondition(row("SELECT content FROM revisions WHERE message_id=6 ORDER BY version_index DESC LIMIT 1") == ["Текущая правка"])
        precondition(row("SELECT COUNT(*) FROM events WHERE message_id=6") == ["1"], "baseline repair is not another edit")
        // A transient failure keeps a handoff for retry, then can recover.
        precondition(sqlite3_exec(db, "CREATE TRIGGER fixture_fail BEFORE INSERT ON revisions WHEN NEW.message_id=999 BEGIN SELECT RAISE(ABORT, 'fixture'); END;", nil, nil, nil) == SQLITE_OK)
        try send(999, event: 0, text: "Повтор после ошибки", known: true)
        precondition(goldgramFlushCaptureV1() == 0)
        precondition(sqlite3_exec(db, "DROP TRIGGER fixture_fail;", nil, nil, nil) == SQLITE_OK)
        try send(999, event: 0, text: "Повтор после ошибки", known: true)
        precondition(goldgramFlushCaptureV1() == 1)
        precondition(row("SELECT original_text FROM messages WHERE message_id=999") == ["Повтор после ошибки"])
        precondition(row(GoldgramArchiveReader.countsSQL) == ["3", "2"], "production totals SQL")
        GoldgramArchiveReader.updateSelectedAccount(account)
        var totals: NSDictionary?
        GoldgramArchiveReader.query(["accountId": NSNumber(value: account), "category": 3, "mode": "totals"]) { totals = $0 }
        let deadline = Date().addingTimeInterval(10)
        while totals == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(totals?["status"] as? String == "ok", "totals reader status: \(String(describing: totals))")
        precondition((totals?["edited"] as? NSNumber)?.intValue == 3, "count distinct edited messages")
        precondition((totals?["deleted"] as? NSNumber)?.intValue == 2, "exclude empty receipts and ordinary originals")
        print("Goldgram #91: durable original bridge and selected-account archive totals passed against actual Swift writer/reader")
        print("Goldgram #89: production async writer preserves received content/authors on ID-only deletion; observations never become edit events")
    }
}
