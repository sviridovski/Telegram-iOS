// Goldgram #80: account-scoped named channel/discussion archive.
import Foundation
import UIKit
import tgapiC

// Mirror the tiny, versioned diagnostic record without linking the app-only
// archive UI into TelegramCore. Extra fields in the plist are ignored.
private struct GoldgramBackgroundRunReport: Decodable {
    let startedAt: Double
    let accountId: Int64?
    let outcome: String
    let targets: Int
    let requests: Int
    let completed: Int
    let difference: Int
    let empty: Int
    let tooLong: Int
    let unavailable: Int
    let returnedNew: Int
    let returnedEdits: Int
    let originalsQueued: Int
    // Optional fields decode #108-109 snapshots with no stage information.
    let phase: String?
    let phaseAt: Double?
    let storedPinned: Int?
    let rejectedPeer: Int?
    let rejectedLink: Int?
    let rejectedGroup: Int?
    let rejectedAccess: Int?
    // #113 optional network/RPC fields; absent in archived #108-112 samples.
    let networkStatus: String?
    let networkTransitions: Int?
    let firstOnlineAt: Double?
    let rpcAttempts: Int?
    let rpcErrors: Int?
    let lastRpcError: String?
    let rpcResponseAt: Double?
    let rpcFinal: Bool?
    let rpcPts: Int32?
    let rpcTimeout: Int32?
    // #114 optional fields; older stored BG entries still decode.
    let leaseActivatedAt: Double?
    let serviceMasterMode: String?
    let serviceMasterAt: Double?
    let serviceMasterTransitions: Int?
    let postboxMaster: Bool?
    let postboxMasterAt: Double?
    let postboxMasterTransitions: Int?
    let networkAllowed: Bool?
    let networkAllowedAt: Double?
    let networkAllowedTransitions: Int?
    let firstConnectingAt: Double?
    let rpcEnqueuedAt: Double?
    let rpcBudgetRemaining: Double?
}

@objc(GoldgramArchiveScreen)
public final class GoldgramArchiveScreen: UITableViewController {
    private let category: Int
    // nil = dialog index; non-nil = one conversation or a verified channel pair.
    private let sources: [[String: Any]]?
    private let displayName: String?
    private var boundAccount: Int64?
    private var items: [[String: Any]] = [] // raw rows: pagination offsets never use grouped count
    private var displayItems: [[String: Any]] = []
    private var hasMore = false
    private var inFlight = false
    private var generation = 0
    private var openingMessage = false
    private var status = "Загрузка истории…"
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    @objc(initWithCategory:)
    public convenience init(category: Int) {
        self.init(category: category, sources: nil, displayName: nil)
    }

    private init(category: Int, sources: [[String: Any]]?, displayName: String?) {
        self.category = category
        self.sources = sources
        self.displayName = displayName
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { return nil }

    private static let diagnosticCountPrefix = "GoldgramDiagnosticCountsV1."
    private static let diagnosticSincePrefix = "GoldgramDiagnosticSinceV1."
    private static let tracePrefix = "GoldgramDiagnosticTraceRowsV2."
    private static let traceScopePrefix = "GoldgramDiagnosticTraceScopeV2."
    private static let traceActivePrefix = "GoldgramDiagnosticTraceActiveV2."

    private static func tracePeer(_ item: [String: Any]) -> String? {
        guard let kind = (item["peerKind"] as? NSNumber)?.intValue,
              let peer = (item["peerId"] as? NSNumber)?.int64Value, peer > 0 else { return nil }
        let ns = kind == 0 ? "u" : kind == 1 ? "g" : "c"
        return "\(ns):\(peer)"
    }

    @objc private func captureDiagnosticMenu() {
        guard let account = GoldgramArchiveReader.activeAccountId()?.int64Value, account > 0 else { return }
        let defaults = UserDefaults.standard
        let sinceKey = Self.diagnosticSincePrefix + String(account)
        let running = defaults.object(forKey: sinceKey) != nil
        let menu = UIAlertController(title: "Тест захвата Goldgram",
                                     message: "Только счётчики этапов и состояние SQLite. Без текстов, имён и ID сообщений.",
                                     preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: "Начать новый тест", style: .default) { _ in
            defaults.set([String: Int](), forKey: Self.diagnosticCountPrefix + String(account))
            defaults.set([[String: Any]](), forKey: Self.tracePrefix + String(account))
            let scoped = (self.sources ?? []).compactMap(Self.tracePeer)
            defaults.set(scoped, forKey: Self.traceScopePrefix + String(account))
            defaults.set(!scoped.isEmpty, forKey: Self.traceActivePrefix + String(account))
            if !scoped.isEmpty {
                goldgramResolveNativeMetadata([
                    "action": "notification_trace_start", "accountId": NSNumber(value: account),
                    "items": self.sources ?? []
                ]) { _ in }
            }
            defaults.set(Int64(Date().timeIntervalSince1970 * 1000), forKey: sinceKey)
            defaults.set(true, forKey: "GoldgramDiagnosticEnabledV1")
            let alert = UIAlertController(title: "Диагностика включена",
                message: self.sources == nil
                    ? "Для адресной диагностики выбери обсуждение в архиве и запусти «Тест» внутри. Второй аккаунт не нужен."
                    : "Теперь наблюдаем только этот канал и его группу обсуждения. Оставайся в другом чате, дождись нового комментария и его изменения; потом удерживай запись в архиве.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Понятно", style: .default))
            self.present(alert, animated: true)
        })
        if running {
            menu.addAction(UIAlertAction(title: "Показать результат", style: .default) { _ in
                self.showCaptureDiagnosticReport(account: account,
                    since: defaults.object(forKey: sinceKey) as? NSNumber)
            })
        }
        if running {
            menu.addAction(UIAlertAction(title: "Остановить и удалить диагностику", style: .destructive) { _ in
                defaults.removeObject(forKey: sinceKey)
                defaults.removeObject(forKey: Self.diagnosticCountPrefix + String(account))
                defaults.removeObject(forKey: Self.tracePrefix + String(account))
                defaults.removeObject(forKey: Self.traceScopePrefix + String(account))
                defaults.removeObject(forKey: Self.traceActivePrefix + String(account))
                defaults.set(false, forKey: "GoldgramDiagnosticEnabledV1")
                goldgramResolveNativeMetadata([
                    "action": "notification_trace_stop", "accountId": NSNumber(value: account),
                    "items": self.sources ?? []
                ]) { _ in }
            })
        }
        // #104: explicit monitoring preference, independent of the one-off test.
        // Channel folders include a verified broadcast source when available.
        if category == 2, let source = sources?.first(where: {
            ($0["peerKind"] as? NSNumber)?.int32Value == 3
        }) {
            menu.addAction(UIAlertAction(title: "Следить за комментариями канала", style: .default) { _ in
                self.updatePriorityDiscussion(source: source, enabled: true, account: account)
            })
            menu.addAction(UIAlertAction(title: "Отключить слежение за каналом", style: .default) { _ in
                self.updatePriorityDiscussion(source: source, enabled: false, account: account)
            })
        }
        menu.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
        menu.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(menu, animated: true)
    }

    private func updatePriorityDiscussion(source: [String: Any], enabled: Bool, account: Int64) {
        guard boundAccount == account else { return }
        goldgramResolveNativeMetadata([
            "action": enabled ? "priority_discussion_add" : "priority_discussion_remove",
            "accountId": NSNumber(value: account), "items": [source]
        ]) { [weak self] response in
            guard let self else { return }
            let result = response as NSDictionary
            let status = result["status"] as? String ?? "unavailable"
            let count = (result["count"] as? NSNumber)?.intValue ?? 0
            let message: String
            switch status {
            case "enabled":
                message = "Связанная группа добавлена в приоритетные (\(count)/8). Приоритет действует, пока Swiftgram или доступное фоновое окно выполняют код. При полной приостановке iOS обновления не поступают."
            case "disabled":
                message = "Приоритетное наблюдение за этим каналом отключено. Обычная история Goldgram сохранена."
            case "limit_reached":
                message = "Достигнут предел 8 приоритетных обсуждений. Отключи другое в соответствующей папке."
            case "linked_group_unavailable":
                message = "Связанная группа не найдена в проверенных данных аккаунта. Открой комментарии под публикацией канала и повтори попытку."
            case "account_changed":
                message = "Telegram-аккаунт изменился. Открой архив заново."
            default:
                message = "Не удалось изменить наблюдение. Убедись, что сохранение оригиналов включено."
            }
            let alert = UIAlertController(title: enabled ? "Наблюдение за комментариями" : "Настройки наблюдения",
                                          message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Понятно", style: .default))
            self.present(alert, animated: true)
        }
    }

    private func showCaptureDiagnosticReport(account: Int64, since: NSNumber?) {
        let request: NSDictionary = [
            "accountId": NSNumber(value: account), "category": 3,
            "mode": "diagnostics", "since": since ?? NSNumber(value: 0)
        ]
        GoldgramArchiveReader.query(request) { [weak self] answer in
            guard let self else { return }
            let status = answer["status"] as? String ?? "unavailable"
            let counts = UserDefaults.standard.dictionary(
                forKey: Self.diagnosticCountPrefix + String(account)) as? [String: Int] ?? [:]
            let stages: [(String, String)] = [
                ("serverEligible", "Новый оригинал из API"),
                ("writerAccepted", "Передан в SQLite writer"),
                ("postboxUnedited", "Postbox: без метки изменения"),
                ("postboxEdited", "Postbox: с меткой изменения"),
                ("postboxCaptureEnabled", "Postbox: захват включён"),
                ("sqliteLookupHit", "Оригинал найден через SQL bridge"),
                ("inlineKnown", "Inline: оригинал известен"),
                ("inlineUnknown", "Inline: оригинал неизвестен")
            ]
            var report = stages.map { "\($0.1): \(counts[$0.0] ?? 0)" }.joined(separator: "\n")
            if status == "ok" {
                report += "\n\nSQLite за период теста:"
                report += "\nСообщений: \(answer["observed"] ?? 0)"
                report += "\nС подтверждённым оригиналом: \(answer["known"] ?? 0)"
                report += "\nИзменённых без оригинала: \(answer["missingEdited"] ?? 0)"
                report += "\nВсего изменённых: \(answer["edited"] ?? 0)"
            } else {
                report += "\n\nSQLite: \(status)"
            }
            // OS refresh evidence, never interpreted as proof of original delivery.
            let defaults = UserDefaults.standard
            func refreshDate(_ key: String) -> String {
                let timestamp = defaults.double(forKey: key)
                guard timestamp > 0 else { return "нет" }
                return self.dateFormatter.string(from: Date(timeIntervalSince1970: timestamp))
            }
            report += "\n\nФоновые проверки iOS:"
            report += "\nЗапрошено: \(refreshDate("GoldgramLastRefreshScheduledV1"))"
            report += "\nЗапущено системой: \(refreshDate("GoldgramLastRefreshStartedV1"))"
            report += "\nЗавершено: \(refreshDate("GoldgramLastRefreshFinishedV1"))"
            report += "\nПрервано: \(refreshDate("GoldgramLastRefreshExpiredV1"))"
            report += "\nЗапуск зависит от iOS, а завершение не гарантирует получение оригиналов."
            let allSessions: [GoldgramBackgroundRunReport]
            if let data = UserDefaults.standard.data(forKey: "GoldgramBackgroundRefreshRunsV1"),
               let decoded = try? PropertyListDecoder().decode([GoldgramBackgroundRunReport].self, from: data) {
                allSessions = decoded
            } else {
                allSessions = []
            }
            let sessions = Array(allSessions.filter {
                $0.accountId == nil || $0.accountId == account
            }.suffix(4).reversed())
            if sessions.isEmpty {
                report += "\n\nЖурнал фоновых сеансов №108: пока пуст."
            } else {
                report += "\n\nЖурнал фоновых сеансов №108 (последние \(sessions.count)):"
                for (index, item) in sessions.enumerated() {
                    let reason: String
                    switch item.outcome {
                    case "running": reason = "выполняется / нет отметки завершения"
                    case "completed": reason = "завершён"
                    case "ios_expiration": reason = "остановлен iOS"
                    case "goldgram_deadline": reason = "лимит Goldgram 24 секунды"
                    case "no_targets": reason = "нет закреплённых обсуждений"
                    case "no_account": reason = "аккаунт не успел загрузиться"
                    case "capture_disabled": reason = "архив выключен"
                    case "already_running": reason = "другая проверка уже выполняется"
                    case "incomplete_requests": reason = "не все запросы завершены"
                    case "postbox_unreached": reason = "не дошли до списка обсуждений Postbox"
                    case "targets_unavailable": reason = "закрепления есть, но группы недоступны"
                    case "stale_reclaimed": reason = "зависшая попытка освобождена"
                    default: reason = item.outcome
                    }
                    report += "\n\n\(index + 1). \(self.dateFormatter.string(from: Date(timeIntervalSince1970: item.startedAt)))"
                    report += "\nИтог: \(reason)"
                    let stageLabels: [String: String] = [
                        "task_invoked": "iOS вызвала обработчик",
                        "await_context": "ожидание контекста Telegram",
                        "context_ready": "контекст Telegram загружен",
                        "wakeup_lease_active": "менеджеру Telegram разрешена фоновая работа",
                        "await_account": "ожидание активного аккаунта",
                        "account_ready": "аккаунт определён",
                        "await_postbox": "ожидание доступа к Postbox",
                        "postbox_entered": "выполняется транзакция Postbox",
                        "postbox_checked": "настройки обсуждений прочитаны",
                        "capture_disabled": "захват сообщений выключен",
                        "telegram_requested": "запущена цепочка опроса (ещё не RPC)",
                        "inner_postbox_entered": "внутренняя транзакция Postbox началась",
                        "channel_state_ready": "состояние обсуждения получено",
                        "rpc_enqueued": "RPC передан сетевому сервису (отправка не подтверждена)",
                        "rpc_error": "RPC вернул ошибку",
                        "rpc_response": "получен типизированный RPC-ответ",
                        "resolve_forum_threads": "обработка веток обсуждений",
                        "resolve_poll_stories": "обработка связанных историй опроса",
                        "resolve_messages": "обработка связанных сообщений",
                        "resolve_stories": "обработка историй",
                        "resolve_peer_infos": "обработка данных участников",
                        "replay_started": "начата запись обновлений в Postbox",
                        "api_answered": "тип ответа Telegram классифицирован",
                        "replay_completed": "запись обновлений в Postbox завершена",
                        "no_account": "аккаунт не получен"
                    ]
                    report += "\nПоследний этап: \(stageLabels[item.phase ?? ""] ?? "нет данных №110")"
                    if let recorded = item.phaseAt {
                        report += " (\(self.dateFormatter.string(from: Date(timeIntervalSince1970: recorded))))"
                    }
                    if let configured = item.storedPinned {
                        report += "\nЗакреплений сохранено: \(configured)"
                        report += "\nНедоступные: канал \(item.rejectedPeer ?? 0), связь \(item.rejectedLink ?? 0), группа \(item.rejectedGroup ?? 0), доступ \(item.rejectedAccess ?? 0)"
                    } else {
                        report += "\nЗакрепления: не проверены (до Postbox не дошли)"
                    }
                    report += "\nВыбрано обсуждений: \(item.targets)"
                    report += "\nЦепочек опроса начато/завершено: \(item.requests)/\(item.completed)"
                    if item.leaseActivatedAt != nil || item.serviceMasterMode != nil {
                        let elapsed: (Double?) -> String = { time in
                            guard let time else { return "не достигнуто" }
                            return String(format: "%.1f с", max(0, time - item.startedAt))
                        }
                        let postboxMaster = item.postboxMaster.map { $0 ? "да" : "нет" } ?? "нет данных"
                        let networkAllowed = item.networkAllowed.map { $0 ? "да" : "нет" } ?? "нет данных"
                        report += "\nШлюзы сети №114 (от запуска iOS):"
                        report += "\nLease менеджера: +\(elapsed(item.leaseActivatedAt))"
                        report += "\nРежим сервиса: \(item.serviceMasterMode ?? "не получен"), активен +\(elapsed(item.serviceMasterAt)), наблюдений \(item.serviceMasterTransitions ?? 0)"
                        report += "\nPostbox master: \(postboxMaster), впервые да +\(elapsed(item.postboxMasterAt)), наблюдений \(item.postboxMasterTransitions ?? 0)"
                        report += "\nСеть разрешена: \(networkAllowed), впервые да +\(elapsed(item.networkAllowedAt)), наблюдений \(item.networkAllowedTransitions ?? 0)"
                        report += "\nMTProto connecting впервые: +\(elapsed(item.firstConnectingAt))"
                        report += "\nRPC-подписка: +\(elapsed(item.rpcEnqueuedAt)), до лимита приложения ~\(item.rpcBudgetRemaining.map { String(format: "%.1f с", $0) } ?? "нет данных")"
                    }
                    if let status = item.networkStatus {
                        report += "\nMTProto: \(status), смен состояний \(item.networkTransitions ?? 0)"
                    }
                    if let firstOnlineAt = item.firstOnlineAt {
                        report += "\nПервый online: через \(Int(max(0, firstOnlineAt - item.startedAt))) с"
                    }
                    if let attempts = item.rpcAttempts {
                        report += "\nRPC-подписок: \(attempts), ошибок \(item.rpcErrors ?? 0)"
                    }
                    if let rpcError = item.lastRpcError {
                        report += "\nПоследняя ошибка RPC: \(rpcError)"
                    }
                    if let responseAt = item.rpcResponseAt {
                        report += "\nПоследний ответ RPC: через \(Int(max(0, responseAt - item.startedAt))) с"
                        report += ", final \(item.rpcFinal.map { $0 ? "да" : "нет" } ?? "неизвестно")"
                        if let pts = item.rpcPts { report += ", PTS \(pts)" }
                        if let timeout = item.rpcTimeout { report += ", timeout \(timeout) с" }
                    }
                    report += "\nОтветы API: обычных \(item.difference), пустых \(item.empty), слишком длинных \(item.tooLong), недоступных \(item.unavailable)"
                    report += "\nВ ответах API: новых \(item.returnedNew), редакций \(item.returnedEdits)"
                    report += "\nОригиналов поставлено в очередь SQLite: \(item.originalsQueued)"
                }
            }
            report += "\nЭто счётчики запросов и очереди, не подтверждение сохранения оригиналов на диск."

            report += "\n\nСчётчики относятся только к выбранному аккаунту. Повторная доставка может увеличить значения."
            let alert = UIAlertController(title: "Результат диагностического теста",
                                          message: report, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Закрыть", style: .default))
            self.present(alert, animated: true)
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Тест", style: .plain, target: self, action: #selector(captureDiagnosticMenu))
        title = displayName ?? (category == 0 ? "Личные сообщения" :
             category == 1 ? "Группы и чаты" : category == 3 ? "Удалённые сообщения" : "Каналы")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 110
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load(reset: true)
    }

    private static func key(_ row: [String: Any]) -> String {
        let kind = (row["peerKind"] as? NSNumber)?.int32Value ?? -1
        let peer = (row["peerId"] as? NSNumber)?.int64Value ?? 0
        let message = (row["messageId"] as? NSNumber)?.int64Value ?? 0
        return "\(kind):\(peer):\(message)"
    }

    private static func fallbackName(_ row: [String: Any]) -> String {
        let kind = (row["peerKind"] as? NSNumber)?.int32Value ?? -1
        let id = (row["peerId"] as? NSNumber)?.int64Value ?? 0
        return "\(kind == 3 ? "Канал" : kind == 0 ? "Собеседник" : "Группа") #\(id)"
    }

    private func decorate(_ page: [[String: Any]], accountId: Int64,
                          completion: @escaping ([[String: Any]]) -> Void) {
        guard !page.isEmpty else { completion(page); return }
        // Only identity metadata crosses this bridge; no archived message text.
        let ids = page.map { entry -> [String: Any] in
            var row: [String: Any] = [:]
            for key in ["peerKind", "peerId", "messageId", "senderId", "senderKind", "sentAt"] {
                row[key] = entry[key]
            }
            return row
        }
        let request: [AnyHashable: Any] = ["accountId": NSNumber(value: accountId), "items": ids]
        goldgramResolveNativeMetadata(request) { response in
            let answer = response as NSDictionary
            let metadata = answer["items"] as? [[String: Any]] ?? []
            var byIdentity: [String: [String: Any]] = [:]
            for row in metadata { byIdentity[Self.key(row)] = row }
            completion(page.map { entry in
                var row = entry
                if let extra = byIdentity[Self.key(entry)] {
                    for key in ["peerName", "channelId", "channelName", "linkedPeerKind", "linkedPeerId", "senderName", "sentAt"] {
                        if let value = extra[key] { row[key] = value }
                    }
                }
                return row
            })
        }
    }

    private func rebuildDisplayItems() {
        displayItems = sources == nil ? GoldgramArchiveGrouping.folders(items, category: category) : items
    }

    private func load(reset: Bool) {
        if reset {
            generation += 1
            items = []; displayItems = []
            hasMore = false; inFlight = false
            status = "Загрузка истории…"
        }
        guard !inFlight else { return }
        guard let active = GoldgramArchiveReader.activeAccountId()?.int64Value, active > 0 else {
            items = []; displayItems = []; hasMore = false
            status = "Активный Telegram-аккаунт не определён"
            tableView.reloadData(); return
        }
        if let boundAccount, boundAccount != active {
            items = []; displayItems = []; hasMore = false
            status = "Аккаунт изменён — откройте архив заново"
            tableView.reloadData(); return
        }
        boundAccount = active
        guard items.count <= 5000 else { hasMore = false; return }
        inFlight = true
        let callGeneration = generation
        let first = sources?.first
        let request: NSDictionary = [
            "accountId": NSNumber(value: active), "category": NSNumber(value: category),
            "mode": sources == nil ? "dialogs" : (category == 2 || category == 3) ? "combined" : "messages",
            "peerId": first?["peerId"] ?? NSNumber(value: 0),
            "peerKind": first?["peerKind"] ?? NSNumber(value: -1),
            "sources": sources ?? [],
            "offset": NSNumber(value: items.count), "limit": NSNumber(value: 30)
        ]
        GoldgramArchiveReader.query(request) { [weak self] answer in
            guard let self, self.generation == callGeneration else { return }
            let page = answer["items"] as? [[String: Any]] ?? []
            self.decorate(page, accountId: active) { [weak self] enriched in
                guard let self, self.generation == callGeneration else { return }
                self.inFlight = false
                guard GoldgramArchiveReader.activeAccountId()?.int64Value == active else {
                    self.items = []; self.displayItems = []; self.hasMore = false
                    self.status = "Аккаунт изменён — откройте архив заново"
                    self.tableView.reloadData(); return
                }
                let code = answer["status"] as? String ?? ""
                if code == "ok" {
                    self.items.append(contentsOf: enriched)
                    self.rebuildDisplayItems()
                    self.hasMore = (answer["hasMore"] as? Bool ?? false) && self.items.count <= 5000
                    self.status = "Записей пока нет"
                } else {
                    self.items = []; self.displayItems = []; self.hasMore = false
                    self.status = code == "no_archive" ? "Локальный архив ещё не создан" :
                        code == "account_changed" ? "Аккаунт изменён" : "Не удалось прочитать SQLite-архив"
                }
                self.tableView.reloadData()
            }
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(1, displayItems.count + (hasMore ? 1 : 0))
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 6
        cell.detailTextLabel?.numberOfLines = 5
        cell.detailTextLabel?.textColor = .secondaryLabel
        if displayItems.indices.contains(indexPath.row) {
            let entry = displayItems[indexPath.row]
            if sources == nil {
                cell.textLabel?.text = entry["displayName"] as? String
                if category == 3 {
                    let last = (entry["lastEventAt"] as? NSNumber)?.int64Value ?? 0
                    let time = last > 0 ? dateFormatter.string(from: Date(timeIntervalSince1970: Double(last) / 1000)) : "Время неизвестно"
                    cell.detailTextLabel?.text = "\((entry["messageCount"] as? NSNumber)?.intValue ?? 0) удалено · \(time)"
                } else {
                    cell.detailTextLabel?.text = category == 2 ? "Публикации и обсуждение" :
                        "Сохранённых записей: \((entry["messageCount"] as? NSNumber)?.intValue ?? 0)"
                }
            } else {
                let original = entry["originalText"] as? String
                let latest = entry["latestText"] as? String
                let sender = entry["senderName"] as? String ??
                    (entry["senderId"] as? NSNumber).map { "Автор #\($0.int64Value)" } ?? "Автор неизвестен"
                let sent = (entry["sentAt"] as? NSNumber)?.int64Value ?? 0
                let date = sent > 0 ? dateFormatter.string(from: Date(timeIntervalSince1970: Double(sent) / 1000)) : "Время отправки неизвестно"
                let removed = (entry["deleted"] as? NSNumber)?.boolValue == true
                let edited = (entry["edited"] as? NSNumber)?.boolValue == true
                let state = removed ? (edited ? "Удалено · изменено" : "Удалено") : "Изменено"
                let kind = (entry["peerKind"] as? NSNumber)?.int32Value ?? -1
                let location = kind == 3 ? "Публикация" : (entry["channelId"] as? NSNumber) != nil ? "Обсуждение" : "Сообщение"
                let receiptOnly = removed && original == nil && (latest == nil || latest == "[Содержимое не было получено]")
                let body = receiptOnly ? "Получено только уведомление об удалении" : (removed ? latest ?? original : original ?? latest) ?? "Содержимое недоступно"
                cell.textLabel?.text = "\(sender) · \(date)\n\(body)"
                var details = ["\(state) · \(location)", entry["peerName"] as? String ?? Self.fallbackName(entry)]
                if let deletedAt = (entry["deletedAt"] as? NSNumber)?.int64Value, removed {
                    details.append("Удаление замечено: \(dateFormatter.string(from: Date(timeIntervalSince1970: Double(deletedAt) / 1000)))")
                }
                if !removed, original == nil { details.append("Оригинал не получен · показана сохранённая редакция") }
                if !removed, original != nil, let latest, latest != original { details.append("Редакция: \(latest)") }
                cell.detailTextLabel?.text = details.joined(separator: "\n")
            }
            cell.selectionStyle = .default
            cell.accessoryType = .disclosureIndicator
        } else if hasMore {
            cell.textLabel?.text = "Загрузить ещё"
            cell.detailTextLabel?.text = "Ещё записи архива"
        } else {
            cell.textLabel?.text = status
            cell.detailTextLabel?.text = "Локальная история текущего аккаунта"
            cell.selectionStyle = .none
        }
        return cell
    }

    // Inspect a single archived message without including its text or IDs in the report.
    public override func tableView(_ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard sources != nil, displayItems.indices.contains(indexPath.row) else { return nil }
        let entry = displayItems[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: "Маршрут оригинала") { [weak self] _ in
                self?.showTrace(entry)
            }])
        }
    }

    private func showTrace(_ entry: [String: Any]) {
        guard let peer = Self.tracePeer(entry),
              let id = (entry["messageId"] as? NSNumber)?.int32Value,
              let account = GoldgramArchiveReader.activeAccountId()?.int64Value else { return }
        let rows = UserDefaults.standard.array(forKey: Self.tracePrefix + String(account)) as? [[String: Any]] ?? []
        let key = "\(peer):\(id)"
        let stages = rows.first(where: { ($0["key"] as? String) == key })?["stages"] as? [String] ?? []
        let descriptions: [String: String] = [
            "newApiReceived": "Оригинальное событие получено из Telegram API",
            "newPtsAccepted": "Новое сообщение прошло PTS",
            "newPtsStale": "Новое сообщение пришло со старым PTS",
            "newPtsGap": "При новом сообщении разрыв PTS",
            "newChannelStateUnknown": "Нет состояния группы обсуждения",
            "originalEligible": "Получен подтверждённый оригинал",
            "originalQueued": "Оригинал передан в очередь SQLite",
            "editApiReceived": "Редакция получена из Telegram API",
            "editPtsAccepted": "Редакция прошла PTS",
            "editPtsStale": "Редакция пришла со старым PTS",
            "editPtsGap": "При редакции разрыв PTS",
            "postboxUnedited": "Postbox видел неотредактированную версию",
            "postboxEdited": "Postbox видел изменённую версию",
            "postboxCaptureEnabled": "Сохранение в Postbox включено",
            "sqlOriginalLookupAttempt": "Прочитать оригинал из SQLite пытались",
            "sqlOriginalLookupHit": "SQLite вернула оригинал",
            "inlineKnown": "Встроенная история распознала оригинал",
            "inlineMissing": "Встроенная история не знает оригинала"
        ]
        let hasOriginal = (entry["originalObserved"] as? NSNumber)?.boolValue == true
            && (entry["originalText"] as? String) != nil
        let count = (entry["revisionCount"] as? NSNumber)?.intValue ?? 0
        let body = stages.isEmpty ? "Нет следов после начала адресного теста. Сообщение могло появиться раньше или вне выбранной группы."
            : stages.map { "• " + (descriptions[$0] ?? $0) }.joined(separator: "\n")
        // Read extension events through authenticated shared Postbox, not
        // UserDefaults.standard (which differs between the two processes).
        goldgramResolveNativeMetadata([
            "action": "notification_trace_read",
            "accountId": NSNumber(value: account), "items": [entry]
        ]) { [weak self] response in
            guard let self else { return }
            let details = response as NSDictionary
            let ext = details["stages"] as? [String] ?? []
            let extNames: [String: String] = [
                "extensionPushPolled": "Получено уведомление; начата проверка Telegram",
                "extensionPostboxMissing": "NotificationService: сообщение не найдено в Postbox",
                "extensionPostboxEdited": "NotificationService: найдена уже изменённая версия",
                "extensionPostboxUnedited": "NotificationService: найдена версия без метки правки",
                "extensionOriginalEligible": "NotificationService: подлинный оригинал подтверждён",
                "extensionOriginalQueued": "NotificationService: оригинал поставлен в очередь",
                "extensionQueueRejected": "NotificationService: не удалось поставить оригинал в очередь",
                "extensionCaptureDisabled": "NotificationService: захват не разрешён",
                "extensionOriginalIneligible": "NotificationService: содержимое не подходит для захвата"
            ]
            let extensionResult = ext.isEmpty
                ? "Нет данных о работе NotificationService для этого сообщения. Это НЕ доказывает отсутствие уведомления."
                : ext.map { "• " + (extNames[$0] ?? $0) }.joined(separator: "\n")
            let report = "SQLite: оригинал \(hasOriginal ? "ЕСТЬ" : "ОТСУТСТВУЕТ"), сохранённых версий: \(count).\n\nОсновное приложение:\n" + body
                + "\n\nNotificationService:\n" + extensionResult
            let alert = UIAlertController(title: "Маршрут оригинала", message: report, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Закрыть", style: .default))
            self.present(alert, animated: true)
        }
    }

    private static func purgeRetained(_ items: [[String: Any]], account: NSNumber, offset: Int = 0, completion: @escaping (Bool) -> Void) {
        let end = min(offset + 50, items.count)
        let page = Array(items[offset..<end])
        let request: [AnyHashable: Any] = ["action": "purge_retained", "accountId": account,
            "items": page, "clearMedia": end == items.count]
        goldgramResolveNativeMetadata(request) { answer in
            let response = answer as NSDictionary
            guard response["status"] as? String == "ok" else { completion(false); return }
            if end == items.count { completion(true) }
            else { purgeRetained(items, account: account, offset: end, completion: completion) }
        }
    }

    @objc(presentClearHistoryFromController:)
    public static func presentClearHistory(from controller: UIViewController) {
        guard let account = GoldgramArchiveReader.activeAccountId() else { return }
        let alert = UIAlertController(
            title: "Очистить логи?",
            message: "Удалить всю локальную историю Goldgram текущего аккаунта: сохранённые тексты, редакции и записи об удалениях? Сообщения в Telegram останутся. При включённой записи новые события продолжат сохраняться.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Очистить", style: .destructive) { [weak controller] _ in
            GoldgramArchiveReader.clearHistory(forAccount: account) { [weak controller] answer in
                guard let controller else { return }
                let status = answer["status"] as? String
                let showResult: (Bool) -> Void = { purged in
                let result = UIAlertController(
                    title: status == "ok" && purged ? "Логи очищены" : "Не удалось полностью очистить логи",
                    message: status == "ok" && purged ? "Локальная история выбранного аккаунта удалена." :
                        status == "account_changed" ? "Аккаунт изменён. Откройте Goldgram в нужном аккаунте и повторите очистку." :
                        "Ошибка локального хранилища. Попробуйте ещё раз.",
                    preferredStyle: .alert
                )
                result.addAction(UIAlertAction(title: "OK", style: .default))
                controller.present(result, animated: true)
                }
                if status == "ok" {
                    let retained = answer["retainedItems"] as? [[String: Any]] ?? []
                    purgeRetained(retained, account: account, completion: showResult)
                } else { showResult(false) }
            }
        })
        controller.present(alert, animated: true)
    }

    private func showLocalRecord(_ entry: [String: Any], accountChanged: Bool = false) {
        let controller = UIViewController()
        controller.title = accountChanged ? "Аккаунт изменился" : "Сохранённая запись"
        controller.view.backgroundColor = .systemBackground
        let text = UITextView()
        text.isEditable = false
        text.font = UIFont.systemFont(ofSize: 16)
        text.backgroundColor = .clear
        text.textColor = .label
        text.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 30, right: 16)
        let original = entry["originalText"] as? String
        let latest = entry["latestText"] as? String
        let receiptOnly = original == nil && (latest == nil || latest == "[Содержимое не было получено]")
        let body = [original, latest == original ? nil : latest].compactMap { $0 }.joined(separator: "\n\n")
        text.text = accountChanged ? "Вернись в аккаунт, в котором сохранена эта запись." :
            body + "\n\n" + ((entry["deleted"] as? NSNumber)?.boolValue == true ?
                (receiptOnly ? "Получено только уведомление об удалении. Автор и содержимое этой записи не сохранены." : "Здесь показан сохранённый текст. Копия сообщения для открытия в чате недоступна.") :
                "Сообщение сейчас недоступно в Telegram. Здесь показан сохранённый текст.")
        text.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
            text.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor)
        ])
        navigationController?.pushViewController(controller, animated: true)
    }

    private func openMessage(_ entry: [String: Any], accountId: Int64) {
        guard !openingMessage else { return }
        openingMessage = true
        var request: [AnyHashable: Any] = ["action": "prepare_jump", "accountId": NSNumber(value: accountId), "items": [entry]]
        goldgramResolveNativeMetadata(request) { [weak self] response in
            guard let self else { return }
            self.openingMessage = false
            let status = (response as NSDictionary)["status"] as? String
            guard status == "ok", self.boundAccount == accountId else {
                self.showLocalRecord(entry, accountChanged: status == "account_changed"); return
            }
            request["action"] = "open_message"
            let open = { goldgramResolveNativeMetadata(request) { _ in } }
            // Finish dismissing UIKit's archive/menu sheet before the native
            // Telegram navigation mutates its own controller stack.
            if let presenter = self.navigationController?.presentingViewController ?? self.presentingViewController {
                presenter.dismiss(animated: true, completion: open)
            } else { open() }
        }
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if hasMore && indexPath.row == displayItems.count { load(reset: false); return }
        guard displayItems.indices.contains(indexPath.row) else { return }
        let entry = displayItems[indexPath.row]
        if sources != nil, let accountId = boundAccount {
            openMessage(entry, accountId: accountId)
            return
        }
        guard let members = entry["sources"] as? [[String: Any]], !members.isEmpty else { return }
        let child = GoldgramArchiveScreen(category: category, sources: members,
            displayName: entry["displayName"] as? String)
        child.boundAccount = boundAccount
        navigationController?.pushViewController(child, animated: true)
    }
}
