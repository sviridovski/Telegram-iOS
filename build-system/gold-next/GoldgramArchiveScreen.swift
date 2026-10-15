// Goldgram #74: native read-only account-scoped SQLite archive viewer.
import Foundation
import UIKit

@objc(GoldgramArchiveScreen)
public final class GoldgramArchiveScreen: UITableViewController {
    private let category: Int
    private let peerId: Int64?
    private let peerKind: Int32?
    private var boundAccount: Int64?
    private var items: [[String: Any]] = []
    private var hasMore = false
    private var inFlight = false
    private var generation = 0
    private var status = "Загрузка истории…"

    @objc(initWithCategory:)
    public convenience init(category: Int) {
        self.init(category: category, peerId: nil, peerKind: nil)
    }

    private init(category: Int, peerId: Int64?, peerKind: Int32?) {
        self.category = category
        self.peerId = peerId
        self.peerKind = peerKind
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { return nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = peerId.map { "Диалог #\($0)" } ??
            (category == 0 ? "Личные сообщения" :
             category == 1 ? "Группы и чаты" : "Каналы")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 70
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load(reset: true)
    }

    private func load(reset: Bool) {
        if reset {
            generation += 1
            items = []
            hasMore = false
            inFlight = false
            status = "Загрузка истории…"
        }
        guard !inFlight else { return }
        guard let active = GoldgramArchiveReader.activeAccountId()?.int64Value,
              active > 0 else {
            items = []
            hasMore = false
            status = "Активный Telegram-аккаунт не определён"
            tableView.reloadData()
            return
        }
        if let boundAccount, boundAccount != active {
            items = []
            hasMore = false
            status = "Аккаунт изменён — откройте архив заново"
            tableView.reloadData()
            return
        }
        boundAccount = active
        guard items.count <= 5000 else { hasMore = false; return }
        inFlight = true
        let callGeneration = generation
        let request: NSDictionary = [
            "accountId": NSNumber(value: active),
            "category": NSNumber(value: category),
            "mode": peerId == nil ? "dialogs" : "messages",
            "peerId": NSNumber(value: peerId ?? 0),
            "peerKind": NSNumber(value: peerKind ?? -1),
            "offset": NSNumber(value: items.count),
            "limit": NSNumber(value: 30)
        ]
        GoldgramArchiveReader.query(request) { [weak self] answer in
            guard let self, self.generation == callGeneration else { return }
            self.inFlight = false
            guard GoldgramArchiveReader.activeAccountId()?.int64Value == active else {
                self.items = []
                self.hasMore = false
                self.status = "Аккаунт изменён — откройте архив заново"
                self.tableView.reloadData()
                return
            }
            let code = answer["status"] as? String ?? ""
            if code == "ok" {
                let page = answer["items"] as? [[String: Any]] ?? []
                self.items.append(contentsOf: page)
                self.hasMore = (answer["hasMore"] as? Bool ?? false) && self.items.count <= 5000
                self.status = "Записей пока нет"
            } else {
                self.items = []
                self.hasMore = false
                self.status = code == "no_archive" ? "Локальный архив ещё не создан" :
                    code == "account_changed" ? "Аккаунт изменён" :
                    code == "incompatible_schema" ? "Неподдерживаемая версия архива" :
                    "Не удалось прочитать SQLite-архив"
            }
            self.tableView.reloadData()
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(1, items.count + (hasMore ? 1 : 0))
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.numberOfLines = 3
        cell.detailTextLabel?.textColor = .secondaryLabel
        if items.indices.contains(indexPath.row) {
            let entry = items[indexPath.row]
            if peerId == nil {
                let id = (entry["peerId"] as? NSNumber)?.int64Value ?? 0
                cell.textLabel?.text = "Диалог #\(id)"
                cell.detailTextLabel?.text = "Сохранённых изменений: \((entry["messageCount"] as? NSNumber)?.intValue ?? 0)"
                cell.accessoryType = .disclosureIndicator
            } else {
                let original = entry["originalText"] as? String
                let latest = entry["latestText"] as? String
                cell.textLabel?.text = original ?? "Оригинал неизвестен"
                let msgId = (entry["messageId"] as? NSNumber)?.int64Value ?? 0
                if let latest, latest != original {
                    cell.detailTextLabel?.text = "Редакция: \(latest)"
                } else {
                    cell.detailTextLabel?.text = "Сообщение #\(msgId)"
                }
                cell.selectionStyle = .none
            }
        } else if hasMore {
            cell.textLabel?.text = "Загрузить ещё"
        } else {
            cell.textLabel?.text = status
            cell.detailTextLabel?.text = "Локальная история текущего аккаунта"
            cell.selectionStyle = .none
        }
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if hasMore && indexPath.row == items.count {
            load(reset: false)
            return
        }
        guard peerId == nil, items.indices.contains(indexPath.row) else { return }
        let entry = items[indexPath.row]
        guard let id = (entry["peerId"] as? NSNumber)?.int64Value, id > 0,
              let kind = (entry["peerKind"] as? NSNumber)?.int32Value else { return }
        let child = GoldgramArchiveScreen(category: category, peerId: id, peerKind: kind)
        child.boundAccount = boundAccount
        navigationController?.pushViewController(child, animated: true)
    }
}
