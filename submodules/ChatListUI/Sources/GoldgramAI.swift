import Foundation
import CoreFoundation
import UIKit
import Security
import UniformTypeIdentifiers

// #268: a built-in native AI command. Imported JavaScript receives no network,
// credentials, chat objects or send capability. User approves each request.
public struct GoldgramAIDraft: Equatable {
    public let identity: String
    public let text: String
    public let writable: Bool
    public init(identity: String, text: String, writable: Bool = true) { self.identity = identity; self.text = text; self.writable = writable }
}

// #272: provider endpoint policy and sanitized model catalog; no credentials in JS.
enum GoldgramNetworkPolicy {
    enum Route: Equatable { case models, completion, balance }
    static func route(url: String?, method: String?, hasBody: Bool, allowBalance: Bool = false) -> Route? {
        switch (url, method) {
        case ("https://api.deepseek.com/models", "GET"): return hasBody ? nil : .models
        case ("https://api.deepseek.com/user/balance", "GET"): return !hasBody && allowBalance ? .balance : nil
        case ("https://api.deepseek.com/chat/completions", "POST"): return hasBody ? .completion : nil
        default: return nil
        }
    }
    static func modelID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 100 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 || $0 == 58 }
    }
    static func catalog(_ data: Data) -> [[String: Any]]? {
        guard data.count <= 128 * 1024, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["object"] as? String == "list", let rows = root["data"] as? [[String: Any]], rows.count <= 256 else { return nil }
        var seen = Set<String>()
        var result: [[String: Any]] = []
        for row in rows {
            guard let id = row["id"] as? String, modelID(id), row["object"] as? String == "model", seen.insert(id).inserted else { continue }
            var model: [String: Any] = ["id": id, "object": "model", "owned_by": "deepseek"]
            if let name = row["name"] as? String, !name.isEmpty { model["name"] = String(name.prefix(120)) }
            for field in ["context_window", "max_output_tokens"] {
                if let value = row[field] as? Int, value > 0, value <= 100_000_000 { model[field] = value }
            }
            for field in ["input_modalities", "output_modalities"] {
                if let values = row[field] as? [String] { model[field] = Array(Set(values.filter { ["text","image","audio","video"].contains($0) })).sorted() }
            }
            if let effort = row["effort"] as? [String: Any], let levels = effort["supported_levels"] as? [String] {
                let supported = Array(levels.filter { ["low","medium","high","max"].contains($0) }.prefix(4))
                var clean: [String: Any] = ["supported_levels": supported]
                if let level = effort["default_level"] as? String, supported.contains(level) { clean["default_level"] = level }
                model["effort"] = clean
            }
            result.append(model)
            if result.count == 50 { break }
        }
        return result.isEmpty ? nil : result
    }
    static func fresh(updated: Double, now: Double) -> Bool { updated > 0 && now >= updated && now - updated < 86400 }
}

// BEGIN GOLDGRAM_AI_USAGE_V1
enum GoldgramAIUsagePolicy {
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 100_000_000,
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return Int(number.doubleValue)
    }
    static func tokens(_ raw: Any?) -> [String: Int] {
        guard let root = raw as? [String: Any] else { return [:] }
        var result: [String: Int] = [:]
        for key in ["prompt_tokens", "completion_tokens", "total_tokens", "prompt_cache_hit_tokens", "prompt_cache_miss_tokens"] {
            if let n = integer(root[key]) { result[key] = n }
        }
        if let details = root["completion_tokens_details"] as? [String: Any], let n = integer(details["reasoning_tokens"]) {
            result["reasoning_tokens"] = n
        }
        return result
    }
    static func balance(_ data: Data) -> [String: Any]? {
        guard data.count <= 16 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let available = root["is_available"] as? NSNumber, CFGetTypeID(available) == CFBooleanGetTypeID(),
              let rows = root["balance_infos"] as? [[String: Any]], !rows.isEmpty, rows.count <= 2 else { return nil }
        var seen = Set<String>()
        var clean: [[String: String]] = []
        for row in rows {
            guard let currency = row["currency"] as? String, ["CNY", "USD"].contains(currency), seen.insert(currency).inserted else { return nil }
            var entry = ["currency": currency]
            for field in ["total_balance", "granted_balance", "topped_up_balance"] {
                guard let value = row[field] as? String, value.utf8.count <= 32,
                      value.range(of: #"^-?[0-9]{1,16}(\.[0-9]{1,12})?$"#, options: .regularExpression) != nil,
                      Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) != nil else { return nil }
                entry[field] = value
            }
            clean.append(entry)
        }
        return ["is_available": available.boolValue, "balance_infos": clean]
    }
    static func elapsed(_ start: TimeInterval, now: TimeInterval) -> Int {
        let ms = (now - start) * 1000
        guard ms.isFinite else { return 0 }
        return Int(max(0, min(3_600_000, ms.rounded())))
    }
    static func report(_ records: [GoldgramAIUsageRecord]) -> [String: Any] {
        var totals: [String: Int64] = [:]
        var outcomes: [String: Int] = [:]
        for record in records {
            outcomes[record.outcome, default: 0] += 1
            for (key, value) in record.tokens { totals[key, default: 0] += Int64(value) }
        }
        let rows = records.map { item -> [String: Any] in
            var row: [String: Any] = ["timestamp": item.timestamp, "durationMs": item.durationMs, "outcome": item.outcome, "usage": item.tokens]
            if let model = item.model { row["model"] = model }
            if let status = item.httpStatus { row["httpStatus"] = status }
            return row
        }
        return ["scope": "localPluginRetainedRequests", "capacity": 128, "requests": records.count,
                "requestsWithUsage": records.filter { !$0.tokens.isEmpty }.count, "totals": totals,
                "outcomes": outcomes, "records": rows, "cost": NSNull()]
    }
}
struct GoldgramAIUsageRecord: Codable {
    let timestamp: Double
    let durationMs: Int
    let outcome: String
    let model: String?
    let httpStatus: Int?
    let tokens: [String: Int]
}
struct GoldgramAIUsageLedger {
    private(set) var records: [GoldgramAIUsageRecord] = []
    init(data: Data?) {
        guard let data, data.count <= 128 * 1024,
              let decoded = try? JSONDecoder().decode([GoldgramAIUsageRecord].self, from: data) else { return }
        records = Array(decoded.suffix(128))
    }
    mutating func append(_ record: GoldgramAIUsageRecord) {
        records.append(record)
        if records.count > 128 { records.removeFirst(records.count - 128) }
    }
    func encoded() -> Data? { try? JSONEncoder().encode(records) }
}
// END GOLDGRAM_AI_USAGE_V1

// BEGIN GOLDGRAM_FINANCE_V2
struct GoldgramFinanceCost {
    let low: Decimal
    let high: Decimal
}
enum GoldgramFinancePricing {
    // USD per million tokens, official published rate snapshot, checked 2026-11-28.
    static let version = "2026-11-28"
    static let validFrom: Double = 1795824000
    static let validUntil: Double = validFrom + 30 * 86400
    static func modelGroup(_ model: String?) -> String {
        switch model {
        case "deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp": return "Flash"
        case "deepseek-v4-pro": return "Pro"
        default: return "Другие / неизвестно"
        }
    }
    static func estimate(_ record: GoldgramAIUsageRecord) -> GoldgramFinanceCost? {
        guard record.outcome == "completed", record.timestamp >= validFrom, record.timestamp < validUntil,
              record.durationMs >= 0, record.durationMs <= 3_600_000,
              record.timestamp + Double(record.durationMs) / 1000 < validUntil,
              let input = record.tokens["prompt_tokens"], let hit = record.tokens["prompt_cache_hit_tokens"],
              let miss = record.tokens["prompt_cache_miss_tokens"], let output = record.tokens["completion_tokens"],
              [input, hit, miss, output].allSatisfy({ (0...100_000_000).contains($0) }), hit + miss == input else { return nil }
        let prices: [String]
        switch modelGroup(record.model) {
        case "Flash": prices = ["0.003", "0.15", "0.6"]
        case "Pro": prices = ["0.022", "0.66", "1.98"]
        default: return nil
        }
        let rate = prices.compactMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        guard rate.count == 3 else { return nil }
        let low = (Decimal(hit) * rate[0] + Decimal(miss) * rate[1] + Decimal(output) * rate[2]) / Decimal(1_000_000)
        // A weekday peak interval may be a Chinese public holiday. Never guess the holiday calendar.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: record.timestamp)
        let end = start.addingTimeInterval(Double(record.durationMs) / 1000)
        let day = calendar.startOfDay(for: start)
        let mayPeak = [day, day.addingTimeInterval(86400)].contains { date in
            let weekday = calendar.component(.weekday, from: date)
            guard (2...6).contains(weekday) else { return false }
            return [(1,4),(6,10)].contains { hours in
                start < date.addingTimeInterval(Double(hours.1 * 3600)) && end >= date.addingTimeInterval(Double(hours.0 * 3600))
            }
        }
        return GoldgramFinanceCost(low: low, high: mayPeak ? low * 2 : low)
    }
    static func positive(_ text: String) -> Decimal? {
        guard text.utf8.count <= 20, text.range(of: #"^[0-9]{1,7}(\.[0-9]{1,6})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        return value
    }
    static func day(_ timestamp: Double) -> Int? {
        guard timestamp.isFinite, timestamp >= 0, timestamp <= 4_102_444_800 else { return nil }
        return Int(timestamp / 86400)
    }
}
struct GoldgramFinanceTotals: Codable {
    var requests: Int64 = 0
    var completed: Int64 = 0
    var known: Int64 = 0
    var priced: Int64 = 0
    var milliseconds: Int64 = 0
    var tokens: [String: Int64] = [:]
    var low: Decimal = 0
    var high: Decimal = 0
    static let tokenKeys = ["prompt_tokens", "completion_tokens", "total_tokens", "prompt_cache_hit_tokens", "prompt_cache_miss_tokens", "reasoning_tokens"]
    static let cap: Int64 = 1_000_000_000_000
    static func add(_ a: Int64, _ b: Int64) -> Int64 { min(cap, max(0, min(cap, a)) + max(0, min(cap, b))) }
    mutating func record(_ item: GoldgramAIUsageRecord, priced allowPrice: Bool) {
        requests = Self.add(requests, 1)
        if item.outcome == "completed" { completed = Self.add(completed, 1) }
        milliseconds = Self.add(milliseconds, Int64(max(0, min(3_600_000, item.durationMs))))
        let usage = item.tokens.filter { Self.tokenKeys.contains($0.key) && (0...100_000_000).contains($0.value) }
        if !usage.isEmpty { known = Self.add(known, 1) }
        for (k,v) in usage { tokens[k] = Self.add(tokens[k] ?? 0, Int64(v)) }
        if allowPrice, let cost = GoldgramFinancePricing.estimate(item) {
            priced = Self.add(priced, 1); low = min(Decimal(Self.cap), low + cost.low); high = min(Decimal(Self.cap), high + cost.high)
        }
    }
    mutating func merge(_ other: Self) {
        requests = Self.add(requests, other.requests); completed = Self.add(completed, other.completed)
        known = Self.add(known, other.known); priced = Self.add(priced, other.priced)
        milliseconds = Self.add(milliseconds, other.milliseconds)
        for k in Self.tokenKeys { if let v = other.tokens[k] { tokens[k] = Self.add(tokens[k] ?? 0,v) } }
        low = min(Decimal(Self.cap), low + other.low); high = min(Decimal(Self.cap), high + other.high)
    }
    var valid: Bool {
        [requests,completed,known,priced,milliseconds].allSatisfy { (0...Self.cap).contains($0) } && completed <= requests && known <= requests && priced <= known &&
        tokens.allSatisfy { Self.tokenKeys.contains($0.key) && (0...Self.cap).contains($0.value) } && !low.isNaN && !high.isNaN && low >= 0 && high >= low && high <= Decimal(Self.cap)
    }
}
struct GoldgramFinanceLedger: Codable {
    var recent: [GoldgramAIUsageRecord] = []
    var days: [Int: [String: GoldgramFinanceTotals]] = [:]
    static let groups = ["Flash", "Pro", "Другие / неизвестно"]
    init() {}
    init(data: Data?, legacy: [GoldgramAIUsageRecord]) {
        if let data, data.count <= 2 * 1024 * 1024, let value = try? JSONDecoder().decode(Self.self, from: data),
           value.recent.count <= 128, value.days.count <= 366,
           value.days.allSatisfy({ (0...47482).contains($0.key) && $0.value.count <= 3 && $0.value.allSatisfy { Self.groups.contains($0.key) && $0.value.valid } }) {
            self = value; return
        }
        for item in legacy.suffix(128) { append(item, priced: false) }
    }
    mutating func append(_ item: GoldgramAIUsageRecord, priced: Bool = true) {
        guard let day = GoldgramFinancePricing.day(item.timestamp) else { return }
        recent.append(item); recent = Array(recent.suffix(128))
        let group = GoldgramFinancePricing.modelGroup(item.model)
        var models = days[day] ?? [:]
        var totals = models[group] ?? GoldgramFinanceTotals()
        totals.record(item, priced: priced); models[group] = totals; days[day] = models
        if let latest = days.keys.max() { days = days.filter { $0.key >= latest - 365 } }
    }
    func selected(_ period: Int, now: Date = Date()) -> [Int: [String: GoldgramFinanceTotals]] {
        guard let today = GoldgramFinancePricing.day(now.timeIntervalSince1970) else { return [:] }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let month = cal.dateInterval(of: .month, for: now)?.start.timeIntervalSince1970 ?? now.timeIntervalSince1970
        let first = period == 0 ? today : period == 1 ? today - 6 : period == 2 ? (GoldgramFinancePricing.day(month) ?? today) : today - 365
        return days.filter { $0.key >= first && $0.key <= today }
    }
    static func totals(_ days: [Int: [String: GoldgramFinanceTotals]]) -> GoldgramFinanceTotals {
        var result = GoldgramFinanceTotals()
        for day in days.values { for value in day.values { result.merge(value) } }
        return result
    }
}
// END GOLDGRAM_FINANCE_V2

struct GoldgramAIConfig {
    let account: String
    private var prefix: String { "goldgram.ai.v1." + account + "." }
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: prefix + "enabled") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: prefix + "enabled") }
    }
    var prompt: String {
        get { UserDefaults.standard.string(forKey: prefix + "prompt") ?? "Напиши естественный ответ на приведённый текст по-русски. Не выдумывай факты. Верни только текст ответа." }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: prefix + "prompt") }
    }
    var model: String {
        get { UserDefaults.standard.string(forKey: prefix + "model") ?? "deepseek-v4-pro" }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: prefix + "model") }
    }
    var vertical: Double {
        get { (UserDefaults.standard.object(forKey: prefix + "vertical") as? NSNumber)?.doubleValue ?? 0.82 }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: prefix + "vertical") }
    }
    var horizontal: Double {
        get { (UserDefaults.standard.object(forKey: prefix + "horizontal") as? NSNumber)?.doubleValue ?? 0.0 }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: prefix + "horizontal") }
    }
    private var usageLedgerKey: String { prefix + "usageLedger.v1" }
    private var financeLedgerKey: String { prefix + "financeLedger.v2" }
    func financeLedger() -> GoldgramFinanceLedger {
        GoldgramFinanceLedger(data: UserDefaults.standard.data(forKey: financeLedgerKey),
                              legacy: GoldgramAIUsageLedger(data: UserDefaults.standard.data(forKey: usageLedgerKey)).records)
    }
    func recordUsage(_ record: GoldgramAIUsageRecord) {
        var ledger = financeLedger()
        ledger.append(record)
        if let data = try? JSONEncoder().encode(ledger), data.count <= 2 * 1024 * 1024 {
            UserDefaults.standard.set(data, forKey: financeLedgerKey)
        } else {
            // Retain the last known aggregate; never replace it with an empty history.
            return
        }
        // Preserve the last 128 records for older app versions.
        if let recent = try? JSONEncoder().encode(ledger.recent), recent.count <= 128 * 1024 {
            UserDefaults.standard.set(recent, forKey: usageLedgerKey)
        }
    }
    func usageReport() -> [String: Any] {
        GoldgramAIUsagePolicy.report(financeLedger().recent)
    }
    func clearUsageLedger() {
        UserDefaults.standard.removeObject(forKey: financeLedgerKey)
        UserDefaults.standard.removeObject(forKey: usageLedgerKey)
    }
    func financeThreshold(_ name: String) -> Decimal? {
        guard ["budgetUSD", "lowUSD", "lowCNY"].contains(name), let value = UserDefaults.standard.string(forKey: prefix + "finance." + name) else { return nil }
        return GoldgramFinancePricing.positive(value)
    }
    func setFinanceThreshold(_ name: String, value: Decimal?) {
        guard ["budgetUSD", "lowUSD", "lowCNY"].contains(name) else { return }
        let key = prefix + "finance." + name
        if let value { UserDefaults.standard.set(NSDecimalNumber(decimal: value).stringValue, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    func clearFinancePreferences() {
        for name in ["budgetUSD", "lowUSD", "lowCNY"] { setFinanceThreshold(name, value: nil) }
    }
    func financeBudgetReached() -> Bool {
        guard let limit = financeThreshold("budgetUSD") else { return false }
        let totals = GoldgramFinanceLedger.totals(financeLedger().selected(2))
        return totals.priced > 0 && totals.high >= limit
    }
    private var streamUsageKey: String { prefix + "streamUsage.v1" }
    var lastStreamUsage: [String: Int]? { UserDefaults.standard.dictionary(forKey: streamUsageKey) as? [String: Int] }
    func saveStreamUsage(_ usage: [String: Int]) { UserDefaults.standard.set(usage, forKey: streamUsageKey) }
    func clearStreamUsage() { UserDefaults.standard.removeObject(forKey: streamUsageKey) }
    private var catalogKey: String { prefix + "modelCatalog.v1" }
    var modelCatalog: (models: [[String: Any]], updated: Double)? {
        guard readKey() != nil,
              let stored = UserDefaults.standard.data(forKey: catalogKey), stored.count <= 128 * 1024,
              let envelope = try? JSONSerialization.jsonObject(with: stored) as? [String: Any],
              let updated = envelope["updated"] as? Double, updated.isFinite, updated > 0,
              let payload = try? JSONSerialization.data(withJSONObject: ["object":"list","data":envelope["data"] ?? []]),
              let models = GoldgramNetworkPolicy.catalog(payload) else { return nil }
        return (models, updated)
    }
    func saveCatalog(_ models: [[String: Any]]) {
        if let data = try? JSONSerialization.data(withJSONObject: ["updated":Date().timeIntervalSince1970,"data":models]), data.count <= 128 * 1024 {
            UserDefaults.standard.set(data, forKey: catalogKey)
        }
    }
    func clearCatalog() { UserDefaults.standard.removeObject(forKey: catalogKey); clearStreamUsage() }
    private var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "GoldgramAI.DeepSeek.v1", kSecAttrAccount as String: account]
    }
    func readKey() -> String? {
        var query = keyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func saveKey(_ key: String) -> Bool {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512, !value.contains("\n"), !value.contains("\r") else { return false }
        let data = Data(value.utf8)
        let update = SecItemUpdate(keyQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { clearCatalog(); return true }
        guard update == errSecItemNotFound else { return false }
        var query = keyQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let saved = SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        if saved { clearCatalog() }; return saved
    }
    func deleteKey() -> Bool {
        let status = SecItemDelete(keyQuery as CFDictionary)
        let deleted = status == errSecSuccess || status == errSecItemNotFound
        if deleted { clearCatalog() }; return deleted
    }
}

final class GoldgramAINoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private enum GoldgramAIProtocol {
    static func request(key: String, model: String, prompt: String, draft: String) -> URLRequest? {
        guard !model.isEmpty, model.utf8.count <= 100, !prompt.isEmpty, prompt.utf8.count <= 12000,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.utf8.count <= 16000 else { return nil }
        let payload: [String: Any] = ["model": model, "messages": [
            ["role": "system", "content": prompt], ["role": "user", "content": draft]
        ], "stream": false, "max_tokens": 2048]
        guard let url = URL(string: "https://api.deepseek.com/chat/completions"),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.httpBody = data
        return request
    }
    static func answer(_ data: Data) -> String? {
        guard data.count <= 2 * 1024 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any],
              let raw = message["content"] as? String else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 4096 else { return nil }
        return text
    }
}

final class GoldgramAISettings: UITableViewController {
    private let config: GoldgramAIConfig
    private let isCurrent: () -> Bool
    init(account: String, isCurrent: @escaping () -> Bool) {
        config = GoldgramAIConfig(account: account); self.isCurrent = isCurrent
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() { super.viewDidLoad(); title = "AI Command Center" }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 6 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Включите AI и вернитесь в чат. Вставьте текст в черновик, нажмите AI и подтвердите отправку текста и промпта в DeepSeek. Ответ вставляется только после подтверждения. Ключ хранится в Keychain, не в JS. Это резервный нативный помощник. Для AI Commander 2.1.8 откройте сам импортированный плагин и его настройки."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = ["Плавающая кнопка AI", "API-ключ DeepSeek", "Модель (ID из API)", "Системный промпт", "Сброс положения кнопки", "Удалить API-ключ"][indexPath.row]
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 3
        if indexPath.row == 0 { cell.detailTextLabel?.text = config.enabled ? "Включена" : "Выключена" }
        if indexPath.row == 1 { cell.detailTextLabel?.text = config.readKey() == nil ? "Не задан" : "Сохранён в Keychain" }
        if indexPath.row == 2 { cell.detailTextLabel?.text = config.model }
        if indexPath.row == 3 { cell.detailTextLabel?.text = config.prompt }
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard isCurrent() else { return }
        switch indexPath.row {
        case 0: config.enabled.toggle(); tableView.reloadData()
        case 1: edit("API-ключ DeepSeek", value: "", secure: true) { [weak self] value in
            guard let self else { return }
            if !self.config.saveKey(value) { self.notice("Не удалось сохранить ключ.") }
        }
        case 2:
            let screen = GoldgramModelCatalogScreen(config: config, valid: { [weak self] in
                guard let self else { return false }; return self.isCurrent() && goldgramAIAllowed(account: self.config.account)
            }, fallback: [["value":"deepseek-v4-pro","title":"deepseek-v4-pro"],["value":"deepseek-flash","title":"deepseek-flash"]], selected: config.model, choose: { [weak self] model in
                guard let self, self.isCurrent(), GoldgramNetworkPolicy.modelID(model) else { return }
                self.config.model = model; self.tableView.reloadData()
            })
            navigationController?.pushViewController(screen, animated: true)
        case 3:
            let editor = GoldgramAIPromptEditor(prompt: config.prompt) { [weak self] value in
                guard let self, self.isCurrent(), !value.isEmpty, value.utf8.count <= 12000 else { return }
                self.config.prompt = value; self.navigationController?.popViewController(animated: true); self.tableView.reloadData()
            }
            navigationController?.pushViewController(editor, animated: true)
        case 4: config.horizontal = 0; config.vertical = 0.82
        default:
            let alert = UIAlertController(title: "Удалить ключ?", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in
                guard let self, self.isCurrent() else { return }
                if !self.config.deleteKey() { self.notice("Не удалось удалить ключ.") }
                self.tableView.reloadData()
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
        }
    }
    private func notice(_ text: String) {
        let alert = UIAlertController(title: "Goldgram AI", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
    private func edit(_ title: String, value: String, secure: Bool, save: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = value; field.isSecureTextEntry = secure; field.autocorrectionType = .no; field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] _ in
            guard let self, self.isCurrent(), let value = alert?.textFields?.first?.text else { return }
            save(value); self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
    }
}

private final class GoldgramAIPromptEditor: UIViewController {
    private let input = UITextView()
    private let prompt: String
    private let saveValue: (String) -> Void
    init(prompt: String, save: @escaping (String) -> Void) {
        self.prompt = prompt; saveValue = save; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Промпт"; view.backgroundColor = .systemBackground
        input.text = prompt; input.font = .preferredFont(forTextStyle: .body)
        input.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(input)
        NSLayoutConstraint.activate([input.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            input.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            input.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            input.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)])
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
    }
    @objc private func save() { saveValue(input.text ?? "") }
}

public final class GoldgramAIButton: UIButton {
    private let config: GoldgramAIConfig
    private weak var presenter: UIViewController?
    private let snapshot: () -> GoldgramAIDraft?
    private let insert: (GoldgramAIDraft, String) -> Bool
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var token = UUID()
    private weak var activeAlert: UIAlertController?
    private var dragStart = CGPoint.zero
    private var pluginRun: GoldgramPluginChatRun?
    private let pluginContext: (() -> [String: Any])?
    private let idleTitle: String
    private let registration: GoldgramPluginRegistration?
    private var pendingAlert: UIAlertController?
    fileprivate var moveGroup: ((UIPanGestureRecognizer) -> Void)?
    fileprivate var isBusy: Bool { task != nil || pluginRun != nil || pendingAlert != nil }
    private var selectedAction: (String, [String: Any])?

    public static func isEnabled(account: String) -> Bool {
        goldgramAIAllowed(account: account) && (!GoldgramPluginChatRun.registrations(account: account).isEmpty || GoldgramAIConfig(account: account).enabled)
    }
    fileprivate init(account: String, registration: GoldgramPluginRegistration?, presenter: UIViewController, snapshot: @escaping () -> GoldgramAIDraft?, pluginContext: (() -> [String: Any])? = nil, insert: @escaping (GoldgramAIDraft, String) -> Bool) {
        self.pluginContext = pluginContext
        self.registration = registration
        self.idleTitle = registration?.title ?? "AI"
        config = GoldgramAIConfig(account: account); self.presenter = presenter; self.snapshot = snapshot; self.insert = insert
        super.init(frame: CGRect(x: 0, y: 0, width: 46, height: 38))
        backgroundColor = .systemBlue; layer.cornerRadius = 19
        setTitle(idleTitle, for: .normal); setTitleColor(.white, for: .normal); titleLabel?.font = .boldSystemFont(ofSize: 15)
        accessibilityLabel = registration?.name ?? "Goldgram AI"; accessibilityHint = "Сгенерировать ответ на текст черновика"
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    required init?(coder: NSCoder) { return nil }
    deinit { NotificationCenter.default.removeObserver(self); task?.cancel(); session?.invalidateAndCancel() }
    @objc private func background() { cancel() }
    public func cancel() {
        guard task != nil || pluginRun != nil || activeAlert != nil || pendingAlert != nil else { return }
        pendingAlert = nil
        token = UUID(); let oldPlugin = pluginRun; pluginRun = nil; oldPlugin?.cancel(); task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil
        setTitle(idleTitle, for: .normal)
        if let alert = activeAlert, alert.presentingViewController != nil { alert.dismiss(animated: false) }
        activeAlert = nil
    }
    private func usable() -> CGRect? {
        guard let host = superview else { return nil }
        let safe = host.bounds.inset(by: host.safeAreaInsets)
        let keyboardTop = host.keyboardLayoutGuide.layoutFrame.minY
        let bottom = keyboardTop > safe.minY + 100 ? min(safe.maxY, keyboardTop) : safe.maxY
        let rect = CGRect(x: safe.minX + 30, y: safe.minY + 60, width: safe.width - 60, height: bottom - safe.minY - 125)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }
    public func reposition() {
        guard let host = superview, let rect = usable() else { return }
        center = CGPoint(x: rect.minX + rect.width * CGFloat(max(0,min(1,config.horizontal))),
                         y: rect.minY + rect.height * CGFloat(max(0,min(1,config.vertical))))
        host.bringSubviewToFront(self)
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        if let moveGroup { moveGroup(gesture); return }
        guard let host = superview, let rect = usable() else { return }
        if gesture.state == .began { dragStart = center }
        let delta = gesture.translation(in: host)
        let x = max(rect.minX, min(rect.maxX, dragStart.x + delta.x))
        let y = max(rect.minY, min(rect.maxY, dragStart.y + delta.y))
        center = CGPoint(x: x, y: y)
        if gesture.state == .ended || gesture.state == .cancelled {
            config.horizontal = Double((x - rect.minX) / rect.width); config.vertical = Double((y - rect.minY) / rect.height)
        }
    }
    private func presentAlert(_ alert: UIAlertController) {
        guard let presenter, presenter.viewIfLoaded?.window != nil else { return }
        if presenter.presentedViewController != nil { pendingAlert = alert; setTitle("✓", for: .normal); return }
        pendingAlert = nil; setTitle(idleTitle, for: .normal)
        activeAlert = alert; presenter.present(alert, animated: true)
    }
    private func notice(_ text: String) {
        let alert = UIAlertController(title: "Goldgram AI", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); presentAlert(alert)
    }
    public static func pluginMenu(account: String, mediaOnly: Bool = false) -> [[String: String]] { GoldgramPluginChatRun.menu(account: account, mediaOnly: mediaOnly) }
    public func invokePluginAction(key: String, message: [String: Any]) {
        guard let registration, registration.actions.contains(where: { $0["id"] == key }) else { return }
        if pendingAlert != nil { tapped(); return }
        guard !isBusy else { return }
        selectedAction = (key, message); tapped(); selectedAction = nil
    }
    fileprivate func trigger() { tapped() }
    private func authorized() -> Bool {
        if let registration { return GoldgramPluginChatRun.authorized(account: config.account, registration: registration) }
        return GoldgramAIConfig(account: config.account).enabled && GoldgramPluginChatRun.registrations(account: config.account).isEmpty && goldgramAIAllowed(account: config.account)
    }
    @objc private func tapped() {
        if let pendingAlert { if authorized(), snapshot() != nil { presentAlert(pendingAlert) } else { cancel() }; return }
        if let pluginRun, pluginRun.stopStream() { return }
        if task != nil || pluginRun != nil { cancel(); return }
        guard authorized(), let draft = snapshot() else { return }
        if let registration, let presenter {
            let id = registration.id
            let current = UUID(); token = current
            let runner = GoldgramPluginChatRun(); pluginRun = runner; setTitle("×", for: .normal)
            var context = pluginContext?() ?? [:]; context["draft"] = draft.text; context["draftWritable"] = draft.writable
            let action = selectedAction
            if let action { context["selectedMessage"] = action.1 }
            runner.start(account: config.account, presenter: presenter, id: id, context: context, event: action == nil ? "floating.tap" : "context.tap", key: action?.0, valid: { [weak self] in
                guard let self else { return false }; return self.token == current && self.snapshot() == draft && self.authorized()
            }, completion: { [weak self] output, error in
                guard let self, self.token == current else { return }
                self.pluginRun = nil; self.setTitle(self.idleTitle, for: .normal)
                guard self.snapshot() == draft, self.authorized() else { return }
                if let output, let kind = output["kind"] as? String, let text = output["text"] as? String {
                    if kind == "draft" {
                        if draft.writable { self.preview(text, draft: draft, token: current, pluginId: id) }
                        else if !text.isEmpty { self.notice("Результат плагина (чат только для чтения)\n\n" + text) }
                    }
                    else if kind == "clipboard" {
                        let alert = UIAlertController(title: "Копировать результат?", message: text, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "Копировать", style: .default) { [weak self] _ in guard let self, self.snapshot() == draft, self.token == current, self.authorized() else { return }; UIPasteboard.general.string = text })
                        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); self.presentAlert(alert)
                    } else { self.notice((output["title"] as? String ?? "AI") + "\n\n" + text) }
                } else if let error { self.notice(error) }
            }); return
        }
        guard registration == nil, draft.writable else { return }
        guard let key = config.readKey() else { notice("Задайте ключ в Goldgram → Плагины → AI Command Center."); return }
        let prompt = config.prompt, model = config.model
        guard let request = GoldgramAIProtocol.request(key: key, model: model, prompt: prompt, draft: draft.text) else {
            notice("Введите текст в поле сообщения. Проверьте размер текста, промпт и модель."); return
        }
        let alert = UIAlertController(title: "Передать текст в DeepSeek?", message: "Модель: " + model + "\n\nПромпт:\n" + prompt + "\n\nТекст:\n" + draft.text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Сгенерировать", style: .default) { [weak self] _ in
            guard let self, self.snapshot() == draft, self.authorized() else { return }
            self.activeAlert = nil; self.start(request, draft: draft)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); presentAlert(alert)
    }
    private func start(_ request: URLRequest, draft: GoldgramAIDraft) {
        guard task == nil else { return }
        let current = UUID(); token = current
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false; settings.httpCookieStorage = nil
        settings.urlCache = nil; settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = 90; settings.timeoutIntervalForResource = 120
        let session = URLSession(configuration: settings, delegate: GoldgramAINoRedirect(), delegateQueue: nil)
        self.session = session
        setTitle("×", for: .normal)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == current else { return }
                self.task = nil; self.session?.finishTasksAndInvalidate(); self.session = nil; self.setTitle("AI", for: .normal)
                guard self.snapshot() == draft, self.authorized() else { return }
                guard error == nil, let http = response as? HTTPURLResponse else { self.notice("Сетевая ошибка или тайм-аут."); return }
                guard http.statusCode == 200 else { self.notice("DeepSeek HTTP " + String(http.statusCode) + ". Проверьте ключ, баланс и ID модели."); return }
                guard let data, let answer = GoldgramAIProtocol.answer(data) else { self.notice("Нет ответа или ответ превышает 4096 символов."); return }
                self.preview(answer, draft: draft, token: current)
            }
        }
        self.task = task; task.resume()
    }
    private func preview(_ answer: String, draft: GoldgramAIDraft, token: UUID, pluginId: UUID? = nil) {
        guard draft.writable, self.token == token, snapshot() == draft, authorized(), !answer.isEmpty, answer.utf16.count <= 4096 else { return }
        if let pluginId {
            let policy = GoldgramPluginChatRun.draftPolicy(account: config.account, id: pluginId)
            guard policy.allowed else { return }
            if policy.skip { _ = insert(draft, answer); return }
        }
        let alert = UIAlertController(title: "Результат AI", message: answer, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Вставить в черновик", style: .default) { [weak self] _ in
            guard let self, self.token == token, self.snapshot() == draft, self.authorized() else { return }
            if let pluginId, !GoldgramPluginChatRun.draftPolicy(account: self.config.account, id: pluginId).allowed { return }
            self.activeAlert = nil
            _ = self.insert(draft, answer)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); presentAlert(alert)
    }
}


// One host for all registered plugins. Each button owns its own request,
// cancellation token and result; non-button registrations are still routable.
public final class GoldgramAIButtonGroup: UIView {
    private let account: String
    private weak var presenter: UIViewController?
    private let snapshot: () -> GoldgramAIDraft?
    private let pluginContext: (() -> [String: Any])?
    private let insert: (GoldgramAIDraft, String) -> Bool
    private var registrations: [GoldgramPluginRegistration] = []
    private var buttons: [UUID: GoldgramAIButton] = [:]
    private var fallback: GoldgramAIButton?
    private let overflow = UIButton(type: .system)
    private var overflowItems: [GoldgramPluginRegistration] = []
    private var dragOrigin = CGPoint.zero
    private var dragAnchor: CGPoint?
    public static func isEnabled(account: String) -> Bool { GoldgramAIButton.isEnabled(account: account) }
    public static func skipTimedTextPrompt(account: String, actionKey: String) -> Bool { GoldgramPluginChatRun.skipTimedTextPrompt(account: account, actionKey: actionKey) }
    public static func pluginMenu(account: String, mediaOnly: Bool = false) -> [[String: String]] { GoldgramPluginChatRun.menu(account: account, mediaOnly: mediaOnly) }
    public init(account: String, presenter: UIViewController, snapshot: @escaping () -> GoldgramAIDraft?, pluginContext: (() -> [String: Any])? = nil, insert: @escaping (GoldgramAIDraft, String) -> Bool) {
        self.account = account; self.presenter = presenter; self.snapshot = snapshot; self.pluginContext = pluginContext; self.insert = insert
        super.init(frame: .zero)
        backgroundColor = .clear
        overflow.backgroundColor = .systemBlue; overflow.tintColor = .white; overflow.layer.cornerRadius = 19
        overflow.addTarget(self, action: #selector(showOverflow), for: .touchUpInside); addSubview(overflow)
        overflow.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(registryChanged(_:)), name: .goldgramPluginsChanged, object: nil)
        sync()
    }
    required init?(coder: NSCoder) { return nil }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func registryChanged(_ note: Notification) {
        guard note.object as? String == account else { return }
        sync(); reposition()
    }
    private func make(_ registration: GoldgramPluginRegistration?) -> GoldgramAIButton? {
        guard let presenter else { return nil }
        let button = GoldgramAIButton(account: account, registration: registration, presenter: presenter, snapshot: snapshot, pluginContext: pluginContext, insert: insert)
        button.moveGroup = { [weak self] gesture in self?.drag(gesture) }
        addSubview(button); return button
    }
    private func sync() {
        let next = GoldgramPluginChatRun.registrations(account: account)
        for old in registrations {
            if !next.contains(old) { if let button = buttons.removeValue(forKey: old.id) { button.cancel(); button.removeFromSuperview() } }
        }
        registrations = next
        for registration in next where buttons[registration.id] == nil { buttons[registration.id] = make(registration) }
        let needsFallback = next.isEmpty && GoldgramAIConfig(account: account).enabled && goldgramAIAllowed(account: account)
        if needsFallback && fallback == nil { fallback = make(nil) }
        if !needsFallback, let old = fallback { old.cancel(); old.removeFromSuperview(); fallback = nil }
    }
    public func cancel() {
        for button in Array(buttons.values) { button.cancel() }
        fallback?.cancel()
    }
    public func invokePluginAction(key: String, message: [String: Any]) {
        guard let (id, local) = GoldgramPluginRouting.splitAction(key), let button = buttons[id],
              registrations.contains(where: { $0.id == id && $0.actions.contains(where: { $0["id"] == local }) }) else { return }
        button.invokePluginAction(key: local, message: message)
    }
    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
    private func area() -> CGRect? {
        guard let parent = superview else { return nil }
        let safe = parent.bounds.inset(by: parent.safeAreaInsets)
        let keyboard = parent.keyboardLayoutGuide.layoutFrame.minY
        let bottom = keyboard > safe.minY + 100 ? min(safe.maxY, keyboard) : safe.maxY
        let rect = CGRect(x: safe.minX + 30, y: safe.minY + 60, width: safe.width - 60, height: bottom - safe.minY - 125)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }
    public func reposition() {
        guard let parent = superview else { return }
        frame = parent.bounds
        guard let rect = area() else { for button in buttons.values { button.isHidden = true }; fallback?.isHidden = true; overflow.isHidden = true; return }
        let shown = registrations.filter { $0.title != nil }
        for button in buttons.values { button.isHidden = true }
        fallback?.isHidden = true
        let columns = max(1, min(3, Int(rect.width / 54) + 1))
        let rows = max(1, min(2, Int(rect.height / 46) + 1))
        let capacity = columns * rows
        let limit = shown.count > capacity ? max(0, capacity - 1) : capacity
        var visible: [UIButton] = shown.prefix(limit).compactMap { buttons[$0.id] }
        overflowItems = Array(shown.dropFirst(limit))
        overflow.isHidden = overflowItems.isEmpty
        if !overflowItems.isEmpty { overflow.setTitle("+" + String(overflowItems.count), for: .normal); visible.append(overflow) }
        if let fallback, snapshot()?.writable == true { visible.append(fallback) }
        let usedColumns = min(columns, max(1, visible.count))
        let usedRows = max(1, (visible.count + columns - 1) / columns)
        let width = CGFloat(usedColumns - 1) * 54, height = CGFloat(usedRows - 1) * 46
        let config = GoldgramAIConfig(account: account)
        let availableX = max(0, rect.width - width), availableY = max(0, rect.height - height)
        let x = rect.minX + availableX * CGFloat(max(0,min(1,config.horizontal)))
        let y = rect.minY + availableY * CGFloat(max(0,min(1,config.vertical)))
        let anchor = dragAnchor ?? CGPoint(x: x, y: y)
        let origin = CGPoint(x: max(rect.minX,min(rect.minX+availableX,anchor.x)), y: max(rect.minY,min(rect.minY+availableY,anchor.y)))
        for (index, button) in visible.enumerated() {
            button.isHidden = false
            button.bounds = CGRect(x: 0, y: 0, width: 46, height: 38)
            button.center = CGPoint(x: origin.x + CGFloat(index % columns) * 54, y: origin.y + CGFloat(index / columns) * 46)
        }
        parent.bringSubviewToFront(self)
    }
    private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let rect = area() else { return }
        let visible = registrations.filter { $0.title != nil }.compactMap { buttons[$0.id] }.filter { !$0.isHidden }
        var controls: [UIButton] = visible.map { $0 as UIButton }
        if !overflow.isHidden { controls.append(overflow) }
        if let fallback, !fallback.isHidden { controls.append(fallback) }
        guard !controls.isEmpty else { return }
        let minX = controls.map { $0.center.x }.min() ?? rect.minX, maxX = controls.map { $0.center.x }.max() ?? rect.minX
        let minY = controls.map { $0.center.y }.min() ?? rect.minY, maxY = controls.map { $0.center.y }.max() ?? rect.minY
        let availableX = max(0, rect.width - (maxX-minX)), availableY = max(0, rect.height - (maxY-minY))
        if gesture.state == .began { dragOrigin = CGPoint(x: minX,y: minY) }
        let delta = gesture.translation(in: self)
        let x = max(rect.minX,min(rect.minX+availableX,dragOrigin.x+delta.x)), y = max(rect.minY,min(rect.minY+availableY,dragOrigin.y+delta.y))
        dragAnchor = CGPoint(x:x,y:y)
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            let config = GoldgramAIConfig(account: account)
            if availableX > 0 { config.horizontal = Double((x-rect.minX)/availableX) }
            if availableY > 0 { config.vertical = Double((y-rect.minY)/availableY) }
            dragAnchor = nil
        }
        reposition()
    }
    @objc private func showOverflow() {
        guard let presenter, presenter.presentedViewController == nil, snapshot() != nil else { return }
        let alert = UIAlertController(title: "Плагины", message: nil, preferredStyle: .actionSheet)
        for item in overflowItems {
            guard let button = buttons[item.id] else { continue }
            alert.addAction(UIAlertAction(title: item.name + (button.isBusy ? " · выполняется / результат" : ""), style: .default) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now()+0.35) { [weak self] in self?.buttons[item.id]?.trigger() }
            })
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.popoverPresentationController?.sourceView = overflow; alert.popoverPresentationController?.sourceRect = overflow.bounds
        presenter.present(alert, animated: true)
    }
}

// #274 bounded SSE parser; accumulate complete UTF-8 lines across packets.
// Never retain or return raw reasoning text, only an activity flag.
struct GoldgramStreamOptions: Codable, Equatable {
    var enabled = false
    var preview = true
    var reasoning = true
    var partial = false
    var usage = true
}

struct GoldgramSSEParser {
    private var buffer = Data()
    private var event: [String] = []
    private var eventBytes = 0
    private var received = 0
    private(set) var text = ""
    private(set) var thinking = false
    private(set) var usage: [String: Int] = [:]
    private(set) var model: String?
    private(set) var reason = "stop"
    private var sawFinish = false
    private(set) var done = false

    mutating func feed(_ data: Data) -> Bool {
        if done { return true }
        guard data.count <= 512 * 1024 - received else { return false }
        received += data.count; buffer.append(data)
        while let index = buffer.firstIndex(of: 10) {
            var line = Data(buffer[..<index])
            buffer.removeSubrange(...index)
            if line.last == 13 { line.removeLast() }
            guard line.count <= 64 * 1024, let value = String(data: line, encoding: .utf8) else { return false }
            if value.isEmpty {
                if !event.isEmpty {
                    let payload = event.joined(separator: "\n")
                    event.removeAll(keepingCapacity: true); eventBytes = 0
                    guard consume(payload) else { return false }
                    if done { return true }
                }
            } else if value.hasPrefix("data:") {
                var part = String(value.dropFirst(5))
                if part.first == " " { part.removeFirst() }
                eventBytes += part.utf8.count + 1
                guard eventBytes <= 64 * 1024 else { return false }
                event.append(part)
            }
        }
        return buffer.count <= 64 * 1024
    }

    private mutating func consume(_ value: String) -> Bool {
        if value == "[DONE]" { guard sawFinish else { return false }; done = true; thinking = false; return true }
        guard let root = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
              (root["error"] == nil || root["error"] is NSNull), let choices = root["choices"] as? [[String: Any]], choices.count <= 1 else { return false }
        if let reported = root["model"] as? String, GoldgramNetworkPolicy.modelID(reported) { model = reported }
        for (key, n) in GoldgramAIUsagePolicy.tokens(root["usage"]) { usage[key] = n }
        if let choice = choices.first {
            if let delta = choice["delta"] as? [String: Any] {
                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty { thinking = true }
                if let content = delta["content"] as? String, !content.isEmpty {
                    guard text.utf8.count + content.utf8.count <= 64 * 1024 else { return false }
                    text += content; thinking = false
                }
            }
            if let finish = choice["finish_reason"] as? String {
                guard ["stop","length"].contains(finish) else { return false }
                reason = finish; thinking = false; sawFinish = true
            }
        }
        return true
    }

    func response(partial: Bool) -> [String: Any] {
        var root: [String: Any] = ["choices": [["message": ["role": "assistant", "content": text], "finish_reason": partial ? "cancelled" : reason]], "goldgram_partial": partial]
        if !usage.isEmpty { root["usage"] = usage }
        if let model { root["model"] = model }
        return root
    }
}

// URLSession owns the delegate on a serial queue; UI receives bounded snapshots.
private final class GoldgramSSETransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var parser = GoldgramSSEParser()
    private var finished = false
    private var lastUpdate = Date.distantPast
    private let update: (GoldgramSSEParser) -> Void
    private let result: (GoldgramSSEParser?, String?) -> Void
    init(update: @escaping (GoldgramSSEParser) -> Void, result: @escaping (GoldgramSSEParser?, String?) -> Void) {
        self.update = update; self.result = result; super.init()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.mimeType?.lowercased() == "text/event-stream" else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            finish(nil, "DeepSeek SSE HTTP " + String(status) + " / invalid content type")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard parser.feed(data) else { finish(nil, "Некорректный или слишком большой поток SSE."); dataTask.cancel(); return }
        if parser.done { finish(parser, nil); return }
        if Date().timeIntervalSince(lastUpdate) >= 0.15 {
            lastUpdate = Date()
            let snapshot = parser
            DispatchQueue.main.async { [update] in update(snapshot) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if parser.done { finish(parser, nil) }
        else { finish(nil, "Поток прерван до завершения.") }
    }
    private func finish(_ value: GoldgramSSEParser?, _ error: String?) {
        guard !finished else { return }; finished = true
        DispatchQueue.main.async { [result] in result(value, error) }
    }
}

// Local nonmodal progress; does not write drafts or send Telegram events.
private final class GoldgramStreamPanel: UIView {
    static let marker = 804274
    private let status = UILabel()
    private let body = UITextView()
    init(host: UIView, options: GoldgramStreamOptions, stop: @escaping () -> Void) {
        super.init(frame: .zero)
        tag = Self.marker
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 16
        layer.borderWidth = 1; layer.borderColor = UIColor.separator.cgColor
        status.font = .preferredFont(forTextStyle: .subheadline); status.numberOfLines = 2
        status.text = "DeepSeek · ожидание ответа…"
        body.isEditable = false; body.font = .preferredFont(forTextStyle: .body)
        body.backgroundColor = .clear; body.textColor = .label; body.isHidden = !options.preview
        let button = UIButton(type: .system)
        button.setTitle("Остановить", for: .normal)
        button.addAction(UIAction { _ in stop() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [status, body, button])
        stack.axis = .vertical; stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack); host.addSubview(self)
        let preferredWidth = widthAnchor.constraint(equalToConstant: 340); preferredWidth.priority = .defaultHigh
        let bodyHeight = body.heightAnchor.constraint(equalToConstant: 130); bodyHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: host.safeAreaLayoutGuide.centerXAnchor),
            topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 12),
            widthAnchor.constraint(lessThanOrEqualTo: host.safeAreaLayoutGuide.widthAnchor, constant: -24), preferredWidth,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            bodyHeight,
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }
    required init?(coder: NSCoder) { return nil }
    func display(_ parser: GoldgramSSEParser, options: GoldgramStreamOptions) {
        var title = parser.thinking && options.reasoning ? "DeepSeek · рассуждает…" : "DeepSeek · генерация…"
        if options.usage, let n = parser.usage["total_tokens"] { title += " · \(n) токенов" }
        status.text = title
        if options.preview { body.text = parser.text }
        if options.preview, !body.text.isEmpty { body.scrollRangeToVisible(NSRange(location: (body.text as NSString).length - 1, length: 1)) }
    }
}

// Native request broker. Fixed provider routes, managed credentials, and explicit
// user actions; chat payload confirmation follows the per-plugin consent policy.
@MainActor
// Bounded generic tile picker. Only returns one explicit choice, never executes JS.
private final class GoldgramPluginTilePicker: UIViewController {
    private let heading: String
    private let choices: [[String: String]]
    private let detailed: Bool
    var onChoice: ((String?) -> Void)?
    private var chosen = false
    init(title: String, choices: [[String: String]], detailed: Bool = false) {
        self.heading = title; self.choices = choices; self.detailed = detailed
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = heading
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closePicker))
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16)
        ])
        let caption = UILabel()
        caption.text = detailed ? "Нажмите на нужный вариант" : "Выберите действие"
        caption.font = .preferredFont(forTextStyle: .subheadline)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .secondaryLabel; caption.numberOfLines = 0
        stack.addArrangedSubview(caption)
        let symbols = Set(["sparkles","message","pencil","globe","shield","list.bullet","text.alignleft","person.crop.circle","wallet.pass","chart.bar","questionmark.circle","doc.text","trash","arrow.uturn.backward","magnifyingglass","bolt","slider.horizontal.3"])
        let accent = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(red: 0.96, green: 0.79, blue: 0.40, alpha: 1) : UIColor(red: 0.48, green: 0.33, blue: 0.06, alpha: 1)
        }
        let columns = detailed || traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 1 : 2
        for offset in stride(from: 0, to: choices.count, by: columns) {
            let row = UIStackView()
            row.axis = .horizontal; row.spacing = 12; row.distribution = .fillEqually
            for index in offset..<min(offset + columns, choices.count) {
                let item = choices[index]
                let button = UIButton(type: .system)
                button.tag = index
                button.backgroundColor = .secondarySystemGroupedBackground
                button.layer.cornerRadius = 16
                button.layer.borderWidth = 1
                button.layer.borderColor = UIColor.separator.cgColor
                button.tintColor = accent
                let label = item["title"] ?? ""
                let requested = item["icon"] ?? "sparkles"
                let symbol = symbols.contains(requested) ? requested : "sparkles"
                if detailed {
                    let text = UILabel()
                    text.text = label; text.numberOfLines = 0
                    text.font = .preferredFont(forTextStyle: .body)
                    text.adjustsFontForContentSizeCategory = true
                    text.textColor = .label
                    text.translatesAutoresizingMaskIntoConstraints = false
                    button.addSubview(text)
                    NSLayoutConstraint.activate([
                        text.topAnchor.constraint(equalTo: button.topAnchor, constant: 16),
                        text.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -16),
                        text.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
                        text.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16)
                    ])
                } else if #available(iOS 15.0, *) {
                    var config = UIButton.Configuration.plain()
                    config.title = label
                    config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .medium))
                    config.imagePlacement = .top; config.imagePadding = 9
                    config.titleAlignment = .center
                    config.baseForegroundColor = accent
                    config.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 10, bottom: 16, trailing: 10)
                    button.configuration = config
                } else {
                    button.setTitle(label, for: .normal)
                }
                button.titleLabel?.font = .preferredFont(forTextStyle: .body)
                button.titleLabel?.adjustsFontForContentSizeCategory = true
                button.titleLabel?.numberOfLines = 0
                button.titleLabel?.textAlignment = .center
                button.accessibilityLabel = label
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 106).isActive = true
                button.addTarget(self, action: #selector(tapTile(_:)), for: .touchUpInside)
                row.addArrangedSubview(button)
            }
            if columns == 2 && row.arrangedSubviews.count == 1 { row.addArrangedSubview(UIView()) }
            stack.addArrangedSubview(row)
        }
    }
    @objc private func tapTile(_ sender: UIButton) {
        guard choices.indices.contains(sender.tag) else { return }
        choose(choices[sender.tag]["value"])
    }
    @objc private func closePicker() { choose(nil) }
    private func choose(_ value: String?) {
        guard !chosen else { return }
        chosen = true
        onChoice?(value); onChoice = nil
    }
}

final class GoldgramPluginNetwork: NSObject, UIDocumentPickerDelegate {
    private let config: GoldgramAIConfig
    private weak var presenter: UIViewController?
    private let valid: () -> Bool
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private weak var alert: UIAlertController?
    private var cancelled = false
    private var busy = false
    var isBusy: Bool { busy }
    private var count = 0
    private weak var fileUI: UIViewController?
    private var fileReply: (([String: Any]) -> Void)?
    private var exportDirectory: URL?
    private let skipRequestConfirmation: () -> Bool
    private let streamingOptions: () -> GoldgramStreamOptions
    private var streamID: UUID?
    private var streamState: GoldgramSSEParser?
    private var streamReply: (([String: Any]) -> Void)?
    private var streamPanel: GoldgramStreamPanel?
    private var streamGuard: (() -> Bool)?
    private var activeOptions = GoldgramStreamOptions()
    private var usageStart: (timestamp: Double, uptime: TimeInterval)?
    private func beginUsage() {
        usageStart = (Date().timeIntervalSince1970, ProcessInfo.processInfo.systemUptime)
    }
    @discardableResult private func endUsage(_ outcome: String, status: Int? = nil, model: String? = nil, tokens: [String: Int] = [:]) -> Int? {
        guard let start = usageStart else { return nil }
        usageStart = nil
        let duration = GoldgramAIUsagePolicy.elapsed(start.uptime, now: ProcessInfo.processInfo.systemUptime)
        let safeModel = model.flatMap { GoldgramNetworkPolicy.modelID($0) ? $0 : nil }
        config.recordUsage(GoldgramAIUsageRecord(timestamp: start.timestamp, durationMs: duration, outcome: outcome, model: safeModel, httpStatus: status, tokens: tokens))
        return duration
    }
    func usageReport() -> [String: Any] { config.usageReport() }
    init(config: GoldgramAIConfig, presenter: UIViewController, valid: @escaping () -> Bool, skipRequestConfirmation: @escaping () -> Bool = { false }, streamingOptions: @escaping () -> GoldgramStreamOptions = { GoldgramStreamOptions() }) { self.config = config; self.presenter = presenter; self.valid = valid; self.skipRequestConfirmation = skipRequestConfirmation; self.streamingOptions = streamingOptions; super.init() }
    func cancel() {
        _ = endUsage("cancelled")
        cancelled = true; streamID = nil; streamReply = nil; streamGuard = nil; streamState = nil; streamPanel?.removeFromSuperview(); streamPanel = nil
        task?.cancel(); session?.invalidateAndCancel(); task = nil; session = nil
        if let alert, alert.presentingViewController != nil { alert.dismiss(animated: false) }
        if let fileUI, fileUI.presentingViewController != nil { fileUI.dismiss(animated: false) }
        fileReply = nil; cleanExport()
    }
    private func cleanExport() { if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }; exportDirectory = nil }
    func pickJSON(completion: @escaping ([String: Any]) -> Void) {
        guard !cancelled, !busy, valid(), let presenter, presenter.presentedViewController == nil else { completion(["error":"Файл недоступен"]); return }
        busy = true; fileReply = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true); picker.delegate = self; picker.allowsMultipleSelection = false; picker.modalPresentationStyle = .formSheet; fileUI = picker; presenter.present(picker, animated: true)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completeFile(["value":NSNull()]) }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !cancelled, valid(), let url = urls.first else { completeFile(["error":"request_cancelled"]); return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536, let data = try? Data(contentsOf: url), data.count <= 65536, let value = try? JSONSerialization.jsonObject(with: data) else { completeFile(["error":"Некорректный JSON (лимит 64 КБ)"]); return }
        completeFile(["value":value])
    }
    private func completeFile(_ result: [String: Any]) { let reply = fileReply; fileReply = nil; busy = false; fileUI = nil; if !cancelled { reply?(result) } }
    func shareJSON(_ args: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        guard !cancelled, !busy, valid(), let presenter, presenter.presentedViewController == nil, let name = args["name"] as? String, name.count <= 100, name.hasSuffix(".json"), !name.contains("/"), !name.contains("\\"), let raw = args["body"] as? String, raw.utf8.count <= 65536, (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) != nil else { completion(["error":"Invalid JSON export"]); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil); exportDirectory = directory; let url = directory.appendingPathComponent(name); try Data(raw.utf8).write(to: url, options: .atomic)
            busy = true; let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil); activity.popoverPresentationController?.sourceView = presenter.view; activity.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1); fileUI = activity
            activity.completionWithItemsHandler = { [weak self] _, completed, _, _ in DispatchQueue.main.async { guard let self else { return }; self.busy = false; self.fileUI = nil; self.cleanExport(); if !self.cancelled { completion(["value":completed]) } } }; presenter.present(activity, animated: true)
        } catch { cleanExport(); completion(["error":"Не удалось экспортировать JSON"]) }
    }
    func select(_ args: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        guard !cancelled, !busy, valid(), let title = args["title"] as? String, let choices = args["choices"] as? [[String: String]], !choices.isEmpty, choices.count <= 24 else { completion(["error":"Invalid selection"]); return }
        busy = true
        DispatchQueue.main.asyncAfter(deadline: .now()+0.35) { [weak self] in
            guard let self, !self.cancelled, self.valid(), let presenter = self.presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { self?.busy = false; completion(["error":"request_cancelled"]); return }
            let detailed = args["layout"] as? String == "results"
            if args["layout"] as? String == "tiles" || detailed {
                guard !detailed || choices.count <= 3 else { self.busy = false; completion(["error":"Too many results"]); return }
                var seen = Set<String>()
                guard choices.allSatisfy({ item in
                    guard let value = item["value"], !value.isEmpty, value.utf8.count <= 200,
                          let label = item["title"], !label.isEmpty, label.utf8.count <= (detailed ? 4000 : 320),
                          seen.insert(value).inserted else { return false }
                    return (item["icon"]?.utf8.count ?? 0) <= 60
                }) else { self.busy = false; completion(["error":"Invalid tiles"]); return }
                let screen = GoldgramPluginTilePicker(title: String(title.prefix(80)), choices: choices, detailed: detailed)
                let nav = UINavigationController(rootViewController: screen)
                nav.modalPresentationStyle = .formSheet
                nav.isModalInPresentation = true
                self.fileUI = nav
                screen.onChoice = { [weak self, weak nav] value in
                    guard let self, let nav, !self.cancelled else { return }
                    nav.dismiss(animated: true) { [weak self] in
                        guard let self, !self.cancelled else { return }
                        self.fileUI = nil; self.busy = false
                        guard self.valid() else { completion(["error":"request_cancelled"]); return }
                        completion(["value": value.map { $0 as Any } ?? NSNull()])
                    }
                }
                presenter.present(nav, animated: true)
                return
            }
            let alert = UIAlertController(title: String(title.prefix(160)), message: nil, preferredStyle: .alert); self.alert = alert
            for item in choices { guard let value = item["value"], let label = item["title"], value.count <= 200 else { continue }; alert.addAction(UIAlertAction(title: String(label.prefix(160)), style: .default) { [weak self] _ in self?.busy = false; self?.alert = nil; completion(["value":value]) }) }
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in self?.busy = false; self?.alert = nil; completion(["value":NSNull()]) }); presenter.present(alert, animated: true)
        }
    }
    // User stop is distinct from lifecycle cancellation: partial results are
    // allowed only by explicit preference and while the original context is valid.
    @discardableResult func stopStream() -> Bool {
        guard let id = streamID else { return false }
        let partial = activeOptions.partial && !(streamState?.text.isEmpty ?? true)
        finishStream(id, value: partial ? streamState : nil, error: "request_cancelled", partial: partial)
        return true
    }
    private func finishStream(_ id: UUID, value: GoldgramSSEParser?, error: String?, partial: Bool = false) {
        guard streamID == id else { return }
        let allowed = !cancelled && (streamGuard?() == true)
        let reply = streamReply
        streamID = nil; streamReply = nil; streamGuard = nil; streamState = nil; busy = false
        streamPanel?.removeFromSuperview(); streamPanel = nil
        task?.cancel(); session?.invalidateAndCancel(); task = nil; session = nil
        guard allowed else { endUsage("cancelled"); reply?(["error":"request_cancelled"]); return }
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value.response(partial: partial)), let body = String(data: data, encoding: .utf8) else {
            endUsage(error == "request_cancelled" ? "cancelled" : "failed")
            reply?(["error":error ?? "Invalid stream"]); return
        }
        if activeOptions.usage, !partial {
            if value.usage.isEmpty { config.clearStreamUsage() } else { config.saveStreamUsage(value.usage) }
        }
        let duration = endUsage(partial ? "partial" : "completed", status: partial ? nil : 200, model: value.model, tokens: partial ? [:] : value.usage)
        var response: [String: Any] = ["status":200,"body":body]
        if let duration { response["durationMs"] = duration }
        reply?(response)
    }
    private func startStream(_ request: URLRequest, config sessionConfig: URLSessionConfiguration, options: GoldgramStreamOptions, key: String, progress: @escaping ([String: Any]) -> Void, completion: @escaping ([String: Any]) -> Void) {
        guard !cancelled, valid(), streamingOptions() == options, self.config.readKey() == key, let presenter, let host = presenter.viewIfLoaded, host.window != nil else { busy = false; completion(["error":"request_cancelled"]); return }
        if (options.preview || options.reasoning), host.viewWithTag(GoldgramStreamPanel.marker) != nil { busy = false; completion(["error":"Закройте другой потоковый ответ или отключите его показ."]); return }
        let id = UUID(); streamID = id; streamReply = completion; streamState = GoldgramSSEParser(); activeOptions = options
        streamGuard = { [weak self] in
            guard let self else { return false }
            return self.valid() && self.streamingOptions() == options && self.config.readKey() == key && UIApplication.shared.applicationState == .active
        }
        if options.preview || options.reasoning {
            streamPanel = GoldgramStreamPanel(host: host, options: options, stop: { [weak self] in _ = self?.stopStream() })
        }
        let transport = GoldgramSSETransport(update: { [weak self] value in
            guard let self, self.streamID == id else { return }
            guard self.streamGuard?() == true else { self.finishStream(id, value: nil, error: "request_cancelled"); return }
            self.streamState = value
            self.streamPanel?.display(value, options: options)
            var event: [String: Any] = ["text":value.text, "thinking":options.reasoning && value.thinking, "done":false]
            if options.usage { event["usage"] = value.usage }
            progress(event)
        }, result: { [weak self] value, error in
            guard let self, self.streamID == id else { return }
            if let value, self.streamGuard?() == true {
                var event: [String: Any] = ["text":value.text, "thinking":false, "done":true]
                if options.usage { event["usage"] = value.usage }
                progress(event)
            }
            self.finishStream(id, value: value, error: error)
        })
        let session = URLSession(configuration: sessionConfig, delegate: transport, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request); self.task = task; beginUsage(); task.resume()
    }
    func fetch(_ args: [String: Any], allowBalance: Bool = false, progress: @escaping ([String: Any]) -> Void = { _ in }, completion: @escaping ([String: Any]) -> Void) {
        let raw = args["body"]
        let hasBody = raw != nil && !(raw is NSNull)
        guard !cancelled, !busy, valid(), count < 3, let key = config.readKey(),
              let route = GoldgramNetworkPolicy.route(url: args["url"] as? String, method: args["method"] as? String, hasBody: hasBody, allowBalance: allowBalance) else {
            completion(["error":"Нет ключа, разрешения или поддерживаемого адреса/метода."]); return
        }
        let options = streamingOptions()
        let streaming = route == .completion && options.enabled
        let url: URL
        let method: String
        var payload: Data? = nil
        let title: String
        let message: String
        switch route {
        case .models:
            url = URL(string: "https://api.deepseek.com/models")!
            method = "GET"; title = "Обновить каталог DeepSeek?"
            message = "Запрос списка моделей. Переписка, промпты и файлы не передаются."
        case .balance:
            url = URL(string: "https://api.deepseek.com/user/balance")!
            method = "GET"; title = "Проверить баланс DeepSeek?"
            message = "Только запрос баланса аккаунта по ключу этого плагина. Переписка и файлы не передаются."
        case .completion:
            guard let raw = raw as? String, raw.utf8.count <= 48000,
                  let body = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let model = body["model"] as? String, GoldgramNetworkPolicy.modelID(model),
                  let messages = body["messages"] as? [[String: Any]], messages.count == 2,
                  messages[0]["role"] as? String == "system", messages[1]["role"] as? String == "user",
                  let prompt = messages[0]["content"] as? String, let text = messages[1]["content"] as? String,
                  prompt.utf8.count <= 16000, text.utf8.count <= 28000 else { completion(["error":"Некорректный запрос к DeepSeek."]); return }
            var clean: [String: Any] = ["model":model,"messages":[["role":"system","content":prompt],["role":"user","content":text]],"stream":streaming,"max_tokens":max(1,min(2048,body["max_tokens"] as? Int ?? 900))]
            if streaming { clean["stream_options"] = ["include_usage":true] }
            if let t = body["temperature"] as? Double, t.isFinite { clean["temperature"] = max(0,min(2,t)) }
            if let t = body["thinking"] as? [String: Any], let type = t["type"] as? String, ["enabled","disabled"].contains(type) { clean["thinking"] = ["type":type] }
            if let effort = body["reasoning_effort"] as? String, ["low","high","max"].contains(effort) { clean["reasoning_effort"] = effort }
            guard let data = try? JSONSerialization.data(withJSONObject: clean) else { completion(["error":"Invalid request"]); return }
            url = URL(string:"https://api.deepseek.com/chat/completions")!
            method = "POST"; payload = data; title = "Передать данные плагина в DeepSeek?"
            message = "Модель: "+model+"\n\nПромпт:\n"+prompt+"\n\nТекст:\n"+text
        }
        let ms = max(1000,min(route != .completion ? 30000 : 240000,args["timeoutMs"] as? Int ?? (route != .completion ? 15000 : 75000)))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Double(ms)/1000)
        request.httpMethod = method; request.httpBody = payload
        request.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if payload != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        busy = true; count += 1
        DispatchQueue.main.asyncAfter(deadline: .now()+0.35) { [weak self] in
            guard let self, !self.cancelled, self.valid(), let presenter = self.presenter, presenter.viewIfLoaded?.window != nil else { self?.busy = false; completion(["error":"Запрос отменён"]); return }
            let send: () -> Void = { [weak self] in
                guard let self, !self.cancelled, self.valid(), self.config.readKey() == key else { self?.busy = false; completion(["error":"request_cancelled"]); return }
                self.alert = nil
                if route == .completion && self.config.financeBudgetReached() {
                    self.busy = false
                    completion(["error":"Локальный лимит расчётных расходов достигнут. Измените его в финансовом центре."]); return
                }
                let cfg = URLSessionConfiguration.ephemeral
                cfg.httpShouldSetCookies = false; cfg.httpCookieStorage = nil; cfg.urlCache = nil; cfg.urlCredentialStorage = nil
                cfg.timeoutIntervalForRequest = Double(ms)/1000; cfg.timeoutIntervalForResource = Double(ms)/1000
                if streaming {
                    self.startStream(request, config: cfg, options: options, key: key, progress: progress, completion: completion); return
                }
                let session = URLSession(configuration: cfg, delegate: GoldgramAINoRedirect(), delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request) { [weak self] data, response, error in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.cancelled else { return }
                        self.busy = false; self.task = nil; self.session?.finishTasksAndInvalidate(); self.session = nil
                        guard self.valid(), self.config.readKey() == key else { self.endUsage("cancelled"); completion(["error":"request_cancelled"]); return }
                        guard error == nil, let http = response as? HTTPURLResponse, let data, data.count <= 512*1024 else { self.endUsage("failed"); completion(["error":"Network error or invalid response"]); return }
                        if route == .balance {
                            guard http.statusCode == 200 else { completion(["error":"Balance HTTP \(http.statusCode)"]); return }
                            guard var balance = GoldgramAIUsagePolicy.balance(data) else { completion(["error":"Invalid balance response"]); return }
                            balance["updatedAt"] = Date().timeIntervalSince1970
                            completion(["value":balance, "status":200]); return
                        }
                        if route == .models {
                            guard http.statusCode == 200 else { completion(["status":http.statusCode,"body":"{\"error\":\"Model discovery failed\"}"]); return }
                            guard let models = GoldgramNetworkPolicy.catalog(data),
                                  let json = try? JSONSerialization.data(withJSONObject: ["object":"list","data":models]), let body = String(data: json, encoding: .utf8) else { completion(["error":"Некорректный список моделей."]); return }
                            self.config.saveCatalog(models)
                            completion(["status":200,"body":body]); return
                        }
                        guard let text = String(data: data, encoding: .utf8) else { self.endUsage("failed", status: http.statusCode); completion(["error":"Invalid response"]); return }
                        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        let success = http.statusCode == 200 && (root?["choices"] as? [[String: Any]])?.isEmpty == false
                        let duration = self.endUsage(success ? "completed" : "failed", status: http.statusCode, model: success ? root?["model"] as? String : nil, tokens: success ? GoldgramAIUsagePolicy.tokens(root?["usage"]) : [:])
                        var response: [String: Any] = ["status":http.statusCode,"body":text]
                        if let duration { response["durationMs"] = duration }
                        completion(response)
                    }
                }
                self.task = task
                if route == .completion { self.beginUsage() }
                task.resume()
            }
            if route != .balance {
                if self.skipRequestConfirmation() { send(); return }
            }
            guard presenter.presentedViewController == nil else { self.busy = false; completion(["error":"Закройте открытое окно и повторите запрос."]); return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            self.alert = alert
            alert.addAction(UIAlertAction(title: "Отправить запрос", style: .default) { _ in send() })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in self?.busy = false; completion(["error":"request_cancelled"]) })
            presenter.present(alert, animated: true)
        }
    }
}

// Native financial center. No background requests or credentials in reports.
final class GoldgramFinanceScreen: UITableViewController {
    private let config: GoldgramAIConfig
    private let valid: () -> Bool
    private let canBalance: Bool
    private let canUsage: Bool
    private let acquire: () -> String?
    private let release: (String) -> Void
    private let startAtUsage: Bool
    private var opened = false
    private var broker: GoldgramPluginNetwork?
    private var lease: String?
    private var balance: [String: Any]?
    private var status = "Обновите баланс вручную."
    private var period = 1
    private var ledger = GoldgramFinanceLedger()
    private var selectedDays: [Int: [String: GoldgramFinanceTotals]] = [:]
    private var totals = GoldgramFinanceTotals()
    private var models: [(String, GoldgramFinanceTotals)] = []
    private let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.96, green: 0.79, blue: 0.40, alpha: 1) : UIColor(red: 0.48, green: 0.33, blue: 0.06, alpha: 1)
    }
    init(config: GoldgramAIConfig, valid: @escaping () -> Bool, canBalance: Bool, canUsage: Bool, startAtUsage: Bool, acquire: @escaping () -> String?, release: @escaping (String) -> Void) {
        self.config = config; self.valid = valid; self.canBalance = canBalance; self.canUsage = canUsage
        self.startAtUsage = startAtUsage; self.acquire = acquire; self.release = release
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "DeepSeek · Финансы"
        tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 64
        NotificationCenter.default.addObserver(self, selector: #selector(stop), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
        broker?.cancel()
        if let lease { release(lease) }
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reload() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !opened {
            opened = true
            if startAtUsage && valid() && canUsage { tableView.scrollToRow(at: IndexPath(row: 0, section: 1), at: .top, animated: false) }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.topViewController !== self || isBeingDismissed { stop() }
    }
    @objc private func stop() {
        broker?.cancel(); broker = nil
        if let lease { release(lease); self.lease = nil }
        balance = nil; status = "Обновите баланс вручную."; reload()
    }
    private func reload() {
        if valid() && canUsage {
            ledger = config.financeLedger(); selectedDays = ledger.selected(period)
            totals = GoldgramFinanceLedger.totals(selectedDays)
            models = GoldgramFinanceLedger.groups.compactMap { group in
                var sum = GoldgramFinanceTotals()
                for day in selectedDays.values { if let value = day[group] { sum.merge(value) } }
                return sum.requests > 0 ? (group, sum) : nil
            }
        } else { ledger = GoldgramFinanceLedger(); selectedDays = [:]; totals = GoldgramFinanceTotals(); models = [] }
        if !valid() { balance = nil }
        tableView.reloadData()
    }
    private func usd(_ value: Decimal) -> String {
        let f = NumberFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal
        f.minimumFractionDigits = 2; f.maximumFractionDigits = 8; f.usesGroupingSeparator = false
        return "$" + (f.string(from: NSDecimalNumber(decimal: value)) ?? "—")
    }
    private func cost(_ value: GoldgramFinanceTotals) -> String {
        guard value.priced > 0 else { return "Нет данных" }
        return value.low == value.high ? usd(value.low) : usd(value.low) + " – " + usd(value.high)
    }
    private func known(_ key: String) -> String { totals.tokens[key].map { String($0) } ?? "—" }
    override func numberOfSections(in tableView: UITableView) -> Int { 6 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard valid() else { return section == 0 ? 1 : 0 }
        switch section {
        case 0: return canBalance ? 2 : 1
        case 1: return canUsage ? 6 : 0
        case 2: return canUsage ? 1 : 0
        case 3: return canUsage ? models.count : 0
        case 4: return canUsage ? 2 : 0
        default: return (canUsage ? 1 : 0) + (canBalance ? 2 : 0)
        }
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard self.tableView(tableView, numberOfRowsInSection: section) > 0 else { return nil }
        return ["Баланс DeepSeek", "Использование", "Запросы по дням", "По моделям", "История", "Лимиты и предупреждения"][section]
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard valid(), self.tableView(tableView, numberOfRowsInSection: section) > 0 else { return nil }
        switch section {
        case 0: return status + "\nБаланс всего аккаунта по этому ключу; не равен расходам только этого плагина."
        case 1: return "Статистика этого плагина, периоды UTC. До 366 дней агрегатов, последние 128 запросов подробно. Расходы в USD — оценка по опубликованным тарифам от 28.11.2026, только новые запросы с полными токенами. Пиковые интервалы показаны диапазоном; не выписка. Снимок тарифов применяется к запросам в течение 30 дней, затем стоимость новых запросов неизвестна."
        case 2: return period == 3 ? "Последние 30 дней из выбранной истории, количество запросов." : "Количество запросов за выбранный период (UTC)."
        case 4: return "Без промптов, переписки, ключей и идентификаторов чатов. Неучтённые или незавершённые запросы могут быть тарифицированы."
        case 5: return "Лимит USD добровольный: блокирует следующий запрос только при достижении верхней оценки уже учтённых расходов текущего месяца UTC. Не учитывает внешние расходы и неизвестные списания, не прерывает запросы. Предупреждения о балансе действуют после ручного обновления."
        default: return nil
        }
    }
    private func chartCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let day = GoldgramFinancePricing.day(Date().timeIntervalSince1970) ?? 0
        var count = period == 0 ? 1 : period == 1 ? 7 : 30
        if period == 2 {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            count = calendar.component(.day, from: Date())
        }
        let values = (0..<count).map { offset -> Int64 in
            let key = day - count + 1 + offset
            return selectedDays[key]?.values.reduce(Int64(0)) { GoldgramFinanceTotals.add($0, $1.requests) } ?? 0
        }
        let chart = UIStackView(); chart.axis = .horizontal; chart.distribution = .fillEqually; chart.spacing = 2
        chart.translatesAutoresizingMaskIntoConstraints = false
        let maximum = max(Int64(1), values.max() ?? 0)
        for value in values {
            let column = UIView()
            let bar = UIView(); bar.backgroundColor = value == 0 ? .tertiarySystemFill : accent
            bar.layer.cornerRadius = 2; bar.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(bar)
            NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: column.leadingAnchor), bar.trailingAnchor.constraint(equalTo: column.trailingAnchor), bar.bottomAnchor.constraint(equalTo: column.bottomAnchor), bar.heightAnchor.constraint(equalToConstant: max(1, CGFloat(value) / CGFloat(maximum) * 86))])
            chart.addArrangedSubview(column)
        }
        cell.contentView.addSubview(chart)
        NSLayoutConstraint.activate([chart.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),chart.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),chart.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),chart.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),chart.heightAnchor.constraint(equalToConstant: 90)])
        chart.isAccessibilityElement = true; chart.accessibilityLabel = "Запросы по дням: " + values.map { String($0) }.joined(separator: ", ")
        return cell
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        cell.selectionStyle = .none
        guard valid() else { cell.textLabel?.text = "Плагин или аккаунт недоступен."; return cell }
        switch indexPath.section {
        case 0:
            if !canBalance { cell.textLabel?.text = "Требуется разрешение gold.ai.balance."; return cell }
            if indexPath.row == 0 {
                let rows = balance?["balance_infos"] as? [[String: String]] ?? []
                cell.textLabel?.font = .preferredFont(forTextStyle: .title2); cell.textLabel?.textColor = accent
                cell.textLabel?.text = rows.isEmpty ? "Баланс не обновлён" : rows.map { ($0["currency"] ?? "") + " " + ($0["total_balance"] ?? "—") }.joined(separator: "\n")
                var details = rows.map { row -> String in
                    let currency = row["currency"] ?? ""
                    var text = currency + ": пополнено " + (row["topped_up_balance"] ?? "—") + " · бонус " + (row["granted_balance"] ?? "—")
                    if let raw = row["total_balance"], let amount = Decimal(string: raw, locale: Locale(identifier:"en_US_POSIX")), let low = config.financeThreshold("low" + currency), amount <= low { text += "\n⚠ Низкий баланс" }
                    return text
                }
                if let available = balance?["is_available"] as? Bool { details.append(available ? "API доступен" : "⚠ API недоступен") }
                if let time = balance?["updatedAt"] as? Double { details.append("Обновлено: " + DateFormatter.localizedString(from: Date(timeIntervalSince1970: time), dateStyle: .short, timeStyle: .short)) }
                cell.detailTextLabel?.text = details.joined(separator: "\n")
            } else {
                cell.textLabel?.text = broker == nil ? "Обновить баланс" : "Отменить обновление"
                cell.textLabel?.textColor = accent; cell.selectionStyle = .default; cell.accessoryType = .disclosureIndicator
            }
        case 1:
            if indexPath.row == 0 {
                let control = UISegmentedControl(items: ["День","Неделя","Месяц","Всё"])
                control.selectedSegmentIndex = period; control.translatesAutoresizingMaskIntoConstraints = false
                cell.contentView.addSubview(control)
                NSLayoutConstraint.activate([control.leadingAnchor.constraint(equalTo:cell.contentView.leadingAnchor,constant:12),control.trailingAnchor.constraint(equalTo:cell.contentView.trailingAnchor,constant:-12),control.topAnchor.constraint(equalTo:cell.contentView.topAnchor,constant:10),control.bottomAnchor.constraint(equalTo:cell.contentView.bottomAnchor,constant:-10)])
                control.addTarget(self, action: #selector(changePeriod(_:)), for: .valueChanged)
                return cell
            }
            switch indexPath.row {
            case 1:
                cell.textLabel?.text = "Расчётные расходы: " + cost(totals)
                cell.textLabel?.font = .preferredFont(forTextStyle: .headline); cell.textLabel?.textColor = accent
                cell.detailTextLabel?.text = "Оценено \(totals.priced) из \(totals.requests) запросов. Без оценки: \(max(0,totals.requests-totals.priced))."
            case 2:
                cell.textLabel?.text = "Запросы: \(totals.requests)"
                cell.detailTextLabel?.text = "Завершено: \(totals.completed) · другие исходы: \(max(0,totals.requests-totals.completed)) · с токенами: \(totals.known)"
            case 3:
                cell.textLabel?.text = "Токены: " + known("total_tokens")
                cell.detailTextLabel?.text = "Вход: " + known("prompt_tokens") + " · Выход: " + known("completion_tokens")
            case 4:
                cell.textLabel?.text = "Кэш и мышление"
                cell.detailTextLabel?.text = "Cache hit: " + known("prompt_cache_hit_tokens") + " · miss: " + known("prompt_cache_miss_tokens") + "\nReasoning: " + known("reasoning_tokens") + " (в составе выходных)"
            default:
                cell.textLabel?.text = "Среднее время"
                cell.detailTextLabel?.text = totals.requests > 0 ? String(format: "%.2f сек.", Double(totals.milliseconds) / Double(totals.requests) / 1000) : "Нет данных"
            }
        case 2: return chartCell()
        case 3:
            guard models.indices.contains(indexPath.row) else { return cell }
            let (name, value) = models[indexPath.row]
            cell.textLabel?.text = name + " · " + String(value.requests) + " запросов"
            cell.detailTextLabel?.text = "Известные токены: " + (value.tokens["total_tokens"].map { String($0) } ?? "—") + " · оценка: " + cost(value)
        case 4:
            cell.textLabel?.text = indexPath.row == 0 ? "Последние запросы (\(ledger.recent.count))" : "Очистить локальную статистику"
            if indexPath.row == 1 { cell.textLabel?.textColor = .systemRed }
            cell.accessoryType = .disclosureIndicator; cell.selectionStyle = .default
        default:
            let names = thresholdNames()
            guard names.indices.contains(indexPath.row) else { return cell }
            let name = names[indexPath.row]
            cell.textLabel?.text = name == "budgetUSD" ? "Локальный лимит в месяц (USD)" : "Низкий баланс (" + String(name.suffix(3)) + ")"
            cell.detailTextLabel?.text = config.financeThreshold(name).map { NSDecimalNumber(decimal: $0).stringValue } ?? "Выключен"
            if name == "budgetUSD" && config.financeBudgetReached() { cell.detailTextLabel?.text = (cell.detailTextLabel?.text ?? "") + " · достигнут" }
            cell.accessoryType = .disclosureIndicator; cell.selectionStyle = .default
        }
        return cell
    }
    @objc private func changePeriod(_ sender: UISegmentedControl) { guard valid(), canUsage else { return }; period = sender.selectedSegmentIndex; reload() }
    private func thresholdNames() -> [String] { (canUsage ? ["budgetUSD"] : []) + (canBalance ? ["lowUSD","lowCNY"] : []) }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true)
        guard valid() else { stop(); return }
        if indexPath.section == 0, indexPath.row == 1, canBalance {
            if broker != nil { stop() } else { refreshBalance() }; return
        }
        guard broker == nil else { return }
        if indexPath.section == 4, canUsage {
            if indexPath.row == 0 {
                navigationController?.pushViewController(GoldgramFinanceHistoryScreen(records: Array(ledger.recent.reversed()), valid: valid), animated: true)
            } else {
                let alert = UIAlertController(title:"Очистить статистику?",message:"Будут удалены локальные агрегаты и журнал этого плагина. Баланс и настройки лимита не изменятся; расчёт лимита начнётся заново.",preferredStyle:.alert)
                alert.addAction(UIAlertAction(title:"Очистить",style:.destructive) { [weak self] _ in
                    guard let self, self.valid(), let lease = self.acquire() else { return }
                    defer { self.release(lease) }
                    self.config.clearUsageLedger(); self.reload()
                })
                alert.addAction(UIAlertAction(title:"Отмена",style:.cancel)); present(alert,animated:true)
            }
        }
        if indexPath.section == 5 {
            let names = thresholdNames()
            if names.indices.contains(indexPath.row) { editThreshold(names[indexPath.row]) }
        }
    }
    private func editThreshold(_ name: String) {
        let alert = UIAlertController(title: name == "budgetUSD" ? "Месячный лимит USD" : "Предупреждение: " + String(name.suffix(3)),message:"Положительное число. Пустое поле выключает. Значение относится только к этому плагину.",preferredStyle:.alert)
        alert.addTextField { field in
            field.keyboardType = .decimalPad
            field.text = self.config.financeThreshold(name).map { NSDecimalNumber(decimal: $0).stringValue }
        }
        alert.addAction(UIAlertAction(title:"Сохранить",style:.default) { [weak self, weak alert] _ in
            guard let self, self.valid(), let text = alert?.textFields?.first?.text?.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:",",with:".") else { return }
            let value = GoldgramFinancePricing.positive(text)
            guard text.isEmpty || value != nil else { self.status = "Некорректное значение; лимит не изменён."; self.reload(); return }
            self.config.setFinanceThreshold(name,value:value); self.reload()
        })
        alert.addAction(UIAlertAction(title:"Отмена",style:.cancel)); present(alert,animated:true)
    }
    private func refreshBalance() {
        guard canBalance, valid(), broker == nil else { return }
        guard config.readKey() != nil else { status = "Сначала сохраните ключ в настройках модели."; reload(); return }
        guard let lease = acquire() else { status = "Плагин занят. Повторите позже."; reload(); return }
        self.lease = lease; status = "Обновление…"; reload()
        let network = GoldgramPluginNetwork(config:config,presenter:self,valid:{ [weak self] in
            guard let self else { return false }
            return self.valid() && self.viewIfLoaded?.window != nil && UIApplication.shared.applicationState == .active
        })
        broker = network
        network.fetch(["url":"https://api.deepseek.com/user/balance","method":"GET"],allowBalance:true) { [weak self, weak network] result in
            guard let self, let network, self.broker === network else { return }
            self.broker = nil
            if let lease = self.lease { self.release(lease); self.lease = nil }
            guard self.valid() else { self.stop(); return }
            if let value = result["value"] as? [String: Any], result["status"] as? Int == 200 {
                self.balance = value; self.status = "Баланс получен от DeepSeek."
            } else { self.status = "Не удалось обновить или запрос отменён. Предыдущие данные могут быть устаревшими." }
            self.reload()
        }
    }
}
private final class GoldgramFinanceHistoryScreen: UITableViewController {
    private let records: [GoldgramAIUsageRecord]
    private let valid: () -> Bool
    init(records: [GoldgramAIUsageRecord], valid: @escaping () -> Bool) {
        self.records = records; self.valid = valid; super.init(style:.insetGrouped)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() { super.viewDidLoad(); title = "История запросов" }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); tableView.reloadData() }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { valid() ? records.count : 0 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style:.subtitle,reuseIdentifier:nil); cell.selectionStyle = .none
        guard valid(), records.indices.contains(indexPath.row) else { return cell }
        let record = records[indexPath.row]
        cell.textLabel?.text = DateFormatter.localizedString(from: Date(timeIntervalSince1970:record.timestamp),dateStyle:.short,timeStyle:.short)
        let outcome = ["completed":"Завершён","failed":"Ошибка","cancelled":"Отменён","partial":"Частичный"][record.outcome] ?? "Неизвестно"
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = (record.model ?? "Модель неизвестна") + " · " + outcome + " · \(record.durationMs) ms\nТокены: " + (record.tokens["total_tokens"].map { String($0) } ?? "нет данных") + (record.httpStatus.map { " · HTTP \($0)" } ?? "")
        return cell
    }
}

// Native model picker/catalog. A user opening the screen authorizes only a
// metadata GET; the broker still checks account, plugin grants and key.
final class GoldgramModelCatalogScreen: UITableViewController {
    private let config: GoldgramAIConfig
    private let valid: () -> Bool
    private let fallback: [[String: String]]
    private let selected: String?
    private let choose: ((String) -> Void)?
    private var broker: GoldgramPluginNetwork?
    private var status = ""
    private var opened = false
    private var models: [[String: Any]] = []
    private var updatedAt: Double?
    init(config: GoldgramAIConfig, valid: @escaping () -> Bool, fallback: [[String: String]] = [], selected: String? = nil, choose: ((String) -> Void)? = nil) {
        self.config = config; self.valid = valid; self.fallback = fallback; self.selected = selected; self.choose = choose
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Модели DeepSeek"; reloadCatalog()
        NotificationCenter.default.addObserver(self, selector: #selector(stop), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !opened else { return }; opened = true
        if let cache = config.modelCatalog, GoldgramNetworkPolicy.fresh(updated: cache.updated, now: Date().timeIntervalSince1970) { return }
        refresh()
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); stop() }
    @objc private func stop() { broker?.cancel(); broker = nil; status = ""; reloadCatalog(); tableView.reloadData() }
    private func reloadCatalog() {
        updatedAt = nil; models = []
        guard valid() else { return }
        if let cache = config.modelCatalog { models = cache.models; updatedAt = cache.updated; return }
        models = fallback.compactMap { item in
            guard let value = item["value"], GoldgramNetworkPolicy.modelID(value) else { return nil }
            return ["id":value,"name":item["title"] ?? value]
        }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : models.count + (choose == nil ? 0 : 1) }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Каталог" : (updatedAt == nil ? "Резервные варианты (не проверены API)" : "Модели из API") }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return nil }
        let date = updatedAt.map { DateFormatter.localizedString(from: Date(timeIntervalSince1970: $0), dateStyle: .short, timeStyle: .short) }
        return ([status, date.map { "Последнее успешное обновление: " + $0 } ?? "Нет подтверждённого списка.", "Обновление при открытии устаревшего каталога (24 ч) или вручную. Только метаданные; без отправки переписки."] .filter { !$0.isEmpty }).joined(separator: "\n")
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0 { cell.textLabel?.text = broker == nil ? "Обновить список моделей" : "Отменить обновление"; cell.accessoryType = .disclosureIndicator; return cell }
        let rows = models
        if indexPath.row >= rows.count { cell.textLabel?.text = "Ввести ID вручную"; cell.accessoryType = .disclosureIndicator; return cell }
        let row = rows[indexPath.row], id = row["id"] as? String ?? ""
        cell.textLabel?.text = row["name"] as? String ?? id
        var details = [id]
        if let window = row["context_window"] as? Int { details.append("Контекст: "+String(window)) }
        if let modalities = row["input_modalities"] as? [String] { details.append(modalities.joined(separator: ", ")) }
        cell.detailTextLabel?.text = details.joined(separator: " · "); cell.detailTextLabel?.numberOfLines = 0
        if id == selected { cell.accessoryType = .checkmark }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard valid() else { stop(); return }
        if indexPath.section == 0 { if broker != nil { stop() } else { refresh() }; return }
        guard let choose else { return }
        let rows = models
        if indexPath.row < rows.count, let id = rows[indexPath.row]["id"] as? String { choose(id); navigationController?.popViewController(animated: true); return }
        let alert = UIAlertController(title:"ID модели",message:"Будет использован указанный ID; доступность не проверяется автоматически.",preferredStyle:.alert)
        alert.addTextField { $0.text = self.selected; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title:"Выбрать",style:.default) { [weak self, weak alert] _ in
            guard let self, self.valid(), let id = alert?.textFields?.first?.text?.trimmingCharacters(in:.whitespacesAndNewlines), GoldgramNetworkPolicy.modelID(id) else { return }
            choose(id); self.navigationController?.popViewController(animated:true)
        })
        alert.addAction(UIAlertAction(title:"Отмена",style:.cancel)); present(alert,animated:true)
    }
    private func refresh() {
        guard broker == nil, valid() else { return }
        guard config.readKey() != nil else { status = "Сначала задайте API-ключ в настройках этого плагина."; tableView.reloadData(); return }
        status = "Обновление…"; tableView.reloadData()
        let network = GoldgramPluginNetwork(config: config, presenter: self, valid: { [weak self] in
            guard let self else { return false }; return self.valid() && self.viewIfLoaded?.window != nil && UIApplication.shared.applicationState == .active
        }, skipRequestConfirmation: { true })
        broker = network
        network.fetch(["url":"https://api.deepseek.com/models","method":"GET","timeoutMs":15000]) { [weak self, weak network] result in
            guard let self, let network, self.broker === network else { return }
            self.broker = nil
            self.status = result["status"] as? Int == 200 ? "Список обновлён." : (result["status"] as? Int).map { "Ошибка HTTP "+String($0)+". Сохранённый список не изменён." } ?? "Не удалось обновить. Сохранённый список не изменён."
            self.reloadCatalog(); self.tableView.reloadData()
        }
        tableView.reloadData()
    }
}
