// Goldgram #80: account-scoped named channel/discussion archive.
import Foundation
import UIKit
import tgapiC

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

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = displayName ?? (category == 0 ? "Личные сообщения" :
             category == 1 ? "Группы и чаты" : "Каналы")
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
            "mode": sources == nil ? "dialogs" : category == 2 ? "combined" : "messages",
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
                cell.detailTextLabel?.text = category == 2 ? "Публикации и обсуждение" :
                    "Сохранённых записей: \((entry["messageCount"] as? NSNumber)?.intValue ?? 0)"
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
                cell.textLabel?.text = "\(sender) · \(date)\n\(original ?? "Оригинал неизвестен")"
                var details = ["\(state) · \(location)", entry["peerName"] as? String ?? Self.fallbackName(entry)]
                if let latest, latest != original { details.append("Редакция: \(latest)") }
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
                let result = UIAlertController(
                    title: status == "ok" ? "Логи очищены" : "Не удалось очистить логи",
                    message: status == "ok" ? "Локальная история выбранного аккаунта удалена." :
                        status == "account_changed" ? "Аккаунт изменён. Откройте Goldgram в нужном аккаунте и повторите очистку." :
                        "Ошибка локального хранилища. Попробуйте ещё раз.",
                    preferredStyle: .alert
                )
                result.addAction(UIAlertAction(title: "OK", style: .default))
                controller.present(result, animated: true)
            }
        })
        controller.present(alert, animated: true)
    }

    private func showArchiveJumpFailure() {
        let alert = UIAlertController(
            title: "Переход недоступен",
            message: "Не удалось открыть сообщение в текущем аккаунте. Удалённые или недоступные сообщения останутся только в локальном архиве.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if hasMore && indexPath.row == displayItems.count { load(reset: false); return }
        guard displayItems.indices.contains(indexPath.row) else { return }
        let entry = displayItems[indexPath.row]
        if sources != nil, let accountId = boundAccount {
            guard (entry["deleted"] as? NSNumber)?.boolValue != true,
                  let number = entry["messageId"] as? NSNumber,
                  let peerId = entry["peerId"] as? NSNumber,
                  let peerKind = entry["peerKind"] as? NSNumber else {
                showArchiveJumpFailure(); return
            }
            let request: NSDictionary = ["accountId": NSNumber(value: accountId),
                "peerKind": peerKind, "peerId": peerId, "messageId": number]
            if !GoldgramArchiveReader.navigateToMessage(request) { showArchiveJumpFailure() }
            return
        }
        guard let members = entry["sources"] as? [[String: Any]], !members.isEmpty else { return }
        let child = GoldgramArchiveScreen(category: category, sources: members,
            displayName: entry["displayName"] as? String)
        child.boundAccount = boundAccount
        navigationController?.pushViewController(child, animated: true)
    }
}
