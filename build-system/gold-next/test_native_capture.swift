import Foundation
import SQLite3

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
        func send(_ id: Int, event: Int, text: String, known: Bool = false, retained: Bool = false, sender: Int = 42, before: String? = nil) throws {
            var payload: [String: Any] = ["accountId": account, "peerKind": 2, "peerId": 99, "messageId": id,
                "eventKind": event, "text": text, "originalObserved": known, "retained": retained,
                "senderId": sender, "senderKind": sender == 0 ? -1 : 0, "sentAt": sender == 0 ? 0 : 1000,
                "visibleEdit": true, "changed": true, "editedAt": event == 1 ? 2000 : 0]
            if let before { payload["beforeText"] = before }
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
            precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
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
        print("Goldgram #89: production async writer preserves received content/authors on ID-only deletion; observations never become edit events")
    }
}
