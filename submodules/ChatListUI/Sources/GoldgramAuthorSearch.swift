// Goldgram #245: author-oriented Telegram search. No archive writes or extra login.
// This uses the signed-in account, and does NOT guess sender identity from text.
import Foundation
import Darwin
import UIKit
import TelegramCore
import SwiftSignalKit
import LocalizedPeerData
import AccountContext
import Display

@objc(GoldgramAuthorSearchBridge)
public final class GoldgramAuthorSearchBridge: NSObject {
    private static weak var activeContext: AccountContext?
    private static weak var primaryContext: AccountContext?
    // The TelegramUI host owns the native navigation stack and account checks.
    public static var nativeJump: ((AccountContext, EngineMessage.Id, UINavigationController, UIViewController, UIView?) -> Bool)?

    public static func bindPrimary(context: AccountContext?) {
        self.primaryContext = context
    }

    fileprivate static func isCurrentAccount(_ context: AccountContext) -> Bool {
        return primaryContext?.account.id == context.account.id
    }

    public static func bind(context: AccountContext) {
        self.activeContext = context
    }

    @objc(presentFromController:)
    public static func presentFromController(_ controller: UIViewController) {
        guard let context = primaryContext else { return }
        open(from: controller, context: context, chatId: nil)
    }

    public static func open(from controller: UIViewController, context: AccountContext, chatId: EnginePeer.Id?) {
        bind(context: context)
        guard isCurrentAccount(context) else { return }
        let search = GoldgramUnifiedSearchScreen(context: context, chatId: chatId)
        // Native Telegram controllers need a Telegram layout host; UIKit
        // search results need a UIKit host. Use a separate modal for native entry.
        if let navigation = controller.navigationController, !(navigation is NavigationController) {
            navigation.pushViewController(search, animated: true)
        } else {
            let navigation = UINavigationController(rootViewController: search)
            search.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: search, action: #selector(GoldgramUnifiedSearchScreen.closeModal))
            controller.present(navigation, animated: true)
        }
    }

    @objc(presentFavoritesFromController:)
    public static func presentFavoritesFromController(_ controller: UIViewController) {
        guard let context = primaryContext, isCurrentAccount(context) else { return }
        presentPersonal(GoldgramPersonalList(context: context), from: controller)
    }

    @objc(presentPersonalContactsFromController:)
    public static func presentPersonalContactsFromController(_ controller: UIViewController) {
        guard let context = primaryContext, isCurrentAccount(context) else { return }
        presentPersonal(GoldgramPersonalContacts(context: context), from: controller)
    }

    private static func presentPersonal(_ screen: UIViewController, from controller: UIViewController) {
        if let navigation = controller.navigationController, !(navigation is NavigationController) {
            navigation.pushViewController(screen, animated: true)
        } else {
            let navigation = UINavigationController(rootViewController: screen)
            screen.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Закрыть", style: .plain, target: nil, action: nil)
            screen.navigationItem.leftBarButtonItem?.primaryAction = UIAction(title: "Закрыть") { [weak navigation] _ in
                navigation?.dismiss(animated: true)
            }
            controller.present(navigation, animated: true)
        }
    }

    @objc(presentGhostPickerFromController:completion:)
    public static func presentGhostPickerFromController(_ controller: UIViewController, completion: @escaping (NSDictionary) -> Void) {
        guard let context = primaryContext, let navigation = controller.navigationController,
              !(navigation is NavigationController) else {
            let alert = UIAlertController(title: "Не удалось открыть контакты", message: "Откройте настройки Goldgram в активном аккаунте.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            controller.present(alert, animated: true)
            return
        }
        let picker = GoldgramAuthorSearchScreen(context: context, chatId: nil, selection: completion)
        navigation.pushViewController(picker, animated: true)
    }
}

private final class GoldgramAuthorSearchScreen: UITableViewController, UISearchBarDelegate {
    private let context: AccountContext
    private let chatId: EnginePeer.Id?
    private let selection: ((NSDictionary) -> Void)?
    private let authorSelection: ((EnginePeer) -> Void)?
    private var handingOff = false
    private var returnOffset: CGPoint?
    private var needsReload = false
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

    init(context: AccountContext, chatId: EnginePeer.Id?, selection: ((NSDictionary) -> Void)? = nil,
         authorSelection: ((EnginePeer) -> Void)? = nil) {
        self.context = context
        self.chatId = chatId
        self.selection = selection
        self.authorSelection = authorSelection
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
        title = authorSelection != nil ? "Выбрать автора" : selection == nil ? "Поиск по автору" : "Добавить исключение"
        authorInput.placeholder = "Имя контакта или @username"
        authorInput.autocapitalizationType = .none
        authorInput.autocorrectionType = .no
        authorInput.delegate = self
        scopePicker.selectedSegmentIndex = chatId == nil ? 1 : 0
        scopePicker.setEnabled(chatId != nil, forSegmentAt: 0)
        scopePicker.addTarget(self, action: #selector(changeScope), for: .valueChanged)
        let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: selection == nil && authorSelection == nil ? 105 : 58))
        authorInput.frame = CGRect(x: 0, y: 0, width: 320, height: 54)
        scopePicker.frame = CGRect(x: 12, y: 60, width: 296, height: 34)
        wrapper.addSubview(authorInput)
        if selection == nil && authorSelection == nil { wrapper.addSubview(scopePicker) }
        tableView.tableHeaderView = wrapper
        info.textAlignment = .center
        info.textColor = .secondaryLabel
        info.font = .preferredFont(forTextStyle: .footnote)
        info.numberOfLines = 0
        info.frame = CGRect(x: 12, y: 0, width: 296, height: 84)
        tableView.tableFooterView = info
        info.text = "Введите имя человека, затем выберите его Telegram-профиль."
    }

    @objc fileprivate func closeModal() {
        dismiss(animated: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if handingOff {
            handingOff = false
            if needsReload {
                needsReload = false
                tableView.reloadData()
            }
            if let offset = returnOffset {
                tableView.layoutIfNeeded()
                tableView.setContentOffset(offset, animated: false)
            }
            returnOffset = nil
        }
    }

    private func showJumpError() {
        let alert = UIAlertController(title: "Не удалось открыть сообщение", message: "Проверьте активный аккаунт и доступность чата.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Do not keep searching after the author-search screen is closed.
        if !handingOff && (isMovingFromParent || isBeingDismissed) {
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
        title = authorSelection != nil ? "Выбрать автора" : selection == nil ? "Поиск по автору" : "Добавить исключение"
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
            if self.handingOff { self.needsReload = true }
            else { self.tableView.reloadData() }
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
            let peer = candidates[indexPath.row]
            if let authorSelection {
                guard GoldgramAuthorSearchBridge.isCurrentAccount(context) else { return }
                authorSelection(peer)
                navigationController?.popViewController(animated: true)
                return
            }
            if let selection {
                guard case .user = peer, GoldgramAuthorSearchBridge.isCurrentAccount(context) else { return }
                let alert = UIAlertController(title: "Добавить исключение?", message: peer.compactDisplayTitle + "\nЭтот человек сможет видеть ваши отметки о прочтении и набор текста при включённой невидимке.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
                alert.addAction(UIAlertAction(title: "Добавить", style: .default) { [weak self] _ in
                    guard let self, GoldgramAuthorSearchBridge.isCurrentAccount(self.context) else { return }
                    selection(["id": NSNumber(value: peer.id.toInt64()), "name": peer.compactDisplayTitle, "username": peer.addressName ?? ""])
                    self.navigationController?.popViewController(animated: true)
                })
                present(alert, animated: true)
                return
            }
            selectedAuthor = peer
            authorInput.text = selectedAuthor?.compactDisplayTitle
            authorInput.resignFirstResponder()
            beginSearch()
        } else {
            guard !handingOff, messages.indices.contains(indexPath.row),
                  let navigation = navigationController,
                  navigation.topViewController === self,
                  let presenter = navigation.presentingViewController,
                  let jump = GoldgramAuthorSearchBridge.nativeJump,
                  GoldgramAuthorSearchBridge.isCurrentAccount(context) else {
                showJumpError()
                return
            }
            let id = messages[indexPath.row].id
            authorInput.resignFirstResponder()
            returnOffset = tableView.contentOffset
            handingOff = true
            let snapshot = navigation.view.snapshotView(afterScreenUpdates: false)
            // Dismiss the UIKit sheet; native host pushes a proper Display
            // chat + return controller. Returning re-presents THIS sheet.
            presenter.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                if !jump(self.context, id, navigation, presenter, snapshot) {
                    guard presenter.viewIfLoaded?.window != nil,
                          presenter.presentedViewController == nil else {
                        self.handingOff = false
                        return
                    }
                    presenter.present(navigation, animated: false) { [weak self] in
                        self?.showJumpError()
                    }
                }
            }
        }
    }
}


// #255: runtime-only, read-only archive adapter. C ABI uses raw pointers so
// no Swift module from the injected Mx library is required by ChatListUI.
private final class GoldgramUnifiedCallbackBox {
    let completion: (NSDictionary) -> Void
    init(_ completion: @escaping (NSDictionary) -> Void) { self.completion = completion }
}

private let goldgramUnifiedReply: @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void = { opaque, raw in
    guard let opaque else { return }
    let box = Unmanaged<GoldgramUnifiedCallbackBox>.fromOpaque(opaque).takeRetainedValue()
    let result = raw.map { Unmanaged<NSDictionary>.fromOpaque($0).takeUnretainedValue() }
        ?? ["status": "unavailable", "items": []]
    box.completion(result)
}

private func goldgramUnifiedCall(_ symbol: String, _ request: NSDictionary,
                                 completion: @escaping (NSDictionary) -> Void) {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void
    typealias Call = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?, Callback?) -> Void
    guard let handle = dlopen(nil, RTLD_NOW) else {
        completion(["status": "unavailable", "items": []]); return
    }
    defer { dlclose(handle) }
    guard let address = dlsym(handle, symbol) else {
        completion(["status": "unavailable", "items": []]); return
    }
    let opaque = Unmanaged.passRetained(GoldgramUnifiedCallbackBox(completion)).toOpaque()
    unsafeBitCast(address, to: Call.self)(
        UnsafeRawPointer(Unmanaged.passUnretained(request).toOpaque()), opaque, goldgramUnifiedReply)
}

// Canonical Telegram identity includes peer namespace and message namespace.
// Archive kinds 2/3 are the SAME Telegram cloud-channel namespace; never
// merge a user, basic group and channel solely because their raw IDs match.
private enum GoldgramUnifiedIdentity {
    static func message(_ row: [String: Any]) -> EngineMessage.Id? {
        guard let kind = (row["peerKind"] as? NSNumber)?.int32Value,
              let raw = (row["peerId"] as? NSNumber)?.int64Value, raw > 0,
              let mid64 = (row["messageId"] as? NSNumber)?.int64Value,
              let mid = Int32(exactly: mid64), mid > 0 else { return nil }
        let namespace: EnginePeer.Id.Namespace
        switch kind {
        case 0: namespace = Namespaces.Peer.CloudUser
        case 1: namespace = Namespaces.Peer.CloudGroup
        case 2, 3: namespace = Namespaces.Peer.CloudChannel
        default: return nil
        }
        let peer = EnginePeer.Id(namespace: namespace, id: ._internalFromInt64Value(raw))
        return EngineMessage.Id(peerId: peer, namespace: Namespaces.Message.Cloud, id: mid)
    }

    static func sources(_ peer: EnginePeer.Id) -> [[String: Any]]? {
        let raw = peer.id._internalGetInt64Value()
        guard raw > 0 else { return nil }
        let kinds: [Int32]
        switch peer.namespace {
        case Namespaces.Peer.CloudUser: kinds = [0]
        case Namespaces.Peer.CloudGroup: kinds = [1]
        case Namespaces.Peer.CloudChannel: kinds = [2, 3]
        default: return nil
        }
        return kinds.map { ["peerKind": NSNumber(value: $0), "peerId": NSNumber(value: raw)] }
    }
}

private final class GoldgramUnifiedDialogPicker: UITableViewController, UISearchBarDelegate {
    private let context: AccountContext
    private let choose: (EnginePeer?) -> Void
    private let query = UISearchBar()
    private let disposable = MetaDisposable()
    private var peers: [EnginePeer] = []
    private var filtered: [EnginePeer] = []
    private var loaded = false
    private var partial = false

    init(context: AccountContext, choose: @escaping (EnginePeer?) -> Void) {
        self.context = context
        self.choose = choose
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { return nil }
    deinit { disposable.dispose() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Выбрать диалог"
        query.placeholder = "Название чата или канала"
        query.delegate = self
        query.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 56)
        tableView.tableHeaderView = query
        let root = context.engine.messages.chatList(group: .root, count: 1000) |> filter { !$0.isLoading } |> take(1)
        let archive = context.engine.messages.chatList(group: .archive, count: 1000) |> filter { !$0.isLoading } |> take(1)
        disposable.set((combineLatest(root, archive) |> deliverOnMainQueue).start(next: { [weak self = self] a, b in
            guard let self, GoldgramAuthorSearchBridge.isCurrentAccount(self.context) else { return }
            var seen = Set<EnginePeer.Id>()
            self.peers = (a.items + b.items).compactMap { item in
                guard case .chatList = item.id, let peer = item.renderedPeer.peer,
                      GoldgramUnifiedIdentity.sources(peer.id) != nil, seen.insert(peer.id).inserted else { return nil }
                return peer
            }.sorted { $0.compactDisplayTitle.localizedCaseInsensitiveCompare($1.compactDisplayTitle) == .orderedAscending }
            self.partial = a.hasEarlier || a.hasLater || b.hasEarlier || b.hasLater ||
                a.items.count >= 1000 || b.items.count >= 1000
            self.loaded = true
            self.applyFilter()
        }))
    }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { applyFilter() }
    private func applyFilter() {
        let term = (query.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = peers.filter {
            term.isEmpty || $0.compactDisplayTitle.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        1 + filtered.count
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        !loaded ? "Загружаю список диалогов…" :
        partial ? "Показаны доступные диалоги из основной и архивной папок; список может быть неполным." :
        "Только доступные облачные диалоги текущего аккаунта."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = indexPath.row == 0 ? "Все диалоги" : filtered[indexPath.row - 1].compactDisplayTitle
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard GoldgramAuthorSearchBridge.isCurrentAccount(context),
              indexPath.row == 0 || filtered.indices.contains(indexPath.row - 1) else { return }
        choose(indexPath.row == 0 ? nil : filtered[indexPath.row - 1])
        navigationController?.popViewController(animated: true)
    }
}

private final class GoldgramUnifiedSearchScreen: UITableViewController, UISearchBarDelegate {
    private let context: AccountContext
    private var chosenChat: EnginePeer.Id?
    private var chosenChatName: String?
    private var author: EnginePeer?
    private var personalAuthorId: EnginePeer.Id?
    private var personalAuthorName: String?
    private let source = UISegmentedControl(items: ["Telegram", "Архив", "Везде"])
    private let period = UISegmentedControl(items: ["Любая дата", "Сегодня", "7 дней", "30 дней"])
    private let event = UISegmentedControl(items: ["Все", "Изменённые", "Удалённые"])
    private let input = UISearchBar()
    private let authorButton = UIButton(type: .system)
    private let dialogButton = UIButton(type: .system)
    private let info = UILabel()
    private let dialogs = MetaDisposable()
    private var global = MetaDisposable()
    private var running: [EnginePeer.Id: MetaDisposable] = [:]
    private var pending: [EnginePeer.Id] = []
    private var titles: [EnginePeer.Id: String] = [:]
    private var allowed = Set<EnginePeer.Id>()
    private var remoteRows: [EngineMessage.Id: EngineMessage] = [:]
    private var localRows: [EngineMessage.Id: [String: Any]] = [:]
    private var order: [EngineMessage.Id] = []
    private var generation = 0
    private var term = ""
    private var since: Int32?
    private var requestedAuthor: EnginePeer.Id?
    private var requestedChat: EnginePeer.Id?
    private var requestedEvent = 0
    private var localOffset = 0
    private var localMore = false
    private var localBusy = false
    private var localStatus = ""
    private var remoteStatus = ""
    private var remoteBusy = false
    private var waitingDialogs = false
    private var globalPage = -1
    private var peerPages: [EnginePeer.Id: Int] = [:]
    private var partial = false
    private var checked = 0
    private var total = 0
    private var handingOff = false
    private var jumping = false
    private var returnOffset: CGPoint?
    private var needsReload = false
    private let maxResults = 5000

    init(context: AccountContext, chatId: EnginePeer.Id?, initialAuthorId: EnginePeer.Id? = nil,
         initialAuthorName: String? = nil) {
        self.context = context
        self.personalAuthorId = initialAuthorId
        self.personalAuthorName = initialAuthorName
        self.chosenChat = chatId
        self.chosenChatName = chatId == nil ? nil : "Текущий чат"
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { return nil }
    deinit {
        NotificationCenter.default.removeObserver(self)
        dialogs.dispose(); global.dispose(); for task in running.values { task.dispose() }
    }

    private var accountId: Int64 { context.account.peerId.id._internalGetInt64Value() }
    private var accountOK: Bool { GoldgramAuthorSearchBridge.isCurrentAccount(context) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Расширенный поиск"
        let favorites = UIBarButtonItem(image: UIImage(systemName: "bookmark"), style: .plain,
                                        target: self, action: #selector(openFavorites))
        favorites.accessibilityLabel = "Личное избранное"
        let contacts = UIBarButtonItem(image: UIImage(systemName: "person.crop.rectangle"), style: .plain,
                                       target: self, action: #selector(openPersonalContacts))
        contacts.accessibilityLabel = "Личные карточки контактов"
        navigationItem.rightBarButtonItems = [favorites, contacts]
        source.selectedSegmentIndex = 2
        period.selectedSegmentIndex = 0
        event.selectedSegmentIndex = 0
        input.placeholder = "Текст сообщения или редакции"
        input.autocorrectionType = .no
        input.returnKeyType = .search
        input.delegate = self
        authorButton.addTarget(self, action: #selector(selectAuthor), for: .touchUpInside)
        dialogButton.addTarget(self, action: #selector(selectDialog), for: .touchUpInside)
        let find = UIButton(type: .system)
        find.setTitle("Найти", for: .normal)
        find.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        find.addTarget(self, action: #selector(submit), for: .touchUpInside)
        let reset = UIButton(type: .system)
        reset.setTitle("Сбросить фильтры", for: .normal)
        reset.addTarget(self, action: #selector(resetFilters), for: .touchUpInside)
        source.addTarget(self, action: #selector(sourceChanged), for: .valueChanged)
        period.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        event.addTarget(self, action: #selector(eventChanged), for: .valueChanged)
        let actions = UIStackView(arrangedSubviews: [find, reset])
        actions.distribution = .fillEqually
        let note = UILabel()
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        note.text = "Дата — время отправки. Тип события применяется к архиву. Поиск в Telegram зависит от сервера."
        info.numberOfLines = 0
        info.textColor = .secondaryLabel
        info.font = .preferredFont(forTextStyle: .footnote)
        info.text = "Введите текст или выберите автора, диалог либо период."
        let stack = UIStackView(arrangedSubviews: [source, input, authorButton, dialogButton, period, event, actions, note, info])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        for control in [source, period, event] { control.heightAnchor.constraint(equalToConstant: 32).isActive = true }
        input.heightAnchor.constraint(equalToConstant: 50).isActive = true
        for button in [authorButton, dialogButton, find, reset] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
            button.titleLabel?.lineBreakMode = .byTruncatingTail
        }
        let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 390))
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8)
        ])
        tableView.tableHeaderView = header
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 110
        updateButtons()
        NotificationCenter.default.addObserver(self, selector: #selector(archiveChanged(_:)),
            name: Notification.Name("GoldgramArchiveChanged"), object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView, tableView.bounds.width > 0 else { return }
        let width = tableView.bounds.width
        let size = header.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        if size.height > 0 && (abs(header.frame.height - size.height) > 1 || abs(header.frame.width - width) > 1) {
            header.frame = CGRect(x: 0, y: 0, width: width, height: ceil(size.height))
            tableView.tableHeaderView = header
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !accountOK { invalidate("Аккаунт изменён. Откройте поиск заново.") }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if handingOff {
            handingOff = false
            if needsReload { needsReload = false; tableView.reloadData() }
            if accountOK, let offset = returnOffset {
                tableView.layoutIfNeeded()
                tableView.setContentOffset(offset, animated: false)
            }
            returnOffset = nil
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !handingOff && (isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true) {
            cancelWork()
        }
    }
    @objc fileprivate func closeModal() { cancelWork(); dismiss(animated: true) }
    @objc private func archiveChanged(_ note: Notification) {
        guard note.userInfo?["journalPurge"] as? Bool == true,
              (note.object as? NSNumber)?.int64Value == accountId else { return }
        DispatchQueue.main.async { [weak self = self] in
            self?.invalidate("Архив очищен. Повторите поиск.")
        }
    }

    private func updateButtons() {
        authorButton.setTitle("Автор: " + (author?.compactDisplayTitle ?? personalAuthorName ?? "любой"), for: .normal)
        dialogButton.setTitle("Диалог: " + (chosenChatName ?? "все диалоги"), for: .normal)
        event.isEnabled = source.selectedSegmentIndex != 0
    }
    @objc private func selectAuthor() {
        guard accountOK else { return }
        input.resignFirstResponder()
        let sheet = UIAlertController(title: "Автор", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Выбрать по имени или @username", style: .default) { [weak self = self] _ in
            guard let self else { return }
            let picker = GoldgramAuthorSearchScreen(context: self.context, chatId: nil, authorSelection: { [weak self = self] peer in
                guard let self else { return }
                self.author = peer; self.personalAuthorId = nil; self.personalAuthorName = nil
                self.updateButtons(); self.filterChanged()
            })
            self.navigationController?.pushViewController(picker, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Любой автор", style: .default) { [weak self = self] _ in
            guard let self else { return }
            self.author = nil; self.personalAuthorId = nil; self.personalAuthorName = nil
            self.updateButtons(); self.filterChanged()
        })
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        sheet.popoverPresentationController?.sourceView = authorButton
        sheet.popoverPresentationController?.sourceRect = authorButton.bounds
        present(sheet, animated: true)
    }
    @objc private func selectDialog() {
        guard accountOK else { return }
        input.resignFirstResponder()
        let picker = GoldgramUnifiedDialogPicker(context: context) { [weak self = self] peer in
            guard let self else { return }
            self.chosenChat = peer?.id
            self.chosenChatName = peer?.compactDisplayTitle
            self.updateButtons(); self.filterChanged()
        }
        navigationController?.pushViewController(picker, animated: true)
    }
    @objc private func resetFilters() {
        input.text = ""; author = nil; personalAuthorId = nil; personalAuthorName = nil
        chosenChat = nil; chosenChatName = nil
        source.selectedSegmentIndex = 2; event.selectedSegmentIndex = 0; period.selectedSegmentIndex = 0
        updateButtons(); filterChanged()
    }
    @objc private func sourceChanged() {
        if source.selectedSegmentIndex != 1 { event.selectedSegmentIndex = 0 }
        updateButtons(); filterChanged()
    }
    @objc private func eventChanged() {
        // Telegram cannot report historical edit/deletion events. Selecting
        // one of these filters intentionally switches to the archive source.
        if event.selectedSegmentIndex != 0 { source.selectedSegmentIndex = 1 }
        updateButtons(); filterChanged()
    }
    @objc private func filterChanged() { invalidate("Фильтры изменены. Нажмите «Найти».") }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { filterChanged() }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { submit() }

    private func cancelWork() {
        generation += 1
        dialogs.set(nil); global.set(nil)
        for task in running.values { task.dispose() }
        running.removeAll(); pending.removeAll()
        localBusy = false; remoteBusy = false; jumping = false
        waitingDialogs = false; globalPage = -1; peerPages.removeAll()
    }
    private func invalidate(_ message: String) {
        cancelWork()
        localRows.removeAll(); remoteRows.removeAll(); order.removeAll()
        titles.removeAll(); allowed.removeAll(); localMore = false
        localStatus = ""; remoteStatus = ""; info.text = message
        tableView.reloadData(); view.setNeedsLayout()
    }

    @objc private func submit() {
        guard accountOK else { invalidate("Аккаунт изменён. Откройте поиск заново."); return }
        input.resignFirstResponder()
        invalidate("Поиск…")
        term = (input.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count <= 200 else { invalidate("Введите не более 200 символов."); return }
        let now = Date()
        let start: Date?
        switch period.selectedSegmentIndex {
        case 1: start = Calendar.current.startOfDay(for: now)
        case 2: start = Calendar.current.date(byAdding: .day, value: -7, to: now)
        case 3: start = Calendar.current.date(byAdding: .day, value: -30, to: now)
        default: start = nil
        }
        since = start.map { Int32(clamping: Int64($0.timeIntervalSince1970)) }
        requestedAuthor = author?.id ?? personalAuthorId; requestedChat = chosenChat; requestedEvent = event.selectedSegmentIndex
        let wantsTelegram = source.selectedSegmentIndex != 1
        let wantsArchive = source.selectedSegmentIndex != 0
        if wantsTelegram && term.isEmpty && requestedAuthor == nil && requestedChat == nil && since == nil {
            invalidate("Для Telegram задайте текст, автора, диалог или период. Для всех записей выберите «Архив»."); return
        }
        localOffset = 0; checked = 0; total = 0; partial = false
        let token = generation
        if wantsTelegram {
            remoteBusy = true; remoteStatus = "Telegram: поиск…"
            if let peer = requestedChat {
                allowed = [peer]; total = 1; pending = [peer]
                if let chosenChatName { titles[peer] = chosenChatName }
                pump(token)
            } else { loadDialogs(token) }
        }
        if wantsArchive { localMore = true; fetchArchive(token) }
        updateStatus()
    }

    private func loadDialogs(_ token: Int) {
        waitingDialogs = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self = self] in
            guard let self, self.generation == token, self.waitingDialogs else { return }
            self.waitingDialogs = false
            self.dialogs.set(nil)
            self.remoteBusy = false; self.partial = true
            self.remoteStatus = "Telegram: не удалось загрузить диалоги"
            self.rebuild(); self.updateStatus()
        }
        let root = context.engine.messages.chatList(group: .root, count: 1000) |> filter { !$0.isLoading } |> take(1)
        let archive = context.engine.messages.chatList(group: .archive, count: 1000) |> filter { !$0.isLoading } |> take(1)
        dialogs.set((combineLatest(root, archive) |> deliverOnMainQueue).start(next: { [weak self = self] a, b in
            guard let self, self.generation == token, self.accountOK, self.waitingDialogs else { return }
            self.waitingDialogs = false
            self.partial = a.hasEarlier || a.hasLater || b.hasEarlier || b.hasLater ||
                a.items.count >= 1000 || b.items.count >= 1000
            for item in a.items + b.items {
                guard case let .chatList(id) = item.id, let peer = item.renderedPeer.peer,
                      GoldgramUnifiedIdentity.sources(id) != nil else { continue }
                if self.allowed.insert(id).inserted { self.pending.append(id) }
                self.titles[id] = peer.compactDisplayTitle
            }
            self.total = self.pending.count
            if self.requestedAuthor == nil && !self.term.isEmpty {
                self.pending.removeAll()
                self.scanGlobal(page: 0, state: nil, token: token)
            } else { self.pump(token) }
        }))
    }
    private func collect(_ raw: [EngineMessage], token: Int) {
        guard generation == token, accountOK else { return }
        for message in raw {
            guard message.id.namespace == Namespaces.Message.Cloud, allowed.contains(message.id.peerId),
                  requestedAuthor == nil || message.author?.id == requestedAuthor,
                  since == nil || message.timestamp >= (since ?? 0) else { continue }
            if remoteRows.count >= maxResults && remoteRows[message.id] == nil { partial = true; break }
            remoteRows[message.id] = message
        }
        rebuild()
    }
    private func scanGlobal(page: Int, state: SearchMessagesState?, token: Int) {
        guard generation == token, accountOK else { return }
        globalPage = page
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self = self] in
            guard let self, self.generation == token, self.remoteBusy, self.globalPage == page else { return }
            self.globalPage = -1
            self.global.set(nil)
            self.remoteBusy = false; self.partial = true
            self.remoteStatus = "Telegram: \(self.remoteRows.count) совпадений · тайм-аут"
            self.rebuild(); self.updateStatus()
        }
        let location: SearchMessagesLocation = .general(scope: .everywhere, groupId: nil, tags: nil,
            minDate: since, maxDate: nil, folderId: nil, communityId: nil)
        let signal = context.engine.messages.searchMessages(location: location, query: term, state: state, limit: 100)
            |> take(1) |> deliverOnMainQueue
        global.set(signal.start(next: { [weak self = self] result, nextState in
            DispatchQueue.main.async { [weak self = self] in
                guard let self, self.generation == token, self.accountOK,
                      self.remoteBusy, self.globalPage == page else { return }
                self.globalPage = -1
                self.collect(result.messages.map { EngineMessage($0) }, token: token)
                self.remoteStatus = "Telegram: \(self.remoteRows.count) совпадений · поиск…"
                self.updateStatus()
                if result.completed || page + 1 >= 10 || state == nextState || self.remoteRows.count >= self.maxResults {
                    if !result.completed { self.partial = true }
                    self.remoteBusy = false
                    self.remoteStatus = "Telegram: \(self.remoteRows.count) совпадений"
                    self.updateStatus()
                } else { self.scanGlobal(page: page + 1, state: nextState, token: token) }
            }
        }))
    }
    private func pump(_ token: Int) {
        guard generation == token, accountOK else { return }
        if remoteRows.count >= maxResults { pending.removeAll(); partial = true }
        while running.count < 2 && !pending.isEmpty {
            let peer = pending.removeFirst()
            let disposable = MetaDisposable()
            running[peer] = disposable
            scanPeer(peer, page: 0, state: nil, token: token, disposable: disposable)
        }
        if pending.isEmpty && running.isEmpty {
            remoteBusy = false
            remoteStatus = "Telegram: \(remoteRows.count) совпадений, \(checked)/\(total) диалогов"
        } else { remoteStatus = "Telegram: \(remoteRows.count), проверено \(checked)/\(total)" }
        updateStatus()
    }
    private func scanPeer(_ peer: EnginePeer.Id, page: Int, state: SearchMessagesState?,
                          token: Int, disposable: MetaDisposable) {
        guard generation == token, accountOK else { return }
        peerPages[peer] = page
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self = self] in
            guard let self, self.generation == token,
                  self.peerPages[peer] == page, self.running[peer] === disposable else { return }
            self.peerPages.removeValue(forKey: peer)
            self.running.removeValue(forKey: peer)?.dispose()
            self.partial = true
            self.checked += 1; self.pump(token)
        }
        let location: SearchMessagesLocation = .peer(peerId: peer, fromId: requestedAuthor, tags: nil,
            reactions: nil, threadId: nil, minDate: since, maxDate: nil)
        let signal = context.engine.messages.searchMessages(location: location, query: term, state: state, limit: 100)
            |> take(1) |> deliverOnMainQueue
        disposable.set(signal.start(next: { [weak self = self] result, nextState in
            DispatchQueue.main.async { [weak self = self] in
                guard let self, self.generation == token, self.accountOK,
                      self.running[peer] === disposable, self.peerPages[peer] == page else { return }
                self.peerPages.removeValue(forKey: peer)
                self.collect(result.messages.map { EngineMessage($0) }, token: token)
                if result.completed || page + 1 >= 10 || state == nextState || self.remoteRows.count >= self.maxResults {
                    if !result.completed { self.partial = true }
                    self.running.removeValue(forKey: peer)?.dispose()
                    self.checked += 1; self.pump(token)
                } else { self.scanPeer(peer, page: page + 1, state: nextState, token: token, disposable: disposable) }
            }
        }))
    }

    private func fetchArchive(_ token: Int) {
        guard generation == token, accountOK, localMore, !localBusy else { return }
        guard localOffset <= 5000 else { localMore = false; updateStatus(); rebuild(); return }
        localBusy = true; localStatus = "Архив: поиск…"
        var request: [String: Any] = ["accountId": NSNumber(value: accountId), "needle": term,
            "event": NSNumber(value: requestedEvent), "since": NSNumber(value: Int64(since ?? 0) * 1000),
            "offset": NSNumber(value: localOffset)]
        if let peer = requestedChat {
            guard let sources = GoldgramUnifiedIdentity.sources(peer) else {
                localBusy = false; localMore = false; localStatus = "Архив: диалог недоступен"; updateStatus(); return
            }
            request["sources"] = sources
        }
        if let author = requestedAuthor {
            request["authorKind"] = NSNumber(value: Int32(0))
            request["authorId"] = NSNumber(value: author.id._internalGetInt64Value())
        }
        goldgramUnifiedCall("goldgram_unified_search_v1", request as NSDictionary) { [weak self = self] answer in
            guard let self, self.generation == token, self.accountOK else { return }
            self.localBusy = false
            guard answer["status"] as? String == "ok" else {
                self.localMore = false
                self.localStatus = answer["status"] as? String == "no_archive" ? "Архив ещё не создан" : "Архив недоступен"
                self.rebuild(); self.updateStatus(); return
            }
            let rows = answer["items"] as? [[String: Any]] ?? []
            self.localOffset += rows.count
            self.localMore = (answer["hasMore"] as? Bool ?? false) && self.localOffset <= 5000 && !rows.isEmpty
            for row in rows {
                guard let id = GoldgramUnifiedIdentity.message(row),
                      self.requestedChat == nil || id.peerId == self.requestedChat else { continue }
                self.localRows[id] = row
            }
            self.localStatus = "Архив: \(self.localRows.count) совпадений" + (self.localMore ? " · есть ещё" : "")
            self.rebuild(); self.updateStatus()
            let identities = rows.map { row -> [String: Any] in
                var value: [String: Any] = [:]
                for key in ["peerKind", "peerId", "messageId", "senderKind", "senderId", "sentAt"] { value[key] = row[key] }
                return value
            }
            if !identities.isEmpty {
                goldgramUnifiedCall("goldgram_unified_metadata_v1",
                    ["accountId": NSNumber(value: self.accountId), "items": identities]) { [weak self = self] result in
                    guard let self, self.generation == token, self.accountOK,
                          result["status"] as? String == "ok" else { return }
                    for extra in result["items"] as? [[String: Any]] ?? [] {
                        guard let id = GoldgramUnifiedIdentity.message(extra), var row = self.localRows[id] else { continue }
                        for key in ["peerName", "senderName"] { if let value = extra[key] { row[key] = value } }
                        self.localRows[id] = row
                    }
                    self.rebuild()
                }
            }
        }
    }

    private func timestamp(_ id: EngineMessage.Id) -> Int64 {
        if let message = remoteRows[id] { return Int64(message.timestamp) * 1000 }
        return (localRows[id]?["sentAt"] as? NSNumber)?.int64Value ?? 0
    }
    private func rebuild() {
        guard accountOK else { invalidate("Аккаунт изменён. Откройте поиск заново."); return }
        order = Array(Set(remoteRows.keys).union(localRows.keys))
        order.sort { a, b in
            let x = timestamp(a), y = timestamp(b)
            if x != y { return x > y }
            if a.peerId.toInt64() != b.peerId.toInt64() { return a.peerId.toInt64() < b.peerId.toInt64() }
            return a.id > b.id
        }
        if handingOff { needsReload = true } else { tableView.reloadData() }
    }
    private func updateStatus() {
        let text = [remoteStatus, localStatus].filter { !$0.isEmpty }.joined(separator: "\n")
        let warning = partial ? "\nЛимит страниц/диалогов или сетевой сбой: выдача неполная." : ""
        let network = remoteStatus.isEmpty || remoteBusy ? "" : "\nTelegramEngine может использовать локальный индекс при сетевых сбоях; выдача не гарантирует доступность сообщения на сервере."
        info.text = "\(text)\nУникальных результатов: \(order.count)" + warning + network
        view.setNeedsLayout()
    }
    private func name(_ id: EngineMessage.Id) -> String {
        localRows[id]?["peerName"] as? String ?? titles[id.peerId] ??
            remoteRows[id]?.enginePeers[id.peerId]?.compactDisplayTitle ?? "Диалог #\(id.peerId.id._internalGetInt64Value())"
    }
    private func archivedText(_ row: [String: Any]) -> String {
        (row["matchedText"] as? String) ?? (row["originalText"] as? String) ??
            (row["latestText"] as? String) ?? "Содержимое не получено"
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        accountOK ? max(1, order.count + (localMore ? 1 : 0)) : 1
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 2; cell.detailTextLabel?.numberOfLines = 6
        guard accountOK else { cell.textLabel?.text = "Аккаунт изменён"; return cell }
        if order.indices.contains(indexPath.row) {
            let id = order[indexPath.row]
            let remote = remoteRows[id], local = localRows[id]
            let mark = remote != nil && local != nil ? "Telegram + архив" : remote != nil ? "Telegram" : "Архив"
            let date = timestamp(id)
            let time = date > 0 ? DateFormatter.localizedString(from: Date(timeIntervalSince1970: Double(date) / 1000), dateStyle: .short, timeStyle: .short) : "Дата отправки неизвестна"
            cell.textLabel?.text = "\(name(id)) · \(mark)"
            let authorName = remote?.author?.compactDisplayTitle ?? local?["senderName"] as? String ?? "Автор неизвестен"
            var details = [authorName + " · " + time]
            if let remote { details.append(String(remote.text.prefix(220))) }
            if let local {
                let text = archivedText(local)
                if remote == nil || text != remote?.text { details.append("Архив: " + String(text.prefix(220))) }
                if (local["deleted"] as? NSNumber)?.boolValue == true { details.append("Удалено") }
                else if (local["edited"] as? NSNumber)?.boolValue == true { details.append("Изменено") }
            }
            cell.detailTextLabel?.text = details.joined(separator: "\n")
            cell.accessoryType = .disclosureIndicator
        } else if localMore {
            cell.textLabel?.text = localBusy ? "Загрузка архива…" : "Загрузить ещё из архива"
        } else {
            cell.textLabel?.text = remoteBusy || localBusy ? "Поиск продолжается…" : "Нет результатов"
            cell.selectionStyle = .none
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard accountOK else { return }
        guard order.indices.contains(indexPath.row) else {
            if localMore { fetchArchive(generation); updateStatus() }
            return
        }
        let id = order[indexPath.row]
        if remoteRows[id] != nil { jump(id) }
        else if let row = localRows[id] { showArchive(id, row: row) }
    }
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        guard accountOK, order.indices.contains(indexPath.row) else { return nil }
        let id = order[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self = self] _ in
            guard let self, self.accountOK else { return UIMenu(children: []) }
            var actions: [UIMenuElement] = []
            if self.localRows[id] != nil {
                actions.append(UIAction(title: "Сохранённая версия", image: UIImage(systemName: "doc.text")) { [weak self = self] _ in
                    guard let self, self.accountOK, let row = self.localRows[id] else { return }
                    self.showArchive(id, row: row)
                })
            }
            actions.append(UIAction(title: "В личное избранное", image: UIImage(systemName: "bookmark")) { [weak self = self] _ in
                self?.bookmark(id)
            })
            if self.personalContact(id) != nil {
                actions.append(UIAction(title: "Личная карточка автора", image: UIImage(systemName: "person.crop.rectangle")) { [weak self = self] _ in
                    guard let self, self.accountOK, let contact = self.personalContact(id) else { return }
                    self.navigationController?.pushViewController(GoldgramPersonalCard(context: self.context,
                        id: contact.0, displayTitle: contact.1), animated: true)
                })
            }
            return UIMenu(children: actions)
        }
    }
    @objc private func openFavorites() {
        guard accountOK else { return }
        navigationController?.pushViewController(GoldgramPersonalList(context: context), animated: true)
    }
    @objc private func openPersonalContacts() {
        guard accountOK else { return }
        navigationController?.pushViewController(GoldgramPersonalContacts(context: context), animated: true)
    }
    private func personalContact(_ id: EngineMessage.Id) -> (Int64, String)? {
        if let author = remoteRows[id]?.author, case .user = author {
            return (author.id.id._internalGetInt64Value(), author.compactDisplayTitle)
        }
        if let row = localRows[id], (row["senderKind"] as? NSNumber)?.int32Value == 0,
           let raw = (row["senderId"] as? NSNumber)?.int64Value, raw > 0 {
            return (raw, row["senderName"] as? String ?? "Автор #\(raw)")
        }
        return nil
    }
    private func bookmark(_ id: EngineMessage.Id) {
        guard accountOK, remoteRows[id] != nil || localRows[id] != nil,
              id.namespace == Namespaces.Message.Cloud,
              let sources = GoldgramUnifiedIdentity.sources(id.peerId),
              let scope = sources.first, let kind = (scope["peerKind"] as? NSNumber)?.int32Value,
              let peer = (scope["peerId"] as? NSNumber)?.int64Value else { return }
        let date = timestamp(id)
        let value = GoldgramPersonalBookmark(peerKind: kind, peerId: peer, messageId: id.id,
            authorId: personalContact(id)?.0, title: String(name(id).prefix(180)),
            date: date, archive: localRows[id] != nil, folder: "", tags: [], note: "")
        GoldgramPersonalUI.editBookmark(self, context: context, value: value) {}
    }

    private func showArchive(_ id: EngineMessage.Id, row: [String: Any]) {
        guard accountOK, localRows[id] != nil else { return }
        let original = row["originalText"] as? String
        let latest = row["latestText"] as? String
        let matched = row["matchedText"] as? String
        var parts = [original.map { "Оригинал:\n" + $0 } ?? "Оригинал не получен"]
        if let matched, matched != original, matched != latest { parts.append("Найденная версия:\n" + matched) }
        if let latest, latest != original { parts.append("Последняя сохранённая версия:\n" + latest) }
        let alert = UIAlertController(title: name(id), message: parts.joined(separator: "\n\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Открыть в чате", style: .default) { [weak self = self] _ in
            guard let self, self.accountOK, self.localRows[id] != nil, !self.jumping else { return }
            self.jumping = true
            let token = self.generation
            goldgramUnifiedCall("goldgram_unified_metadata_v1",
                ["accountId": NSNumber(value: self.accountId), "action": "prepare_jump", "items": [row]]) { [weak self = self] answer in
                guard let self, self.generation == token, self.accountOK else { return }
                self.jumping = false
                if answer["status"] as? String == "ok" { self.jump(id) }
                else { self.showError("Сообщение недоступно в чате. Сохранённая версия остаётся в архиве.") }
            }
        })
        alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
        present(alert, animated: true)
    }
    private func showError(_ text: String) {
        let alert = UIAlertController(title: "Goldgram", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
    private func jump(_ id: EngineMessage.Id) {
        guard accountOK, !handingOff, !jumping, let navigation = navigationController,
              navigation.topViewController === self, let presenter = navigation.presentingViewController,
              let jump = GoldgramAuthorSearchBridge.nativeJump else {
            showError("Не удалось открыть точное сообщение."); return
        }
        input.resignFirstResponder()
        returnOffset = tableView.contentOffset; handingOff = true
        let snapshot = navigation.view.snapshotView(afterScreenUpdates: false)
        presenter.dismiss(animated: true) { [weak self = self] in
            guard let self else { return }
            if !jump(self.context, id, navigation, presenter, snapshot) {
                guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
                    self.handingOff = false; return
                }
                presenter.present(navigation, animated: false) { [weak self = self] in
                    self?.showError("Не удалось открыть сообщение. Проверьте доступность чата.")
                }
            }
        }
    }
}

// BEGIN GOLDGRAM_PERSONAL_MODEL_V1
private struct GoldgramPersonalBookmark: Codable, Equatable {
    var peerKind: Int32
    var peerId: Int64
    var messageId: Int32
    var authorId: Int64?
    var title: String
    var date: Int64
    var archive: Bool
    var folder: String
    var tags: [String]
    var note: String
    var key: String { "\(peerKind >= 2 ? 2 : peerKind):\(peerId):\(messageId)" }
    var valid: Bool {
        (0...3).contains(peerKind) && peerId > 0 && messageId > 0 &&
        (authorId == nil || (authorId ?? 0) > 0) && title.count <= 180 &&
        folder.count <= 80 && tags.count <= 12 && tags.allSatisfy { $0.count <= 40 } &&
        note.count <= 1000
    }
}
private struct GoldgramPersonalContact: Codable, Equatable {
    var id: Int64
    var title: String
    var alias: String
    var note: String
    var valid: Bool { id > 0 && title.count <= 180 && alias.count <= 80 && note.count <= 2000 }
}
private struct GoldgramPersonalData: Codable {
    let version: Int
    let account: Int64
    var bookmarks: [GoldgramPersonalBookmark]
    var contacts: [GoldgramPersonalContact]
    init(account: Int64) { version = 1; self.account = account; bookmarks = []; contacts = [] }
    func validate(account: Int64) -> Bool {
        version == 1 && self.account == account && account > 0 &&
        bookmarks.count <= 2000 && contacts.count <= 1000 &&
        bookmarks.allSatisfy { $0.valid } && contacts.allSatisfy { $0.valid } &&
        Set(bookmarks.map { $0.key }).count == bookmarks.count &&
        Set(contacts.map { $0.id }).count == contacts.count
    }
    mutating func put(_ bookmark: GoldgramPersonalBookmark) -> Bool {
        guard bookmark.valid else { return false }
        if let i = bookmarks.firstIndex(where: { $0.key == bookmark.key }) {
            bookmarks[i] = bookmark
        } else {
            guard bookmarks.count < 2000 else { return false }
            bookmarks.insert(bookmark, at: 0)
        }
        return true
    }
    mutating func putContact(_ contact: GoldgramPersonalContact) -> Bool {
        guard contact.valid else { return false }
        if let i = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[i] = contact
        } else {
            guard contacts.count < 1000 else { return false }
            contacts.append(contact)
        }
        return true
    }
}
private enum GoldgramPersonalStore {
    enum Failure: Error { case invalid, tooLarge }
    static func read(_ url: URL, account: Int64) throws -> GoldgramPersonalData {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 16 * 1024 * 1024 else { throw Failure.tooLarge }
            let bytes = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(GoldgramPersonalData.self, from: bytes)
            guard value.validate(account: account) else { throw Failure.invalid }
            return value
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return GoldgramPersonalData(account: account)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return GoldgramPersonalData(account: account)
        }
    }
    static func write(_ value: GoldgramPersonalData, to url: URL, account: Int64) throws {
        guard value.validate(account: account) else { throw Failure.invalid }
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 16 * 1024 * 1024 else { throw Failure.tooLarge }
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try directory.setResourceValues(attributes)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
    }
    static func url(account: Int64) throws -> URL {
        guard account > 0 else { throw Failure.invalid }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: false)
        return base.appendingPathComponent("Goldgram/Accounts/\(account)/Personal", isDirectory: true)
            .appendingPathComponent("references-v1.json")
    }
}
// END GOLDGRAM_PERSONAL_MODEL_V1


private enum GoldgramPersonalUI {
    static func error(_ owner: UIViewController, _ text: String = "Не удалось сохранить личные данные. Проверьте доступность хранилища.") {
        let alert = UIAlertController(title: "Goldgram", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        owner.present(alert, animated: true)
    }
    static func account(_ context: AccountContext) -> Int64 { context.account.peerId.id._internalGetInt64Value() }
    static func read(_ context: AccountContext) throws -> GoldgramPersonalData {
        guard GoldgramAuthorSearchBridge.isCurrentAccount(context) else { throw GoldgramPersonalStore.Failure.invalid }
        let account = account(context)
        return try GoldgramPersonalStore.read(GoldgramPersonalStore.url(account: account), account: account)
    }
    static func change(_ context: AccountContext, _ modify: (inout GoldgramPersonalData) -> Bool) throws {
        guard GoldgramAuthorSearchBridge.isCurrentAccount(context) else { throw GoldgramPersonalStore.Failure.invalid }
        var data = try read(context)
        guard modify(&data), GoldgramAuthorSearchBridge.isCurrentAccount(context) else { throw GoldgramPersonalStore.Failure.invalid }
        let account = account(context)
        try GoldgramPersonalStore.write(data, to: GoldgramPersonalStore.url(account: account), account: account)
    }
    static func editBookmark(_ owner: UIViewController, context: AccountContext, value: GoldgramPersonalBookmark,
                             completion: @escaping () -> Void) {
        guard GoldgramAuthorSearchBridge.isCurrentAccount(context) else { return }
        let saved: GoldgramPersonalBookmark
        do { saved = try read(context).bookmarks.first(where: { $0.key == value.key }) ?? value }
        catch { error(owner); return }
        let alert = UIAlertController(title: "Личная закладка", message: "Только на этом устройстве. Сохраняется ссылка, а не копия сообщения.", preferredStyle: .alert)
        alert.addTextField { field in field.placeholder = "Папка (например, Работа)"; field.text = saved.folder }
        alert.addTextField { field in field.placeholder = "Теги через запятую"; field.text = saved.tags.joined(separator: ", ") }
        alert.addTextField { field in field.placeholder = "Моя заметка"; field.text = saved.note }
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak owner, weak alert] _ in
            guard let owner, let fields = alert?.textFields, fields.count == 3,
                  GoldgramAuthorSearchBridge.isCurrentAccount(context) else { return }
            var updated = saved
            updated.archive = saved.archive || value.archive
            updated.authorId = value.authorId ?? saved.authorId
            updated.folder = String((fields[0].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            var seen = Set<String>()
            updated.tags = Array((fields[1].text ?? "").split(separator: ",").map {
                String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(12))
            updated.note = String((fields[2].text ?? "").prefix(1000))
            do { try change(context) { $0.put(updated) }; completion() }
            catch { error(owner) }
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        owner.present(alert, animated: true)
    }
}

private final class GoldgramPersonalList: UITableViewController, UISearchBarDelegate {
    private let context: AccountContext
    private let contactId: Int64?
    private let search = UISearchBar()
    private var rows: [GoldgramPersonalBookmark] = []
    private var folders: [String] = []
    private var all: [GoldgramPersonalBookmark] = []
    private var folder: String?
    private var failure = false
    private var handingOff = false
    private var offset: CGPoint?
    private var operation = 0

    init(context: AccountContext, contactId: Int64? = nil) {
        self.context = context; self.contactId = contactId
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { return nil }
    private var accountOK: Bool { GoldgramAuthorSearchBridge.isCurrentAccount(context) }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Личное избранное"
        search.placeholder = "Папка, тег, название или заметка"
        search.delegate = self
        search.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 54)
        search.autoresizingMask = [.flexibleWidth]
        tableView.tableHeaderView = search
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Папки", style: .plain, target: self, action: #selector(chooseFolder))
        NotificationCenter.default.addObserver(self, selector: #selector(purge(_:)),
            name: Notification.Name("GoldgramArchiveChanged"), object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func purge(_ note: Notification) {
        guard note.userInfo?["journalPurge"] as? Bool == true,
              (note.object as? NSNumber)?.int64Value == GoldgramPersonalUI.account(context) else { return }
        DispatchQueue.main.async { [weak self = self] in
            guard let self else { return }
            self.operation += 1
            if self.presentedViewController is UIAlertController { self.dismiss(animated: false) }
            self.reload()
        }
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reload() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if handingOff {
            handingOff = false
            if accountOK, let offset { tableView.layoutIfNeeded(); tableView.setContentOffset(offset, animated: false) }
            offset = nil
        }
    }
    private func reload() {
        do {
            all = try GoldgramPersonalUI.read(context).bookmarks.filter { contactId == nil || $0.authorId == contactId }
            folders = Array(Set(all.map { $0.folder }.filter { !$0.isEmpty })).sorted()
            failure = false
        } catch { all = []; folders = []; failure = true }
        applyFilter()
    }
    private func applyFilter() {
        let q = (search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        rows = all.filter { row in
            (folder == nil || row.folder == folder) && (q.isEmpty ||
                ([row.title,row.folder,row.note] + row.tags).joined(separator: " ").range(of: q,
                    options: [.caseInsensitive,.diacriticInsensitive]) != nil)
        }
        tableView.reloadData()
    }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { applyFilter() }
    @objc private func chooseFolder() {
        guard accountOK else { return }
        let alert = UIAlertController(title: "Папки", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Все папки", style: .default) { [weak self = self] _ in self?.folder = nil; self?.applyFilter() })
        alert.addAction(UIAlertAction(title: "Без папки", style: .default) { [weak self = self] _ in self?.folder = ""; self?.applyFilter() })
        for name in folders.prefix(80) {
            alert.addAction(UIAlertAction(title: name, style: .default) { [weak self = self] _ in self?.folder = name; self?.applyFilter() })
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { accountOK ? max(1, rows.count) : 1 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard accountOK, rows.indices.contains(indexPath.row) else {
            cell.textLabel?.text = !accountOK ? "Аккаунт изменён" : failure ? "Личные данные недоступны" : "Закладок пока нет"
            cell.selectionStyle = .none; return cell
        }
        let row = rows[indexPath.row]
        cell.textLabel?.text = row.title
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.numberOfLines = 4
        let time = row.date > 0 ? DateFormatter.localizedString(from: Date(timeIntervalSince1970: Double(row.date) / 1000), dateStyle: .short, timeStyle: .short) : "Дата неизвестна"
        cell.detailTextLabel?.text = [row.archive ? "Архив · \(time)" : "Telegram · \(time)", row.folder,
            row.tags.map { "#" + $0 }.joined(separator: " "), row.note].filter { !$0.isEmpty }.joined(separator: "\n")
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard accountOK, rows.indices.contains(indexPath.row) else { return }
        open(rows[indexPath.row])
    }
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        guard accountOK, rows.indices.contains(indexPath.row) else { return nil }
        let row = rows[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self = self] _ in
            UIMenu(children: [
                UIAction(title: "Изменить папку, теги и заметку", image: UIImage(systemName: "pencil")) { [weak self = self] _ in
                    guard let self, self.accountOK else { return }
                    GoldgramPersonalUI.editBookmark(self, context: self.context, value: row) { [weak self = self] in self?.reload() }
                },
                UIAction(title: "Удалить закладку", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self = self] _ in
                    guard let self, self.accountOK else { return }
                    do { try GoldgramPersonalUI.change(self.context) { data in
                        data.bookmarks.removeAll { $0.key == row.key }; return true
                    }; self.reload() } catch { GoldgramPersonalUI.error(self) }
                }
            ])
        }
    }
    private func open(_ row: GoldgramPersonalBookmark) {
        let identity: [String: Any] = ["peerKind": NSNumber(value: row.peerKind), "peerId": NSNumber(value: row.peerId),
            "messageId": NSNumber(value: row.messageId)]
        guard let id = GoldgramUnifiedIdentity.message(identity) else { return }
        operation += 1
        let token = operation
        let account = NSNumber(value: GoldgramPersonalUI.account(context))
        if row.archive {
            guard let sources = GoldgramUnifiedIdentity.sources(id.peerId) else { return }
            goldgramUnifiedCall("goldgram_unified_search_v1", ["accountId": account, "needle": "", "event": 0, "since": 0,
                "offset": 0, "sources": sources, "messageId": NSNumber(value: row.messageId)]) { [weak self = self] answer in
                guard let self, self.accountOK, self.operation == token, self.viewIfLoaded?.window != nil else { return }
                guard answer["status"] as? String == "ok", let matches = answer["items"] as? [[String: Any]],
                      let record = matches.first(where: { GoldgramUnifiedIdentity.message($0) == id }) else {
                    GoldgramPersonalUI.error(self, "Сохранённая запись недоступна или очищена. Закладка не содержит копии текста."); return
                }
                var request = identity
                request["accountId"] = account
                request["peerKind"] = record["peerKind"]
                goldgramUnifiedCall("goldgram_personal_revisions_v1", request as NSDictionary) { [weak self = self] result in
                    guard let self, self.accountOK, self.operation == token, self.viewIfLoaded?.window != nil else { return }
                    guard result["status"] as? String == "ok", let current = result["record"] as? [String: Any] else {
                        GoldgramPersonalUI.error(self, "Архив изменился. Откройте закладку ещё раз."); return
                    }
                    self.showSaved(row, id: id, record: current, revisions: result["items"] as? [[String: Any]] ?? [])
                }
            }
        } else {
            prepareJump(id, record: identity)
        }
    }
    private func showSaved(_ row: GoldgramPersonalBookmark, id: EngineMessage.Id, record: [String: Any], revisions: [[String: Any]]) {
        guard accountOK else { return }
        let original = record["originalText"] as? String
        var lines = [original.map { "Оригинал:\n" + $0 } ?? "Оригинал не получен"]
        for revision in revisions.prefix(250) {
            guard let body = revision["text"] as? String, body != "[Содержимое не было получено]" else { continue }
            let index = (revision["index"] as? NSNumber)?.intValue ?? 0
            if index == 0 && body == original { continue }
            lines.append((index == 0 ? "Первая сохранённая версия" : "Редакция \(index)") + ":\n" + body)
        }
        if revisions.isEmpty, let latest = record["latestText"] as? String, latest != original { lines.append("Последняя версия:\n" + latest) }
        let joined = lines.joined(separator: "\n\n")
        let text = String(joined.prefix(8000)) + (joined.count > 8000 ? "\n\n… Полная история доступна в архиве Goldgram." : "")
        let alert = UIAlertController(title: row.title, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Открыть в чате", style: .default) { [weak self = self] _ in self?.prepareJump(id, record: record) })
        alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
        present(alert, animated: true)
    }
    private func prepareJump(_ id: EngineMessage.Id, record: [String: Any]) {
        guard accountOK, !handingOff else { return }
        operation += 1
        let token = operation
        goldgramUnifiedCall("goldgram_unified_metadata_v1", ["accountId": NSNumber(value: GoldgramPersonalUI.account(context)),
            "action": "prepare_jump", "items": [record]]) { [weak self = self] result in
            guard let self, self.accountOK, self.operation == token, self.viewIfLoaded?.window != nil else { return }
            guard result["status"] as? String == "ok" else { GoldgramPersonalUI.error(self, "Сообщение недоступно в чате."); return }
            self.jump(id)
        }
    }
    private func jump(_ id: EngineMessage.Id) {
        guard accountOK, !handingOff, let navigation = navigationController, navigation.topViewController === self,
              let presenter = navigation.presentingViewController, let jump = GoldgramAuthorSearchBridge.nativeJump else {
            GoldgramPersonalUI.error(self, "Не удалось открыть точное сообщение."); return
        }
        search.resignFirstResponder()
        offset = tableView.contentOffset; handingOff = true
        let snapshot = navigation.view.snapshotView(afterScreenUpdates: false)
        presenter.dismiss(animated: true) { [weak self = self] in
            guard let self else { return }
            if !jump(self.context, id, navigation, presenter, snapshot) {
                guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { self.handingOff = false; return }
                presenter.present(navigation, animated: false) { [weak self = self] in
                    if let self { GoldgramPersonalUI.error(self, "Не удалось открыть сообщение.") }
                }
            }
        }
    }
}

private final class GoldgramPersonalContacts: UITableViewController {
    private let context: AccountContext
    private var rows: [GoldgramPersonalContact] = []
    init(context: AccountContext) { self.context = context; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Личные карточки"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(choose))
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rows = ((try? GoldgramPersonalUI.read(context).contacts) ?? []).sorted {
            ($0.alias.isEmpty ? $0.title : $0.alias).localizedCaseInsensitiveCompare($1.alias.isEmpty ? $1.title : $1.alias) == .orderedAscending
        }
        tableView.reloadData()
    }
    @objc private func choose() {
        guard GoldgramAuthorSearchBridge.isCurrentAccount(context) else { return }
        let picker = GoldgramAuthorSearchScreen(context: context, chatId: nil, authorSelection: { [weak self = self] peer in
            guard let self else { return }
            // Wait for the picker pop transition before pushing a UIKit card.
            DispatchQueue.main.async { [weak self = self] in
                guard let self, GoldgramAuthorSearchBridge.isCurrentAccount(self.context) else { return }
                let show = { [weak self = self] in
                    guard let self, GoldgramAuthorSearchBridge.isCurrentAccount(self.context),
                          self.navigationController?.topViewController === self else { return }
                    self.open(peer.id.id._internalGetInt64Value(), title: peer.compactDisplayTitle)
                }
                if let coordinator = self.navigationController?.transitionCoordinator {
                    coordinator.animate(alongsideTransition: nil, completion: { _ in show() })
                } else { show() }
            }
        })
        navigationController?.pushViewController(picker, animated: true)
    }
    private func open(_ id: Int64, title: String) {
        let card = GoldgramPersonalCard(context: context, id: id, displayTitle: title)
        navigationController?.pushViewController(card, animated: true)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        GoldgramAuthorSearchBridge.isCurrentAccount(context) ? max(1, rows.count) : 1
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard GoldgramAuthorSearchBridge.isCurrentAccount(context), rows.indices.contains(indexPath.row) else {
            cell.textLabel?.text = "Выберите контакт через «+»"; cell.selectionStyle = .none; return cell
        }
        let row = rows[indexPath.row]
        cell.textLabel?.text = row.alias.isEmpty ? row.title : row.alias
        cell.detailTextLabel?.text = row.title
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard GoldgramAuthorSearchBridge.isCurrentAccount(context), rows.indices.contains(indexPath.row) else { return }
        open(rows[indexPath.row].id, title: rows[indexPath.row].title)
    }
}

private final class GoldgramPersonalCard: UITableViewController {
    private let context: AccountContext
    private let id: Int64
    private let displayTitle: String
    private var value: GoldgramPersonalContact?
    private var count = 0
    private var available = false
    init(context: AccountContext, id: Int64, displayTitle: String) {
        self.context = context; self.id = id; self.displayTitle = String(displayTitle.prefix(180))
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { return nil }
    private var accountOK: Bool { GoldgramAuthorSearchBridge.isCurrentAccount(context) }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Карточка контакта"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Изменить", style: .plain, target: self, action: #selector(editCard))
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reload() }
    private func reload() {
        do {
            let data = try GoldgramPersonalUI.read(context)
            value = data.contacts.first(where: { $0.id == id }) ??
                GoldgramPersonalContact(id: id, title: displayTitle, alias: "", note: "")
            count = data.bookmarks.filter { $0.authorId == id }.count
            available = true
        } catch { available = false; value = nil; count = 0 }
        tableView.reloadData()
    }
    @objc private func editCard() {
        guard accountOK, available, let value else { return }
        let alert = UIAlertController(title: "Личная карточка", message: "Псевдоним и заметка видны только в Goldgram на этом устройстве.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Личный псевдоним"; $0.text = value.alias }
        alert.addTextField { $0.placeholder = "Заметка"; $0.text = value.note }
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self = self, weak alert] _ in
            guard let self, self.accountOK, let fields = alert?.textFields, fields.count == 2 else { return }
            var updated = value
            updated.alias = String((fields[0].text ?? "").prefix(80))
            updated.note = String((fields[1].text ?? "").prefix(2000))
            do { try GoldgramPersonalUI.change(self.context) { $0.putContact(updated) }; self.reload() }
            catch { GoldgramPersonalUI.error(self) }
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        present(alert, animated: true)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { accountOK && available ? 5 : 1 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard accountOK, available, let value else { cell.textLabel?.text = "Карточка недоступна"; cell.selectionStyle = .none; return cell }
        cell.detailTextLabel?.numberOfLines = 0
        switch indexPath.row {
        case 0: cell.textLabel?.text = value.alias.isEmpty ? value.title : value.alias; cell.detailTextLabel?.text = "Telegram: \(value.title)"
        case 1: cell.textLabel?.text = "Личная заметка"; cell.detailTextLabel?.text = value.note.isEmpty ? "Не заполнена" : value.note
        case 2: cell.textLabel?.text = "Поиск сообщений автора"; cell.accessoryType = .disclosureIndicator
        case 3: cell.textLabel?.text = "Мои закладки (\(count))"; cell.accessoryType = .disclosureIndicator
        default: cell.textLabel?.text = "Удалить личную карточку"; cell.textLabel?.textColor = .systemRed
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard accountOK, available, let value else { return }
        switch indexPath.row {
        case 0, 1: editCard()
        case 2:
            let peer = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(id))
            let search = GoldgramUnifiedSearchScreen(context: context, chatId: nil, initialAuthorId: peer, initialAuthorName: value.title)
            navigationController?.pushViewController(search, animated: true)
        case 3: navigationController?.pushViewController(GoldgramPersonalList(context: context, contactId: id), animated: true)
        default:
            let alert = UIAlertController(title: "Удалить личную карточку?", message: "Закладки и сообщения не изменятся.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self = self] _ in
                guard let self, self.accountOK else { return }
                do { try GoldgramPersonalUI.change(self.context) { data in
                    data.contacts.removeAll { $0.id == self.id }; return true
                }; self.navigationController?.popViewController(animated: true) }
                catch { GoldgramPersonalUI.error(self) }
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            present(alert, animated: true)
        }
    }
}
