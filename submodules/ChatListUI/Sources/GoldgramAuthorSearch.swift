// Goldgram #245: author-oriented Telegram search. No archive writes or extra login.
// This uses the signed-in account, and does NOT guess sender identity from text.
import Foundation
import UIKit
import TelegramCore
import SwiftSignalKit
import LocalizedPeerData
import AccountContext
import Display

@objc(GoldgramAuthorSearchBridge)
public final class GoldgramAuthorSearchBridge: NSObject {
    private static weak var activeContext: AccountContext?

    public static func bind(context: AccountContext) {
        self.activeContext = context
    }

    @objc(presentFromController:)
    public static func presentFromController(_ controller: UIViewController) {
        guard let context = activeContext else { return }
        open(from: controller, context: context, chatId: nil)
    }

    public static func open(from controller: UIViewController, context: AccountContext, chatId: EnginePeer.Id?) {
        bind(context: context)
        let search = GoldgramAuthorSearchScreen(context: context, chatId: chatId)
        controller.navigationController?.pushViewController(search, animated: true)
    }
}

private final class GoldgramAuthorSearchScreen: UITableViewController, UISearchBarDelegate {
    private let context: AccountContext
    private let chatId: EnginePeer.Id?
    private let authorInput = UISearchBar()
    private let scopePicker = UISegmentedControl(items: ["В этом чате", "Во всех чатах"])
    private let info = UILabel()
    private var candidates: [EnginePeer] = []
    private var selectedAuthor: EnginePeer?
    private var messages: [EngineMessage] = []
    private var messageIds = Set<EngineMessage.Id>()
    private var titles: [EnginePeer.Id: String] = [:]
    private var pending: [EnginePeer.Id] = []
    private var running: [EnginePeer.Id: Disposable] = [:]
    private var candidatesLocal = MetaDisposable()
    private var candidatesLocalYo = MetaDisposable()
    private var candidatesRemote = MetaDisposable()
    private var dialogsDisposable = MetaDisposable()
    private var requestGeneration = 0
    private var activeRequests = 0
    private var checkedDialogs = 0
    private var totalDialogs = 0
    private var incomplete = false
    private var ongoing = false
    private let maxDialogCount = 1000
    private let maxPagesPerDialog = 10

    init(context: AccountContext, chatId: EnginePeer.Id?) {
        self.context = context
        self.chatId = chatId
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        candidatesLocal.dispose()
        candidatesLocalYo.dispose()
        candidatesRemote.dispose()
        dialogsDisposable.dispose()
        for task in running.values { task.dispose() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Поиск по автору"
        authorInput.placeholder = "Имя контакта или @username"
        authorInput.autocapitalizationType = .none
        authorInput.autocorrectionType = .no
        authorInput.delegate = self
        scopePicker.selectedSegmentIndex = chatId == nil ? 1 : 0
        scopePicker.setEnabled(chatId != nil, forSegmentAt: 0)
        scopePicker.addTarget(self, action: #selector(changeScope), for: .valueChanged)
        let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 105))
        authorInput.frame = CGRect(x: 0, y: 0, width: 320, height: 54)
        scopePicker.frame = CGRect(x: 12, y: 60, width: 296, height: 34)
        wrapper.addSubview(authorInput)
        wrapper.addSubview(scopePicker)
        tableView.tableHeaderView = wrapper
        info.textAlignment = .center
        info.textColor = .secondaryLabel
        info.font = .preferredFont(forTextStyle: .footnote)
        info.numberOfLines = 0
        info.frame = CGRect(x: 12, y: 0, width: 296, height: 84)
        tableView.tableFooterView = info
        info.text = "Введите имя человека, затем выберите его Telegram-профиль."
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Do not keep searching after the author-search screen is closed.
        if isMovingFromParent || isBeingDismissed {
            cancelSearch()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        if abs(header.bounds.width - tableView.bounds.width) > 1 {
            header.frame.size.width = tableView.bounds.width
            tableView.tableHeaderView = header
        }
        authorInput.frame.size.width = header.bounds.width
        scopePicker.frame.size.width = max(100, header.bounds.width - 24)
        info.frame.size.width = max(100, header.bounds.width - 24)
    }

    private func addCandidates(_ peers: [EnginePeer], generation: Int) {
        guard generation == requestGeneration, selectedAuthor == nil else { return }
        var used = Set(candidates.map { $0.id })
        for peer in peers {
            guard case .user = peer else { continue }
            if used.insert(peer.id).inserted { candidates.append(peer) }
        }
        candidates.sort { $0.compactDisplayTitle.localizedCaseInsensitiveCompare($1.compactDisplayTitle) == .orderedAscending }
        tableView.reloadData()
        info.text = candidates.isEmpty
            ? "Контакты пока не найдены. Проверьте имя или @username."
            : "Выберите пользователя. Совпадения в текстах сообщений не используются."
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        cancelSearch()
        selectedAuthor = nil
        title = "Поиск по автору"
        candidates = []
        tableView.reloadData()
        let original = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard original.count >= 2 else {
            info.text = "Введите минимум 2 символа имени или @username."
            return
        }
        let generation = requestGeneration
        let normalized = original.lowercased().replacingOccurrences(of: "ё", with: "е")
        let local = context.engine.contacts.searchLocalPeers(query: normalized)
            |> take(1)
            |> deliverOnMainQueue
        candidatesLocal.set(local.start(next: { [weak self] matches in
            self?.addCandidates(matches.compactMap { $0.peer }, generation: generation)
        }))
        // The local Postbox index can distinguish е from ё. Query both spellings
        // so a saved "Лёша Начальник" is found when the user enters "леша".
        let yoQuery = normalized.replacingOccurrences(of: "е", with: "ё")
        if yoQuery != normalized {
            let yoLocal = context.engine.contacts.searchLocalPeers(query: yoQuery)
                |> take(1)
                |> deliverOnMainQueue
            candidatesLocalYo.set(yoLocal.start(next: { [weak self] matches in
                self?.addCandidates(matches.compactMap { $0.peer }, generation: generation)
            }))
        }
        let remote = context.engine.contacts.searchRemotePeers(query: original, scope: .everywhere)
            |> take(1)
            |> deliverOnMainQueue
        candidatesRemote.set(remote.start(next: { [weak self] mine, global in
            self?.addCandidates((mine + global).map { $0.peer }, generation: generation)
        }))
        info.text = "Ищу контакты…"
    }

    @objc private func changeScope() {
        if selectedAuthor != nil { beginSearch() }
    }

    private func cancelSearch() {
        requestGeneration += 1
        dialogsDisposable.set(nil)
        candidatesLocal.set(nil)
        candidatesLocalYo.set(nil)
        candidatesRemote.set(nil)
        for task in running.values { task.dispose() }
        running.removeAll()
        pending.removeAll()
        messages.removeAll()
        messageIds.removeAll()
        titles.removeAll()
        checkedDialogs = 0
        totalDialogs = 0
        activeRequests = 0
        incomplete = false
        ongoing = false
    }

    private func beginSearch() {
        guard selectedAuthor != nil else { return }
        cancelSearch()
        title = selectedAuthor.map { "Сообщения: " + $0.compactDisplayTitle } ?? "Поиск по автору"
        let generation = requestGeneration
        tableView.reloadData()
        ongoing = true
        info.text = "Поиск продолжается…"
        if scopePicker.selectedSegmentIndex == 0, let chatId {
            pending = [chatId]
            totalDialogs = 1
            pump(generation)
            return
        }
        // Chat list fetching uses the CURRENT account and includes the archive folder.
        // Bounded sampling is disclosed if older dialog pages remain unavailable.
        let root = context.engine.messages.chatList(group: .root, count: maxDialogCount)
            |> filter { !$0.isLoading }
            |> take(1)
        let archived = context.engine.messages.chatList(group: .archive, count: maxDialogCount)
            |> filter { !$0.isLoading }
            |> take(1)
        dialogsDisposable.set((combineLatest(root, archived)
            |> deliverOnMainQueue).start(next: { [weak self] rootList, archiveList in
                guard let self, self.requestGeneration == generation else { return }
                self.incomplete = rootList.hasEarlier || rootList.hasLater ||
                    archiveList.hasEarlier || archiveList.hasLater ||
                    rootList.items.count >= self.maxDialogCount ||
                    archiveList.items.count >= self.maxDialogCount
                var unique = Set<EnginePeer.Id>()
                for item in rootList.items + archiveList.items {
                    guard case let .chatList(peerId) = item.id,
                          let peer = item.renderedPeer.peer else { continue }
                    switch peer {
                    case .user, .legacyGroup, .channel:
                        break
                    default:
                        continue
                    }
                    if unique.insert(peerId).inserted {
                        self.pending.append(peerId)
                        self.titles[peerId] = item.renderedPeer.peer?.compactDisplayTitle ?? "Диалог"
                    }
                }
                self.totalDialogs = self.pending.count
                self.pump(generation)
            }))
    }

    private func pump(_ generation: Int) {
        guard generation == requestGeneration, selectedAuthor != nil else { return }
        while activeRequests < 2 && !pending.isEmpty {
            let peerId = pending.removeFirst()
            activeRequests += 1
            scan(peerId, page: 0, previous: nil, generation: generation)
        }
        if pending.isEmpty && activeRequests == 0 {
            ongoing = false
            let note = incomplete
                ? " ВНИМАНИЕ: часть диалогов или страниц истории не проверена."
                : " При сетевых сбоях Telegram может вернуть неполную выдачу."
            let summary = messages.isEmpty
                ? "Совпадений среди проверенных чатов нет."
                : "Найдено сообщений: \(messages.count)."
            info.text = "Проверено чатов: \(checkedDialogs) из \(totalDialogs). " + summary + note
        } else {
            info.text = "Ищу… Проверено: \(checkedDialogs) из \(totalDialogs), найдено: \(messages.count)."
        }
    }

    private func complete(_ peerId: EnginePeer.Id, generation: Int) {
        guard generation == requestGeneration else { return }
        running.removeValue(forKey: peerId)?.dispose()
        activeRequests = max(0, activeRequests - 1)
        checkedDialogs += 1
        pump(generation)
    }

    private func scan(_ peerId: EnginePeer.Id, page: Int, previous: SearchMessagesState?, generation: Int) {
        guard generation == requestGeneration, let authorId = selectedAuthor?.id else { return }
        let location: SearchMessagesLocation = .peer(
            peerId: peerId, fromId: authorId, tags: nil, reactions: nil,
            threadId: nil, minDate: nil, maxDate: nil)
        let signal = context.engine.messages.searchMessages(
            location: location, query: "", state: previous, limit: 100)
            |> deliverOnMainQueue
        running[peerId] = signal.start(next: { [weak self] result, nextState in
            guard let self, self.requestGeneration == generation,
                  self.selectedAuthor?.id == authorId else { return }
            for rawMessage in result.messages {
                let message = EngineMessage(rawMessage)
                // Never attribute anonymous admins, channel posts or forwards to a user.
                guard message.author?.id == authorId else { continue }
                if self.messageIds.insert(message.id).inserted {
                    self.messages.append(message)
                }
            }
            self.messages.sort { $0.timestamp > $1.timestamp }
            self.tableView.reloadData()
            if result.completed {
                self.complete(peerId, generation: generation)
            } else if page + 1 >= self.maxPagesPerDialog || previous == nextState {
                self.incomplete = true
                self.complete(peerId, generation: generation)
            } else {
                self.scan(peerId, page: page + 1, previous: nextState, generation: generation)
            }
        })
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        selectedAuthor == nil ? candidates.count : messages.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.accessoryType = .disclosureIndicator
        if selectedAuthor == nil {
            let peer = candidates[indexPath.row]
            cell.textLabel?.text = peer.compactDisplayTitle
            cell.detailTextLabel?.text = "Telegram ID: \(peer.id.toInt64())"
        } else {
            let message = messages[indexPath.row]
            let peerTitle = titles[message.id.peerId] ?? message.enginePeers[message.id.peerId]?.compactDisplayTitle ?? "Чат"
            cell.textLabel?.text = peerTitle
            let date = DateFormatter.localizedString(from: Date(timeIntervalSince1970: Double(message.timestamp)),
                dateStyle: .short, timeStyle: .short)
            cell.detailTextLabel?.text = date + " · " + String(message.text.prefix(160))
            cell.detailTextLabel?.numberOfLines = 3
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if selectedAuthor == nil {
            guard candidates.indices.contains(indexPath.row) else { return }
            selectedAuthor = candidates[indexPath.row]
            authorInput.text = selectedAuthor?.compactDisplayTitle
            authorInput.resignFirstResponder()
            beginSearch()
        } else {
            guard messages.indices.contains(indexPath.row),
                  let navigation = navigationController as? NavigationController else { return }
            let message = messages[indexPath.row]
            guard let chatPeer = message.enginePeers[message.id.peerId] else { return }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(
                navigationController: navigation, context: context,
                chatLocation: .peer(chatPeer),
                subject: .message(id: .id(message.id), highlight: nil,
                    timecode: nil, setupReply: false)))
        }
    }
}
