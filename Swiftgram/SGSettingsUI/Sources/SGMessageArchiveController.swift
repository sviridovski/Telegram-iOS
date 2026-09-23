import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import AccountContext
import TelegramPresentationData

private final class SGMessageArchiveController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let kind: SwiftgramMessageArchive.Kind
    private let openChat: (SwiftgramMessageArchive.Entry) -> Void
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var entries: [SwiftgramMessageArchive.Entry] = []
    private let dateFormatter = DateFormatter()

    init(context: AccountContext, kind: SwiftgramMessageArchive.Kind, openChat: @escaping (SwiftgramMessageArchive.Entry) -> Void) {
        self.context = context
        self.kind = kind
        self.openChat = openChat
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationTheme: presentationData.theme, presentationStrings: presentationData.strings))
        self.dateFormatter.dateStyle = .short
        self.dateFormatter.timeStyle = .short
        self.title = kind == .deleted ? "Удалённые сообщения" : "Изменённые сообщения"
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 96
        self.displayNode.view.addSubview(self.tableView)
        self.refreshEntries()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.refreshEntries()
    }

    private func refreshEntries() {
        self.entries = SwiftgramMessageArchive.shared.list(accountId: self.context.account.peerId, kind: self.kind)
        self.title = "\(self.kind == .deleted ? "Удалённые" : "Изменённые") · \(self.entries.count)"
        self.tableView.reloadData()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.tableView.frame = CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top))
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let entry = self.entries[indexPath.row]
        cell.textLabel?.text = "\(entry.chatTitle) · \(entry.authorTitle)"
        cell.detailTextLabel?.text = "\(self.dateFormatter.string(from: Date(timeIntervalSince1970: entry.eventTimestamp))) · \(entry.previousText)"
        cell.detailTextLabel?.numberOfLines = 2
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = self.entries[indexPath.row]
        let body: String
        if entry.kind == .edited {
            body = "Текущий текст на момент правки:\n\(entry.currentText ?? "—")\n\nДо правки:\n\(entry.previousText)"
        } else {
            body = "Сохранённое сообщение:\n\(entry.previousText)\n\nКто удалил сообщение, Telegram не сообщает."
        }
        let alert = UIAlertController(title: "\(entry.chatTitle) · \(self.dateFormatter.string(from: Date(timeIntervalSince1970: entry.eventTimestamp)))", message: body, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Открыть чат", style: .default, handler: { [weak self] _ in
            self?.openChat(entry)
        }))
        alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
        self.present(alert, animated: true)
    }
}

public func sgMessageArchiveController(context: AccountContext, kind: SwiftgramMessageArchive.Kind, openChat: @escaping (SwiftgramMessageArchive.Entry) -> Void) -> ViewController {
    return SGMessageArchiveController(context: context, kind: kind, openChat: openChat)
}
