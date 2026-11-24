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
import TinyThumbnail
import QuickLook


// BEGIN GOLDGRAM_LAYOUT_MODEL_V1
private struct GoldgramLayoutPreferences: Codable, Equatable {
    static let dashboardIDs = [29, 30, 31, 33, 0, 20, 24, 27, 28, 25, 21, 22, 4, 23]
    static let menuIDs = [100, 101, 102, 103]
    static let key = "Goldgram.LayoutPreferences.v1"
    var dashboardOrder = Self.dashboardIDs
    var dashboardHidden: [Int] = []
    var dashboardPinned: [Int] = []
    var menuOrder = Self.menuIDs
    var menuHidden = [101, 102, 103]

    static func order(_ input: [Int], known: [Int]) -> [Int] {
        var seen = Set<Int>()
        return (input + known).filter { known.contains($0) && seen.insert($0).inserted }
    }

    mutating func normalize() {
        let oldDefault = Self.dashboardIDs.filter { $0 != 33 }
        if dashboardOrder == oldDefault { dashboardOrder = Self.dashboardIDs }
        dashboardOrder = Self.order(dashboardOrder, known: Self.dashboardIDs)
        dashboardHidden = dashboardOrder.filter { dashboardHidden.contains($0) }
        dashboardPinned = dashboardOrder.filter { dashboardPinned.contains($0) && !dashboardHidden.contains($0) }
        menuOrder = Self.order(menuOrder, known: Self.menuIDs)
        menuHidden = menuOrder.filter { menuHidden.contains($0) }
    }

    var visibleDashboard: [Int] {
        return dashboardOrder.filter { !dashboardHidden.contains($0) }
    }
    var visibleMenu: [Int] {
        return menuOrder.filter { !menuHidden.contains($0) }
    }
    var customDashboard: Bool {
        return dashboardOrder != Self.dashboardIDs || !dashboardHidden.isEmpty || !dashboardPinned.isEmpty
    }

    static func load(_ defaults: UserDefaults = .standard) -> Self {
        guard let bytes = defaults.data(forKey: key), bytes.count <= 16384,
              var value = try? JSONDecoder().decode(Self.self, from: bytes) else { return Self() }
        value.normalize()
        return value
    }

    func save(_ defaults: UserDefaults = .standard) {
        var value = self
        value.normalize()
        if let bytes = try? JSONEncoder().encode(value) { defaults.set(bytes, forKey: Self.key) }
    }
}
// END GOLDGRAM_LAYOUT_MODEL_V1


private final class GoldgramLayoutScreen: UITableViewController {
    private var preferences: GoldgramLayoutPreferences

    private static let names: [Int: String] = [
        29: "Расширенный поиск", 30: "Личное избранное", 31: "Карточки контактов", 33: "Единый медиацентр",
        0: "Режим невидимки", 20: "Изменённые", 24: "Удалённые",
        27: "Личные сообщения", 28: "Группы и чаты", 25: "Каналы и комментарии",
        21: "Приватность", 22: "Медиа", 4: "Геопозиция", 23: "Другие функции",
        100: "В личное избранное", 101: "Расширенный поиск в чате",
        102: "Открыть личное избранное", 103: "Карточки контактов"
    ]

    init(preferences: GoldgramLayoutPreferences) {
        self.preferences = preferences
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Панель и меню"
        tableView.allowsSelectionDuringEditing = true
        tableView.setEditing(true, animated: false)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Сброс", style: .plain, target: self, action: #selector(resetLayout))
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? preferences.dashboardOrder.count : preferences.menuOrder.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? "Плитки Goldgram" : "Дополнительные действия меню сообщения"
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return section == 0
            ? "Перетаскивайте строки для изменения порядка. Нажмите на плитку, чтобы скрыть, показать или закрепить её вверху. Счётчики архива и системные настройки остаются доступны."
            : "Перетаскивайте действия и нажимайте для включения или отключения. Обычные пункты Telegram и ограничения защищённых сообщений не изменяются."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let dashboard = indexPath.section == 0
        let id = dashboard ? preferences.dashboardOrder[indexPath.row] : preferences.menuOrder[indexPath.row]
        let hidden = dashboard ? preferences.dashboardHidden.contains(id) : preferences.menuHidden.contains(id)
        let pinned = dashboard && preferences.dashboardPinned.contains(id)
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = Self.names[id] ?? String(id)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = hidden ? "Скрыто" : (pinned ? "Закреплено" : "Показано")
        cell.detailTextLabel?.textColor = hidden ? .secondaryLabel : .systemTeal
        cell.imageView?.image = UIImage(systemName: hidden ? "eye.slash" : (pinned ? "pin.fill" : "checkmark.circle"))
        cell.imageView?.tintColor = hidden ? .secondaryLabel : .systemTeal
        cell.showsReorderControl = true
        return cell
    }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }
    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        return sourceIndexPath.section == proposedDestinationIndexPath.section ? proposedDestinationIndexPath : sourceIndexPath
    }
    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath.section == destinationIndexPath.section else { return }
        if sourceIndexPath.section == 0 {
            let id = preferences.dashboardOrder.remove(at: sourceIndexPath.row)
            preferences.dashboardOrder.insert(id, at: destinationIndexPath.row)
        } else {
            let id = preferences.menuOrder.remove(at: sourceIndexPath.row)
            preferences.menuOrder.insert(id, at: destinationIndexPath.row)
        }
        preferences.save()
    }

    private func change(_ f: (inout GoldgramLayoutPreferences) -> Void) {
        f(&preferences)
        preferences.normalize()
        preferences.save()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let dashboard = indexPath.section == 0
        let id = dashboard ? preferences.dashboardOrder[indexPath.row] : preferences.menuOrder[indexPath.row]
        let hidden = dashboard ? preferences.dashboardHidden.contains(id) : preferences.menuHidden.contains(id)
        if !dashboard {
            change { value in
                if hidden { value.menuHidden.removeAll { $0 == id } }
                else { value.menuHidden.append(id) }
            }
            return
        }
        let pinned = preferences.dashboardPinned.contains(id)
        let alert = UIAlertController(title: Self.names[id], message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: hidden ? "Показать" : "Скрыть", style: .default) { [weak self] _ in
            self?.change { value in
                if hidden { value.dashboardHidden.removeAll { $0 == id } }
                else { value.dashboardHidden.append(id); value.dashboardPinned.removeAll { $0 == id } }
            }
        })
        if !hidden {
            alert.addAction(UIAlertAction(title: pinned ? "Открепить" : "Закрепить вверху", style: .default) { [weak self] _ in
                self?.change { value in
                    if pinned { value.dashboardPinned.removeAll { $0 == id } }
                    else { value.dashboardPinned.append(id) }
                }
            })
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func resetLayout() {
        let alert = UIAlertController(title: "Восстановить исходный вид?", message: "Настройки расположения плиток и дополнительных действий будут сброшены. Архив и избранное не затрагиваются.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Сбросить", style: .destructive) { [weak self] _ in
            self?.change { $0 = GoldgramLayoutPreferences() }
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        present(alert, animated: true)
    }
}

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

    // Layout preferences are installation-local UI choices, never account content.
    @objc(dashboardLayout)
    public static func dashboardLayout() -> NSDictionary? {
        let value = GoldgramLayoutPreferences.load()
        guard value.customDashboard else { return nil }
        return ["order": value.visibleDashboard.map { NSNumber(value: $0) },
                "pinned": value.dashboardPinned.map { NSNumber(value: $0) }] as NSDictionary
    }

    @objc(presentMediaCenterFromController:)
    public static func presentMediaCenterFromController(_ controller: UIViewController) {
        guard let context = primaryContext, isCurrentAccount(context) else { return }
        presentPersonal(GoldgramMediaCenter(context: context), from: controller)
    }

    @objc(presentLayoutFromController:)
    public static func presentLayoutFromController(_ controller: UIViewController) {
        presentPersonal(GoldgramLayoutScreen(preferences: .load()), from: controller)
    }

    public static func menuActionIDs() -> [Int] {
        return GoldgramLayoutPreferences.load().visibleMenu
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

    public static func canBookmark(context: AccountContext, message: EngineMessage) -> Bool {
        return isCurrentAccount(context) && message.id.namespace == Namespaces.Message.Cloud &&
            message.id.id > 0 && GoldgramUnifiedIdentity.sources(message.id.peerId) != nil
    }

    public static func addBookmark(from controller: UIViewController, context: AccountContext, message: EngineMessage) {
        guard canBookmark(context: context, message: message),
              let scope = GoldgramUnifiedIdentity.sources(message.id.peerId)?.first,
              let kind = (scope["peerKind"] as? NSNumber)?.int32Value,
              let peer = (scope["peerId"] as? NSNumber)?.int64Value,
              controller.viewIfLoaded?.window != nil, controller.presentedViewController == nil else { return }
        let authorId: Int64?
        if let author = message.author, case .user = author { authorId = author.id.id._internalGetInt64Value() }
        else { authorId = nil }
        let name = message.enginePeers[message.id.peerId]?.compactDisplayTitle ?? "Диалог #\(peer)"
        let value = GoldgramPersonalBookmark(peerKind: kind, peerId: peer, messageId: message.id.id,
            authorId: authorId, title: String(name.prefix(180)), date: Int64(message.timestamp) * 1000,
            archive: false, folder: "", tags: [], note: "")
        guard let sources = GoldgramUnifiedIdentity.sources(message.id.peerId) else { return }
        goldgramUnifiedCall("goldgram_unified_search_v1", ["accountId": NSNumber(value: context.account.peerId.id._internalGetInt64Value()),
            "needle": "", "event": 0, "since": 0, "offset": 0, "sources": sources,
            "messageId": NSNumber(value: message.id.id)]) { [weak controller] answer in
            guard let controller, isCurrentAccount(context), controller.viewIfLoaded?.window != nil,
                  controller.presentedViewController == nil else { return }
            var bookmark = value
            if answer["status"] as? String == "ok",
               let rows = answer["items"] as? [[String: Any]],
               rows.contains(where: { GoldgramUnifiedIdentity.message($0) == message.id }) { bookmark.archive = true }
            GoldgramPersonalUI.editBookmark(controller, context: context, value: bookmark) {}
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
    private let chooseMedia: ((EnginePeer?, [EnginePeer]) -> Void)?
    private let query = UISearchBar()
    private let disposable = MetaDisposable()
    private var peers: [EnginePeer] = []
    private var filtered: [EnginePeer] = []
    private var activity: [EnginePeer.Id: Int32] = [:]
    private var predecessors: [EnginePeer.Id: [EnginePeer]] = [:]
    private var loaded = false
    private var partial = false

    init(context: AccountContext, choose: @escaping (EnginePeer?) -> Void) {
        self.context = context
        self.choose = choose
        self.chooseMedia = nil
        super.init(style: .insetGrouped)
    }

    init(context: AccountContext, chooseMedia: @escaping (EnginePeer?, [EnginePeer]) -> Void) {
        self.context = context
        self.choose = { _ in }
        self.chooseMedia = chooseMedia
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
            var candidates: [EnginePeer] = []
            for item in a.items + b.items {
                guard case .chatList = item.id, let peer = item.renderedPeer.peer,
                      GoldgramUnifiedIdentity.sources(peer.id) != nil else { continue }
                if let date = item.messages.map({ $0.timestamp }).max() {
                    self.activity[peer.id] = max(self.activity[peer.id] ?? 0, date)
                }
                if seen.insert(peer.id).inserted { candidates.append(peer) }
            }
            if self.chooseMedia != nil {
                candidates = candidates.filter { GoldgramMediaEntry.acceptsPeer($0) }
                let byId = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
                var hidden = Set<EnginePeer.Id>()
                for peer in candidates {
                    // Never merge by title or bare numeric ID. Only a native
                    // migration reference to an available, ordinary supergroup.
                    guard case let .legacyGroup(group) = peer,
                          let targetId = group.migrationReference?.peerId,
                          let target = byId[targetId],
                          case let .channel(channel) = target,
                          case .group = channel.info else { continue }
                    self.predecessors[targetId, default: []].append(peer)
                    hidden.insert(peer.id)
                    self.activity[targetId] = max(self.activity[targetId] ?? 0, self.activity[peer.id] ?? 0)
                }
                candidates.removeAll { hidden.contains($0.id) }
            }
            self.peers = candidates.sorted {
                if self.chooseMedia != nil {
                    let left = self.activity[$0.id] ?? 0, right = self.activity[$1.id] ?? 0
                    if left != right { return left > right }
                }
                let order = $0.compactDisplayTitle.localizedCaseInsensitiveCompare($1.compactDisplayTitle)
                if order != .orderedSame { return order == .orderedAscending }
                return $0.id.toInt64() < $1.id.toInt64()
            }
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
            term.isEmpty || $0.compactDisplayTitle.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
                (chooseMedia != nil && (($0.addressName ?? "").range(of: term.trimmingCharacters(in: CharacterSet(charactersIn: "@")), options: [.caseInsensitive]) != nil ||
                    String($0.id.id._internalGetInt64Value()).contains(term)))
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
        let cell = UITableViewCell(style: chooseMedia == nil ? .default : .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = indexPath.row == 0 ? "Все диалоги" : filtered[indexPath.row - 1].compactDisplayTitle
        guard chooseMedia != nil, indexPath.row > 0 else { return cell }
        let peer = filtered[indexPath.row - 1]
        let kind: String
        let icon: String
        switch peer {
        case .user: kind = "Личный чат"; icon = "person.crop.circle"
        case let .legacyGroup(group):
            kind = group.migrationReference != nil ? "Старая группа" : "Группа"; icon = "person.2.circle"
        case let .channel(channel):
            if case .group = channel.info { kind = "Супергруппа"; icon = "person.3.sequence.fill" }
            else { kind = "Канал"; icon = "megaphone" }
        default: kind = "Диалог"; icon = "bubble.left"
        }
        var parts = [kind, "ID \(peer.id.id._internalGetInt64Value())"]
        if let name = peer.addressName, !name.isEmpty { parts.append("@"+name) }
        if let date = activity[peer.id], date > 0 {
            parts.append(DateFormatter.localizedString(from: Date(timeIntervalSince1970: Double(date)), dateStyle: .short, timeStyle: .short))
        }
        if predecessors[peer.id]?.isEmpty == false { parts.append("Есть прежняя история") }
        cell.detailTextLabel?.text = parts.joined(separator: " · ")
        cell.detailTextLabel?.numberOfLines = 2
        cell.detailTextLabel?.textColor = .secondaryLabel
        let thumbnailData = peer.smallProfileImage?.immediateThumbnailData
        let tiny = thumbnailData.flatMap { $0.count <= 65536 ? decodeTinyThumbnail(data: $0) : nil }.flatMap { UIImage(data: $0) }
        let image = tiny ?? UIImage(systemName: icon)
        if let image {
            cell.imageView?.image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { _ in
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 40, height: 40)).addClip()
                UIColor.secondarySystemGroupedBackground.setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: 40, height: 40))
                image.draw(in: CGRect(x: 0, y: 0, width: 40, height: 40))
            }
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard GoldgramAuthorSearchBridge.isCurrentAccount(context),
              indexPath.row == 0 || filtered.indices.contains(indexPath.row - 1) else { return }
        let peer = indexPath.row == 0 ? nil : filtered[indexPath.row - 1]
        if let chooseMedia {
            chooseMedia(peer, peer.flatMap { predecessors[$0.id] } ?? [])
        } else { choose(peer) }
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
    private let dateButton = UIButton(type: .system)
    private let mediaButton = UIButton(type: .system)
    private let presetsButton = UIButton(type: .system)
    private let sort = UISegmentedControl(items: ["Сначала новые", "Сначала старые"])
    private var customFrom: Int32?
    private var customThrough: Int32?
    private var until: Int32?
    private var mediaMode = 0
    private var requestedMedia = 0
    private var requestedOldest = false
    private let mediaTitles = ["Все сообщения", "Ссылки", "Фото", "Видео", "Документы", "Голосовые"]
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
        title = "Расширенный поиск 2.0"
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
        period.addTarget(self, action: #selector(periodChanged), for: .valueChanged)
        dateButton.addTarget(self, action: #selector(chooseDates), for: .touchUpInside)
        mediaButton.addTarget(self, action: #selector(chooseMedia), for: .touchUpInside)
        presetsButton.setTitle("Сохранённые фильтры", for: .normal)
        presetsButton.addTarget(self, action: #selector(choosePreset), for: .touchUpInside)
        sort.selectedSegmentIndex = 0
        sort.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        event.addTarget(self, action: #selector(eventChanged), for: .valueChanged)
        let actions = UIStackView(arrangedSubviews: [find, reset])
        actions.distribution = .fillEqually
        let note = UILabel()
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        note.text = "Дата — время отправки. Тип вложений — только Telegram: архив не хранит надёжную классификацию медиа. Сортировка применяется к загруженным результатам."
        info.numberOfLines = 0
        info.textColor = .secondaryLabel
        info.font = .preferredFont(forTextStyle: .footnote)
        info.text = "Введите текст или выберите автора, диалог либо период."
        let stack = UIStackView(arrangedSubviews: [source, input, authorButton, dialogButton, period,
            dateButton, mediaButton, event, sort, presetsButton, actions, note, info])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        for control in [source, period, event, sort] { control.heightAnchor.constraint(equalToConstant: 32).isActive = true }
        input.heightAnchor.constraint(equalToConstant: 50).isActive = true
        for button in [authorButton, dialogButton, dateButton, mediaButton, presetsButton, find, reset] {
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
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        if let from = customFrom, let through = customThrough {
            dateButton.setTitle("Период: \(formatter.string(from: Date(timeIntervalSince1970: Double(from)))) – \(formatter.string(from: Date(timeIntervalSince1970: Double(through))))", for: .normal)
        } else { dateButton.setTitle("Выбрать даты…", for: .normal) }
        mediaButton.setTitle("Тип: " + mediaTitles[mediaMode], for: .normal)
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
        customFrom = nil; customThrough = nil; mediaMode = 0; sort.selectedSegmentIndex = 0
        updateButtons(); filterChanged()
    }
    @objc private func sourceChanged() {
        if source.selectedSegmentIndex != 1 { event.selectedSegmentIndex = 0 }
        if source.selectedSegmentIndex != 0 { mediaMode = 0 }
        updateButtons(); filterChanged()
    }
    @objc private func eventChanged() {
        // Telegram cannot report historical edit/deletion events. Selecting
        // one of these filters intentionally switches to the archive source.
        if event.selectedSegmentIndex != 0 { source.selectedSegmentIndex = 1; mediaMode = 0 }
        updateButtons(); filterChanged()
    }
    @objc private func periodChanged() {
        customFrom = nil; customThrough = nil
        updateButtons(); filterChanged()
    }

    @objc private func chooseDates() {
        guard accountOK else { return }
        input.resignFirstResponder()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let alert = UIAlertController(title: "Период отправки", message: "Введите даты в формате ГГГГ-ММ-ДД. Обе даты включительно.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "С 2026-01-01"
            if let from = self.customFrom { field.text = formatter.string(from: Date(timeIntervalSince1970: Double(from))) }
        }
        alert.addTextField { field in
            field.placeholder = "По 2026-11-24"
            field.text = formatter.string(from: self.customThrough.map { Date(timeIntervalSince1970: Double($0)) } ?? Date())
        }
        alert.addAction(UIAlertAction(title: "Применить", style: .default) { [weak self = self, weak alert] _ in
            guard let self, self.accountOK, let fields = alert?.textFields, fields.count == 2 else { return }
            let a = fields[0].text ?? "", b = fields[1].text ?? ""
            guard let start = formatter.date(from: a), let last = formatter.date(from: b),
                  formatter.string(from: start) == a, formatter.string(from: last) == b,
                  let end = formatter.calendar.date(byAdding: .day, value: 1, to: last),
                  let first = Int32(exactly: Int64(start.timeIntervalSince1970)),
                  let through = Int32(exactly: Int64(end.timeIntervalSince1970) - 1),
                  first > 0, first <= through else {
                self.showError("Проверьте даты и их порядок. Допустимый формат: ГГГГ-ММ-ДД."); return
            }
            self.customFrom = first; self.customThrough = through
            self.period.selectedSegmentIndex = 0
            self.updateButtons(); self.filterChanged()
        })
        alert.addAction(UIAlertAction(title: "Убрать период", style: .default) { [weak self = self] _ in self?.period.selectedSegmentIndex = 0; self?.periodChanged() })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func chooseMedia() {
        guard accountOK else { return }
        let sheet = UIAlertController(title: "Тип сообщения", message: "Фильтры вложений применяются к Telegram.", preferredStyle: .actionSheet)
        for (index, title) in mediaTitles.enumerated() {
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self = self] _ in
                guard let self, self.accountOK else { return }
                self.mediaMode = index
                if index != 0 { self.source.selectedSegmentIndex = 0; self.event.selectedSegmentIndex = 0 }
                self.updateButtons(); self.filterChanged()
            })
        }
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        sheet.popoverPresentationController?.sourceView = mediaButton
        sheet.popoverPresentationController?.sourceRect = mediaButton.bounds
        present(sheet, animated: true)
    }

    private func presetValue(_ name: String) -> GoldgramSearchPreset {
        let peer = chosenChat.flatMap { GoldgramUnifiedIdentity.sources($0)?.first }
        return GoldgramSearchPreset(name: name, text: String((input.text ?? "").prefix(200)),
            source: source.selectedSegmentIndex, period: period.selectedSegmentIndex, event: event.selectedSegmentIndex,
            media: mediaMode, oldest: sort.selectedSegmentIndex == 1, from: customFrom, through: customThrough,
            authorId: (author?.id ?? personalAuthorId)?.id._internalGetInt64Value(),
            authorName: (author?.compactDisplayTitle ?? personalAuthorName).map { String($0.prefix(180)) },
            peerKind: (peer?["peerKind"] as? NSNumber)?.int32Value,
            peerId: (peer?["peerId"] as? NSNumber)?.int64Value, peerName: chosenChatName.map { String($0.prefix(180)) })
    }
    private func applyPreset(_ value: GoldgramSearchPreset) {
        guard accountOK, value.valid else { return }
        input.text = value.text
        source.selectedSegmentIndex = value.source; period.selectedSegmentIndex = value.period
        event.selectedSegmentIndex = value.event; mediaMode = value.media; sort.selectedSegmentIndex = value.oldest ? 1 : 0
        customFrom = value.from; customThrough = value.through
        author = nil
        personalAuthorId = value.authorId.map { EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value($0)) }
        personalAuthorName = value.authorName ?? (value.authorId.map { "Автор #\($0)" })
        chosenChat = nil; chosenChatName = nil
        if let kind = value.peerKind, let raw = value.peerId,
           let id = GoldgramUnifiedIdentity.message(["peerKind": NSNumber(value: kind), "peerId": NSNumber(value: raw), "messageId": NSNumber(value: 1)]) {
            chosenChat = id.peerId; chosenChatName = value.peerName ?? "Диалог #\(raw)"
        }
        updateButtons(); filterChanged()
    }
    @objc private func choosePreset() {
        guard accountOK else { return }
        let values: [GoldgramSearchPreset]
        do { values = try GoldgramPersonalUI.read(context).presets ?? [] }
        catch { showError("Сохранённые фильтры недоступны."); return }
        let sheet = UIAlertController(title: "Сохранённые фильтры", message: "Выбор загружает фильтры без запуска поиска.", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Сохранить текущие фильтры…", style: .default) { [weak self = self] _ in
            guard let self, self.accountOK else { return }
            let alert = UIAlertController(title: "Название набора", message: nil, preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "Например, Работа" }
            alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self = self, weak alert] _ in
                guard let self, self.accountOK else { return }
                let name = String((alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
                let value = self.presetValue(name)
                do { try GoldgramPersonalUI.change(self.context) { $0.putPreset(value) } }
                catch { self.showError("Не удалось сохранить набор. Введите название; доступно до 20 наборов.") }
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            self.present(alert, animated: true)
        })
        for value in values {
            sheet.addAction(UIAlertAction(title: value.name, style: .default) { [weak self = self] _ in self?.applyPreset(value) })
        }
        if !values.isEmpty {
            sheet.addAction(UIAlertAction(title: "Удалить набор…", style: .destructive) { [weak self = self] _ in
                guard let self, self.accountOK else { return }
                let remove = UIAlertController(title: "Удалить набор", message: nil, preferredStyle: .actionSheet)
                for value in values {
                    remove.addAction(UIAlertAction(title: value.name, style: .destructive) { [weak self = self] _ in
                        guard let self, self.accountOK else { return }
                        do { try GoldgramPersonalUI.change(self.context) { data in
                            data.presets?.removeAll { $0.name == value.name }; return true
                        } } catch { self.showError("Не удалось удалить набор.") }
                    })
                }
                remove.addAction(UIAlertAction(title: "Отмена", style: .cancel))
                remove.popoverPresentationController?.sourceView = self.presetsButton
                remove.popoverPresentationController?.sourceRect = self.presetsButton.bounds
                self.present(remove, animated: true)
            })
        }
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        sheet.popoverPresentationController?.sourceView = presetsButton
        sheet.popoverPresentationController?.sourceRect = presetsButton.bounds
        present(sheet, animated: true)
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
        since = customFrom ?? start.map { Int32(clamping: Int64($0.timeIntervalSince1970)) }
        until = customThrough
        requestedMedia = mediaMode
        requestedOldest = sort.selectedSegmentIndex == 1
        requestedAuthor = author?.id ?? personalAuthorId; requestedChat = chosenChat; requestedEvent = event.selectedSegmentIndex
        let wantsTelegram = source.selectedSegmentIndex != 1
        let wantsArchive = source.selectedSegmentIndex != 0
        if wantsTelegram && term.isEmpty && requestedAuthor == nil && requestedChat == nil && since == nil && requestedMedia == 0 {
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
            if self.requestedAuthor == nil && (!self.term.isEmpty || self.requestedMedia != 0) {
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
                  since == nil || message.timestamp >= (since ?? 0),
                  until == nil || message.timestamp <= (until ?? Int32.max),
                  matchesMedia(message) else { continue }
            if remoteRows.count >= maxResults && remoteRows[message.id] == nil { partial = true; break }
            remoteRows[message.id] = message
        }
        rebuild()
    }
    private var mediaTags: EngineMessage.Tags? {
        switch requestedMedia {
        case 1: return .webPage
        case 2, 3: return .photoOrVideo
        case 4: return .file
        case 5: return .voiceOrInstantVideo
        default: return nil
        }
    }
    private func matchesMedia(_ message: EngineMessage) -> Bool {
        switch requestedMedia {
        case 1: return message.tags.contains(.webPage)
        case 2: return message.tags.contains(.photo) || message.media.contains { $0 is TelegramMediaImage }
        case 3: return message.tags.contains(.video) || message.media.contains { ($0 as? TelegramMediaFile)?.isVideo == true }
        case 4: return message.tags.contains(.file)
        case 5: return message.media.contains { ($0 as? TelegramMediaFile)?.isVoice == true }
        default: return true
        }
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
        let location: SearchMessagesLocation = .general(scope: .everywhere, groupId: nil, tags: mediaTags,
            minDate: since, maxDate: until, folderId: nil, communityId: nil)
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
        let location: SearchMessagesLocation = .peer(peerId: peer, fromId: requestedAuthor, tags: mediaTags,
            reactions: nil, threadId: nil, minDate: since, maxDate: until)
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
            "offset": NSNumber(value: localOffset), "until": NSNumber(value: Int64(until ?? 0) * 1000 + (until == nil ? 0 : 999)),
            "sortMode": NSNumber(value: requestedOldest ? 2 : 1)]
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
            if x == 0 && y != 0 { return false }
            if y == 0 && x != 0 { return true }
            if x != y { return requestedOldest ? x < y : x > y }
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
            let body = details.joined(separator: "\n")
            let attributed = NSMutableAttributedString(string: body, attributes: [.foregroundColor: UIColor.secondaryLabel])
            if !term.isEmpty {
                let value = body as NSString
                var remaining = NSRange(location: 0, length: value.length)
                while remaining.length > 0 {
                    let found = value.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
                    if found.location == NSNotFound || found.length == 0 { break }
                    attributed.addAttributes([.backgroundColor: UIColor.systemYellow.withAlphaComponent(0.4),
                        .foregroundColor: UIColor.label], range: found)
                    let end = NSMaxRange(found)
                    remaining = NSRange(location: end, length: value.length - end)
                }
            }
            cell.detailTextLabel?.attributedText = attributed
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



// BEGIN GOLDGRAM_MEDIA_MODEL_V1
// Pure bounded filter/order rules used by the UI and isolated CI test.
private enum GoldgramMediaCategory: Int, CaseIterable {
    case photo, video, document, music, voice, circle, link, gif

    var title: String {
        switch self {
        case .photo: return "Фото"
        case .video: return "Видео"
        case .document: return "Документы"
        case .music: return "Музыка"
        case .voice: return "Голосовые"
        case .circle: return "Видеокружки"
        case .link: return "Ссылки"
        case .gif: return "GIF"
        }
    }
    var symbol: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        case .document: return "doc.text"
        case .music: return "music.note"
        case .voice: return "mic"
        case .circle: return "play.circle"
        case .link: return "link"
        case .gif: return "film"
        }
    }
    var visual: Bool { self == .photo || self == .video || self == .circle || self == .gif }
    var family: Int {
        switch self {
        case .photo, .video: return 0
        case .document: return 1
        case .music: return 2
        case .voice, .circle: return 3
        case .link: return 4
        case .gif: return 5
        }
    }
}

private enum GoldgramMediaRules {
    static func families(_ category: GoldgramMediaCategory?) -> [Int] {
        return category.map { [$0.family] } ?? Array(0..<6)
    }
    static func acceptsSize(_ size: Int64?, minimum: Int64) -> Bool {
        return minimum == 0 || (size.map { $0 >= minimum } ?? false)
    }
    static func matches(_ term: String, name: String, caption: String) -> Bool {
        return term.isEmpty || name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
            caption.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    static func extensionFor(_ name: String, fallback: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && ext.count <= 10 && ext.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains($0)
        } ? ext : fallback
    }
}
// END GOLDGRAM_MEDIA_MODEL_V1

private struct GoldgramMediaEntry {
    let message: EngineMessage
    let category: GoldgramMediaCategory
    let name: String
    let size: Int64?
    let thumbnail: Data?
    var chat: String { message.enginePeers[message.id.peerId]?.compactDisplayTitle ?? "Диалог" }
    var author: String { message.author?.compactDisplayTitle ?? "Автор неизвестен" }
    var date: String {
        DateFormatter.localizedString(from: Date(timeIntervalSince1970: Double(message.timestamp)), dateStyle: .short, timeStyle: .short)
    }

    static func acceptsPeer(_ peer: EnginePeer) -> Bool {
        switch peer {
        case let .channel(channel): return !channel.flags.contains(.copyProtectionEnabled)
        case let .legacyGroup(group): return !group.flags.contains(.copyProtectionEnabled)
        case .user: return true
        // Community peers have no supported identity in GoldgramUnifiedIdentity.
        // Fail closed until their access and media protection model is verified.
        case .secretChat, .community: return false
        @unknown default: return false
        }
    }

    static func kind(_ file: TelegramMediaFile, message: EngineMessage) -> GoldgramMediaCategory? {
        guard !file.isSticker, !file.isAnimatedSticker, !file.isCustomEmoji else { return nil }
        if file.isInstantVideo { return .circle }
        if file.isVoice { return .voice }
        if file.isAnimated || message.tags.contains(.gif) { return .gif }
        if file.isVideo { return .video }
        if file.isMusic { return .music }
        return message.tags.contains(.file) ? .document : nil
    }

    static func linkName(_ message: EngineMessage) -> String {
        for media in message.media {
            if let page = media as? TelegramMediaWebpage, let url = page.content.url, !url.isEmpty {
                return String(url.prefix(400))
            }
        }
        return String(message.text.prefix(400))
    }

    // Only ordinary cloud messages with known source peer and no protection/expiry.
    static func eligible(_ message: EngineMessage) -> Bool {
        guard message.id.namespace == Namespaces.Message.Cloud, message.id.id > 0,
              GoldgramUnifiedIdentity.sources(message.id.peerId) != nil,
              let peer = message.enginePeers[message.id.peerId],
              !message._asMessage().isCopyProtected(), !message.containsSecretMedia,
              !message.flags.isSending, !message.flags.contains(.Failed),
              message.adAttribute == nil,
              !message.attributes.contains(where: {
                  $0 is AutoremoveTimeoutMessageAttribute || $0 is AutoclearTimeoutMessageAttribute ||
                  $0 is EphemeralMessageAttribute || $0 is EphemeralReplacementMessageAttribute ||
                  $0 is EphemeralOutgoingMessageAttribute || $0 is MediaSpoilerMessageAttribute ||
                  $0 is RestrictedContentMessageAttribute
              }),
              !message.media.contains(where: { $0 is TelegramMediaAction || $0 is TelegramMediaExpiredContent }) else { return false }
        return acceptsPeer(peer)
    }

    static func from(_ message: EngineMessage, category: GoldgramMediaCategory?) -> Self? {
        guard eligible(message) else { return nil }
        if category == .link, message.tags.contains(.webPage) {
            return Self(message: message, category: .link, name: linkName(message), size: nil, thumbnail: nil)
        }
        for media in message.media {
            if let image = media as? TelegramMediaImage, category == nil || category == .photo {
                return Self(message: message, category: .photo, name: "Фотография", size: nil,
                            thumbnail: image.immediateThumbnailData)
            }
            if let file = media as? TelegramMediaFile, let kind = Self.kind(file, message: message) {
                guard category == nil || category == kind else { continue }
                return Self(message: message, category: kind, name: file.fileName ?? kind.title,
                            size: file.size.flatMap { $0 > 0 ? $0 : nil }, thumbnail: file.immediateThumbnailData)
            }
        }
        if category == nil, message.tags.contains(.webPage) {
            return Self(message: message, category: .link, name: linkName(message), size: nil, thumbnail: nil)
        }
        return nil
    }

    var sizeText: String {
        size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Размер неизвестен"
    }

    func previewResource() -> (EngineMediaResource, MediaResourceReference, MediaResourceUserContentType, String)? {
        let reference = MessageReference(message._asMessage())
        for media in message.media {
            if category == .photo, let image = media as? TelegramMediaImage,
               let representation = image.representations.max(by: {
                   Int64($0.dimensions.width) * Int64($0.dimensions.height) < Int64($1.dimensions.width) * Int64($1.dimensions.height)
               }) {
                let ref: ImageMediaReference = .message(message: reference, media: image)
                return (EngineMediaResource(representation.resource), ref.resourceReference(representation.resource), .image, "jpg")
            }
            if let file = media as? TelegramMediaFile, Self.kind(file, message: message) == category {
                let ref: FileMediaReference = .message(message: reference, media: file)
                let fallback: String
                switch category {
                case .video, .circle, .gif: fallback = file.mimeType == "image/gif" ? "gif" : "mp4"
                case .music: fallback = "mp3"
                case .voice: fallback = "ogg"
                default: fallback = "bin"
                }
                return (EngineMediaResource(file.resource), ref.resourceReference(file.resource),
                        MediaResourceUserContentType(file: file), GoldgramMediaRules.extensionFor(file.fileName ?? "", fallback: fallback))
            }
        }
        return nil
    }
}

private final class GoldgramMediaPreview: QLPreviewController, QLPreviewControllerDataSource {
    private let url: URL
    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }
    required init?(coder: NSCoder) { return nil }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
}

private final class GoldgramMediaCell: UICollectionViewCell {
    private let image = UIImageView()
    private let name = UILabel()
    private let details = UILabel()
    private let column = UIStackView()
    private let labels = UIStackView()
    private var listWidth: NSLayoutConstraint?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        image.clipsToBounds = true
        image.tintColor = .systemTeal
        image.contentMode = .scaleAspectFit
        name.font = .preferredFont(forTextStyle: .subheadline)
        name.numberOfLines = 2
        details.font = .preferredFont(forTextStyle: .caption2)
        details.textColor = .secondaryLabel
        details.numberOfLines = 2
        labels.addArrangedSubview(name); labels.addArrangedSubview(details)
        labels.axis = .vertical; labels.spacing = 4
        column.addArrangedSubview(image); column.addArrangedSubview(labels)
        column.axis = .vertical; column.spacing = 8
        listWidth = image.widthAnchor.constraint(equalToConstant: 70)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            image.heightAnchor.constraint(greaterThanOrEqualToConstant: 22)
        ])
        name.setContentCompressionResistancePriority(.required, for: .vertical)
        details.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { return nil }
    func configure(_ row: GoldgramMediaEntry, grid: Bool, cached: Bool = false) {
        listWidth?.isActive = !grid
        column.axis = grid ? .vertical : .horizontal
        name.text = row.name.isEmpty ? row.category.title : row.name
        details.text = row.chat + " · " + row.date + (cached ? " · Локально" : "") + (grid ? "" : " · " + row.sizeText)
        let decoded = row.thumbnail.flatMap { $0.count <= 65536 ? decodeTinyThumbnail(data: $0) : nil }.flatMap { UIImage(data: $0) }
        image.image = decoded ?? UIImage(systemName: row.category.symbol)
        image.contentMode = decoded == nil ? .scaleAspectFit : .scaleAspectFill
        isAccessibilityElement = true
        accessibilityLabel = [name.text ?? "", details.text ?? ""].joined(separator: ", ")
    }
}

private final class GoldgramMediaCenter: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate {
    private let context: AccountContext
    private let input = UISearchBar()
    private let categoryBar = UIScrollView()
    private let categoryStack = UIStackView()
    private let filterButton = UIButton(type: .system)
    private let info = UILabel()
    private let more = UIButton(type: .system)
    private let layout = UICollectionViewFlowLayout()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let queryTask = MetaDisposable()
    private let dialogsTask = MetaDisposable()
    private let cacheTask = MetaDisposable()
    private let previewTask = MetaDisposable()
    private let downloadTask = MetaDisposable()
    private var category: GoldgramMediaCategory?
    private var author: EnginePeer?
    private var chat: EnginePeer?
    private var relatedChats: [EnginePeer] = []
    private var cacheIds = Set<EngineMessage.Id>()
    private var remoteUnavailable = false
    private var remoteResponded = false
    private var cachedHistoryLatest: Int32?
    private var remoteHistoryLatest: Int32?
    private var cachedHistoryCount = 0
    private var remoteHistoryCount = 0
    private var cachedHistoryPending = false
    private var scope = 0 // all/private/groups/channels
    private var from: Int32?
    private var through: Int32?
    private var minSize: Int64 = 0
    private var sort = 0
    private var grid = true
    private var rows: [GoldgramMediaEntry] = []
    private var found: [EngineMessage.Id: GoldgramMediaEntry] = [:]
    private var allowed: [EnginePeer.Id: EnginePeer] = [:]
    private var states: [Int: SearchMessagesState] = [:]
    private var pages: [Int: Int] = [:]
    private var finished = Set<Int>()
    private var families: [Int] = []
    private var activeFamily: Int?
    private var generation = 0
    private var previewGeneration = 0
    private var busy = false
    private var partial = false
    private var started = false
    private var handingOff = false
    private var query = ""
    private var previewAlert: UIAlertController?
    private var accountOK: Bool { GoldgramAuthorSearchBridge.isCurrentAccount(context) }

    init(context: AccountContext) { self.context = context; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { return nil }
    deinit { queryTask.dispose(); dialogsTask.dispose(); cacheTask.dispose(); previewTask.dispose(); downloadTask.dispose() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Единый медиацентр"
        view.backgroundColor = .systemGroupedBackground
        input.placeholder = "Название, подпись или ссылка"
        input.returnKeyType = .search; input.delegate = self
        filterButton.addTarget(self, action: #selector(filters), for: .touchUpInside)
        let search = UIButton(type: .system)
        search.setTitle("Найти", for: .normal); search.addTarget(self, action: #selector(restart), for: .touchUpInside)
        let layoutButton = UIButton(type: .system)
        layoutButton.setImage(UIImage(systemName: "square.grid.2x2"), for: .normal)
        layoutButton.accessibilityLabel = "Галерея или список"
        layoutButton.addTarget(self, action: #selector(toggleLayout), for: .touchUpInside)
        let refresh = UIButton(type: .system)
        refresh.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refresh.accessibilityLabel = "Обновить результаты"
        refresh.addTarget(self, action: #selector(restart), for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [filterButton, search, refresh, layoutButton])
        controls.axis = .horizontal; controls.distribution = .fillEqually; controls.spacing = 8
        info.font = .preferredFont(forTextStyle: .footnote); info.textColor = .secondaryLabel; info.numberOfLines = 0
        categoryStack.axis = .horizontal; categoryStack.spacing = 8
        categoryStack.translatesAutoresizingMaskIntoConstraints = false
        categoryBar.showsHorizontalScrollIndicator = false
        categoryBar.addSubview(categoryStack)
        NSLayoutConstraint.activate([
            categoryStack.leadingAnchor.constraint(equalTo: categoryBar.contentLayoutGuide.leadingAnchor),
            categoryStack.trailingAnchor.constraint(equalTo: categoryBar.contentLayoutGuide.trailingAnchor),
            categoryStack.topAnchor.constraint(equalTo: categoryBar.contentLayoutGuide.topAnchor),
            categoryStack.bottomAnchor.constraint(equalTo: categoryBar.contentLayoutGuide.bottomAnchor),
            categoryStack.heightAnchor.constraint(equalTo: categoryBar.frameLayoutGuide.heightAnchor),
            categoryBar.heightAnchor.constraint(equalToConstant: 44)
        ])
        layout.minimumLineSpacing = 6; layout.minimumInteritemSpacing = 6
        collection.backgroundColor = .clear
        collection.register(GoldgramMediaCell.self, forCellWithReuseIdentifier: "media")
        collection.dataSource = self; collection.delegate = self
        collection.alwaysBounceVertical = true
        more.addTarget(self, action: #selector(loadNext), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [input, controls, categoryBar, info, collection, more])
        stack.axis = .vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            collection.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            more.heightAnchor.constraint(equalToConstant: 44)
        ])
        collection.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        rebuildCategories(); updateStatus()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handingOff = false
        guard accountOK else {
            clear()
            started = false
            previewGeneration += 1
            previewTask.set(nil); downloadTask.set(nil)
            updateStatus()
            return
        }
        if !started { restart() }
        else { updateStatus() }
    }

    // A sheet dismissal or interactive pop can call viewWillDisappear before
    // the gesture is committed. Never discard results or cursors there.
    // Keep the same controller state on cancellation and native chat handoff.
    // Real departure releases this controller; deinit disposes every task.
    // Only explicit search/filter changes or account invalidation clear rows.

    private func rebuildCategories() {
        for subview in categoryStack.arrangedSubviews { categoryStack.removeArrangedSubview(subview); subview.removeFromSuperview() }
        for index in -1..<GoldgramMediaCategory.allCases.count {
            let kind = GoldgramMediaCategory(rawValue: index)
            let button = UIButton(type: .system)
            button.tag = index
            button.setTitle(kind?.title ?? "Все", for: .normal)
            button.setImage(UIImage(systemName: kind?.symbol ?? "square.grid.2x2"), for: .normal)
            button.tintColor = kind == category ? .white : .systemTeal
            button.backgroundColor = kind == category ? .systemTeal : .secondarySystemGroupedBackground
            button.layer.cornerRadius = 11
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
            button.addTarget(self, action: #selector(selectCategory(_:)), for: .touchUpInside)
            categoryStack.addArrangedSubview(button)
        }
    }
    @objc private func selectCategory(_ button: UIButton) {
        category = GoldgramMediaCategory(rawValue: button.tag)
        grid = category?.visual ?? true
        rebuildCategories(); restart()
    }
    @objc private func toggleLayout() { grid.toggle(); layout.invalidateLayout(); collection.reloadData() }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { restart() }

    private func clear() {
        generation += 1; busy = false; activeFamily = nil; queryTask.set(nil); dialogsTask.set(nil); cacheTask.set(nil)
        cacheIds.removeAll(); remoteUnavailable = false; remoteResponded = false
        cachedHistoryLatest = nil; remoteHistoryLatest = nil
        cachedHistoryCount = 0; remoteHistoryCount = 0; cachedHistoryPending = false
        rows.removeAll(); found.removeAll(); allowed.removeAll(); states.removeAll()
        pages.removeAll(); finished.removeAll(); families.removeAll()
        collection.reloadData()
    }
    @objc private func restart() {
        input.resignFirstResponder()
        clear()
        guard accountOK else { updateStatus(); return }
        query = (input.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= 200 else { info.text = "Введите не более 200 символов."; return }
        started = true; partial = false; busy = true; families = GoldgramMediaRules.families(category)
        let token = generation
        updateStatus()
        if let chat {
            if GoldgramMediaEntry.acceptsPeer(chat) {
                allowed[chat.id] = chat
                for old in relatedChats where GoldgramMediaEntry.acceptsPeer(old) {
                    if case let .legacyGroup(group) = old, group.migrationReference?.peerId == chat.id {
                        allowed[old.id] = old
                    }
                }
                // Family 6 is recent unfiltered server history, before tag searches.
                families.insert(6, at: 0)
            }
            // Always seed from the actual current peer's native history. A
            // successful but stale server page must never suppress this read.
            if allowed[chat.id] != nil { loadCachedRecent(token) }
            else { busy = false; loadNext() }
            return
        }
        let root = context.engine.messages.chatList(group: .root, count: 1000) |> filter { !$0.isLoading } |> take(1)
        let archive = context.engine.messages.chatList(group: .archive, count: 1000) |> filter { !$0.isLoading } |> take(1)
        dialogsTask.set((combineLatest(root, archive) |> deliverOnMainQueue).start(next: { [weak self = self] a, b in
            guard let self, self.generation == token, self.accountOK, self.busy else { return }
            self.partial = a.hasEarlier || a.hasLater || b.hasEarlier || b.hasLater || a.items.count >= 1000 || b.items.count >= 1000
            for item in a.items + b.items {
                guard case let .chatList(id) = item.id, let peer = item.renderedPeer.peer,
                      GoldgramUnifiedIdentity.sources(id) != nil, self.acceptScope(peer),
                      GoldgramMediaEntry.acceptsPeer(peer) else { continue }
                self.allowed[id] = peer
            }
            self.busy = false; self.loadNext()
        }))
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self = self] in
            guard let self, self.generation == token, self.busy, self.pages.isEmpty else { return }
            self.dialogsTask.set(nil); self.busy = false; self.partial = true; self.finished = Set(self.families); self.updateStatus()
        }
    }

    private func acceptScope(_ peer: EnginePeer) -> Bool {
        switch scope {
        case 1: if case .user = peer { return true }; return false
        case 2:
            switch peer {
            case .legacyGroup: return true
            case let .channel(channel): if case .group = channel.info { return true }; return false
            default: return false
            }
        case 3:
            if case let .channel(channel) = peer, case .broadcast = channel.info { return true }
            return false
        default: return true
        }
    }
    private func tags(_ family: Int) -> EngineMessage.Tags {
        switch family {
        case 0: return .photoOrVideo
        case 1: return .file
        case 2: return .music
        case 3: return .voiceOrInstantVideo
        case 4: return .webPage
        default: return .gif
        }
    }
    @objc private func loadNext() {
        guard accountOK, !busy, started else { return }
        guard !allowed.isEmpty else { finished = Set(families); updateStatus(); return }
        guard found.count < 1000,
              let family = families.filter({ !finished.contains($0) }).min(by: {
                  let a = pages[$0] ?? 0, b = pages[$1] ?? 0
                  if a != b { return a < b }
                  return (families.firstIndex(of: $0) ?? 0) < (families.firstIndex(of: $1) ?? 0)
              }) else {
            if found.count >= 1000 { partial = true }
            updateStatus(); return
        }
        busy = true
        let token = generation, page = pages[family] ?? 0, previous = states[family]
        pages[family] = page + 1
        activeFamily = family
        let location: SearchMessagesLocation
        let recentHistory = family == 6
        if let chat {
            location = .peer(peerId: chat.id, fromId: recentHistory ? nil : author?.id,
                tags: recentHistory ? nil : tags(family), reactions: nil, threadId: nil,
                minDate: recentHistory ? nil : from, maxDate: recentHistory ? nil : through)
        } else {
            location = .general(scope: .everywhere, groupId: nil, tags: tags(family), minDate: from, maxDate: through, folderId: nil, communityId: nil)
        }
        updateStatus()
        queryTask.set((context.engine.messages.goldgramMediaSearch(location: location, query: recentHistory ? "" : query,
            state: previous, limit: recentHistory ? 100 : 50, recentHistory: recentHistory)
            |> take(1) |> deliverOnMainQueue).start(next: { [weak self = self] result, nextState in
            guard let self, self.generation == token, self.accountOK, self.busy,
                  self.activeFamily == family, self.pages[family] == page + 1 else { return }
            self.busy = false; self.activeFamily = nil
            if result.goldgramRemoteUnavailable {
                self.remoteUnavailable = true; self.partial = true
                self.finished.insert(family)
            } else {
                self.remoteResponded = true
                let messages = result.messages.map { EngineMessage($0) }
                if recentHistory, let chat = self.chat {
                    let exact = messages.filter { $0.id.peerId == chat.id }
                    self.remoteHistoryCount = exact.count
                    self.remoteHistoryLatest = exact.map { $0.timestamp }.max()
                    if exact.isEmpty { self.partial = true }
                }
                self.collectMedia(messages, cached: false)
                self.states[family] = nextState
                if result.completed || previous == nextState || page + 1 >= (recentHistory ? 3 : 10) {
                    self.finished.insert(family)
                    if !result.completed { self.partial = true }
                }
            }
            self.rebuild()
            self.continueInitial(token)
        }))
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self = self] in
            guard let self, self.generation == token, self.busy, self.activeFamily == family,
                  self.pages[family] == page + 1, !self.finished.contains(family) else { return }
            self.busy = false; self.activeFamily = nil; self.queryTask.set(nil); self.finished.insert(family)
            self.partial = true; self.remoteUnavailable = true
            self.updateStatus(); self.continueInitial(token)
        }
    }

    private func collectMedia(_ messages: [EngineMessage], cached: Bool) {
        for message in messages {
            guard allowed[message.id.peerId] != nil,
                  author == nil || message.author?.id == author?.id,
                  from == nil || message.timestamp >= (from ?? 0),
                  through == nil || message.timestamp <= (through ?? Int32.max),
                  let row = GoldgramMediaEntry.from(message, category: category),
                  GoldgramMediaRules.acceptsSize(row.size, minimum: minSize),
                  GoldgramMediaRules.matches(query, name: row.name, caption: message.text) else { continue }
            if found.count >= 1000 && found[message.id] == nil { partial = true; break }
            if cached {
                if found[message.id] != nil { continue }
                cacheIds.insert(message.id)
            } else { cacheIds.remove(message.id) }
            found[message.id] = row
        }
    }

    private func continueInitial(_ token: Int) {
        if families.contains(where: { pages[$0] == nil && !finished.contains($0) }) {
            DispatchQueue.main.async { [weak self = self] in
                guard let self, self.generation == token else { return }
                self.loadNext()
            }
        }
    }

    private func loadCachedRecent(_ token: Int) {
        guard let chat, accountOK, generation == token, allowed[chat.id] != nil else { return }
        cachedHistoryPending = true
        busy = true; updateStatus()
        cacheTask.set((context.engine.messages.goldgramCachedRecentMediaCandidates(peerId: chat.id)
            |> take(1) |> deliverOnMainQueue).start(next: { [weak self = self] messages in
            guard let self, self.accountOK, self.generation == token, self.cachedHistoryPending else { return }
            self.cachedHistoryPending = false
            self.busy = false
            let exact = messages.filter { $0.id.peerId == chat.id }
            self.cachedHistoryCount = exact.count
            self.cachedHistoryLatest = exact.map { $0.timestamp }.max()
            self.collectMedia(exact, cached: true)
            self.rebuild()
            self.continueInitial(token)
        }))
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self = self] in
            guard let self, self.generation == token, self.cachedHistoryPending else { return }
            self.cachedHistoryPending = false
            self.cacheTask.set(nil); self.busy = false; self.partial = true
            self.rebuild(); self.continueInitial(token)
        }
    }

    private func rebuild() {
        rows = found.values.sorted {
            switch sort {
            case 1: if $0.message.timestamp != $1.message.timestamp { return $0.message.timestamp < $1.message.timestamp }
            case 2:
                if $0.size != $1.size { return ($0.size ?? -1) > ($1.size ?? -1) }
            case 3:
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            default: break
            }
            if $0.message.timestamp != $1.message.timestamp { return $0.message.timestamp > $1.message.timestamp }
            if $0.message.id.peerId != $1.message.id.peerId {
                return $0.message.id.peerId.id._internalGetInt64Value() < $1.message.id.peerId.id._internalGetInt64Value()
            }
            return $0.message.id.id > $1.message.id.id
        }
        collection.reloadData(); updateStatus()
    }
    private func updateStatus() {
        filterButton.setTitle("Фильтры", for: .normal)
        guard accountOK else { info.text = "Аккаунт изменён. Откройте медиацентр заново."; more.isEnabled = false; return }
        let scopeName = chat?.compactDisplayTitle ?? ["Все чаты", "Личные", "Группы", "Каналы"][scope]
        var text = "\(scopeName) · \(author?.compactDisplayTitle ?? "Любой автор")\nЗагружено: \(rows.count) · \(busy ? "поиск…" : "доступные результаты")"
        if remoteResponded || !cacheIds.isEmpty {
            text += "\nСервер Telegram: \(rows.count - cacheIds.count) · локальная история: \(cacheIds.count)"
        }
        if chat != nil && !busy {
            // Compact source freshness evidence: no message contents, names or IDs.
            func date(_ value: Int32?) -> String {
                guard let value else { return "нет" }
                return DateFormatter.localizedString(from: Date(timeIntervalSince1970: Double(value)), dateStyle: .short, timeStyle: .short)
            }
            text += "\nИстория: лок. \(cachedHistoryCount) / \(date(cachedHistoryLatest)); сервер \(remoteHistoryCount) / \(date(remoteHistoryLatest))"
            if let local = cachedHistoryLatest, let remote = remoteHistoryLatest, local > remote {
                text += " · сервер отстаёт"
            }
        }
        if remoteUnavailable { text += "\nЧасть серверных запросов недоступна" }
        if !busy && rows.isEmpty && remoteUnavailable { text += " — отсутствие медиа не подтверждено" }
        if partial || (author != nil && chat == nil) { text += " · возможна неполная выдача" }
        if minSize > 0 { text += "\nРазмер от \(ByteCountFormatter.string(fromByteCount: minSize, countStyle: .file)); неизвестный размер исключён" }
        if from != nil || through != nil { text += " · выбран период" }
        info.text = text
        more.setTitle(busy ? "Загрузка…" : "Загрузить ещё", for: .normal)
        more.isEnabled = !busy && started && found.count < 1000 && families.contains { !finished.contains($0) }
    }
    @objc private func filters() {
        guard accountOK else { return }
        let sheet = UIAlertController(title: "Фильтры медиацентра", message: "Поиск по доступным облачным чатам. Сортировка относится к загруженным результатам.", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Выбрать чат или канал", style: .default) { [weak self = self] _ in
            guard let self else { return }
            self.navigationController?.pushViewController(GoldgramUnifiedDialogPicker(context: self.context, chooseMedia: { [weak self = self] peer, related in
                guard let self else { return }
                self.chat = peer; self.relatedChats = related; self.scope = 0; self.restart()
            }), animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Тип диалога", style: .default) { [weak self = self] _ in self?.chooseScope() })
        sheet.addAction(UIAlertAction(title: "Выбрать автора", style: .default) { [weak self = self] _ in
            guard let self else { return }
            self.navigationController?.pushViewController(GoldgramAuthorSearchScreen(context: self.context, chatId: nil, authorSelection: { [weak self = self] peer in
                self?.author = peer; self?.restart()
            }), animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Любой автор", style: .default) { [weak self = self] _ in self?.author = nil; self?.restart() })
        sheet.addAction(UIAlertAction(title: "Период отправки", style: .default) { [weak self = self] _ in self?.chooseDate() })
        sheet.addAction(UIAlertAction(title: "Минимальный размер", style: .default) { [weak self = self] _ in self?.chooseSize() })
        sheet.addAction(UIAlertAction(title: "Сортировка", style: .default) { [weak self = self] _ in self?.chooseSort() })
        sheet.addAction(UIAlertAction(title: "Сбросить фильтры", style: .destructive) { [weak self = self] _ in
            guard let self else { return }
            self.chat = nil; self.relatedChats.removeAll(); self.author = nil; self.scope = 0; self.from = nil; self.through = nil; self.minSize = 0; self.sort = 0; self.input.text = ""
            self.restart()
        })
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        sheet.popoverPresentationController?.sourceView = filterButton
        sheet.popoverPresentationController?.sourceRect = filterButton.bounds
        present(sheet, animated: true)
    }
    private func choices(_ title: String, _ labels: [String], action: @escaping (Int) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        for (index, label) in labels.enumerated() {
            alert.addAction(UIAlertAction(title: label, style: .default) { _ in action(index) })
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
    }
    private func chooseScope() {
        choices("Тип диалога", ["Все чаты", "Личные", "Группы", "Каналы"]) { [weak self = self] index in
            self?.scope = index; self?.chat = nil; self?.relatedChats.removeAll(); self?.restart()
        }
    }
    private func chooseSize() {
        choices("Минимальный размер", ["Любой", "1 МБ", "10 МБ", "100 МБ", "500 МБ"]) { [weak self = self] index in
            self?.minSize = [0, 1, 10, 100, 500][index] * Int64(1024 * 1024); self?.restart()
        }
    }
    private func chooseSort() {
        choices("Сортировка загруженных", ["Сначала новые", "Сначала старые", "По размеру", "По названию"]) { [weak self = self] index in
            self?.sort = index; self?.rebuild()
        }
    }
    private func chooseDate() {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        let alert = UIAlertController(title: "Период", message: "ГГГГ-ММ-ДД, обе даты включительно.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Начальная дата"; if let from = self.from { $0.text = formatter.string(from: Date(timeIntervalSince1970: Double(from))) } }
        alert.addTextField { $0.placeholder = "Конечная дата"; $0.text = self.through.map { formatter.string(from: Date(timeIntervalSince1970: Double($0))) } ?? formatter.string(from: Date()) }
        alert.addAction(UIAlertAction(title: "Применить", style: .default) { [weak self = self, weak alert] _ in
            guard let self, let fields = alert?.textFields, fields.count == 2,
                  let a = fields[0].text, let b = fields[1].text, let first = formatter.date(from: a), let last = formatter.date(from: b),
                  formatter.string(from: first) == a, formatter.string(from: last) == b,
                  let next = formatter.calendar.date(byAdding: .day, value: 1, to: last),
                  let low = Int32(exactly: Int64(first.timeIntervalSince1970)), let high = Int32(exactly: Int64(next.timeIntervalSince1970) - 1),
                  low > 0, low <= high else { self?.error("Проверьте даты."); return }
            self.from = low; self.through = high; self.restart()
        })
        alert.addAction(UIAlertAction(title: "Любая дата", style: .default) { [weak self = self] _ in self?.from = nil; self?.through = nil; self?.restart() })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { accountOK ? rows.count : 0 }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "media", for: indexPath)
        if let cell = cell as? GoldgramMediaCell, accountOK, rows.indices.contains(indexPath.item) { cell.configure(rows[indexPath.item], grid: grid, cached: cacheIds.contains(rows[indexPath.item].message.id)) }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let columns: CGFloat = grid ? (collectionView.bounds.width > 600 ? 4 : 3) : 1
        let width = max(80, floor((collectionView.bounds.width - (columns - 1) * 6) / columns))
        return CGSize(width: width, height: grid ? max(125, width + 24) : 105)
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard accountOK, rows.indices.contains(indexPath.item) else { return }
        details(rows[indexPath.item])
    }
    private func details(_ row: GoldgramMediaEntry) {
        guard accountOK, GoldgramMediaEntry.eligible(row.message) else { return }
        let alert = UIAlertController(title: row.name.isEmpty ? row.category.title : row.name,
            message: "\(row.category.title) · \(row.sizeText)\n\(row.chat)\n\(row.author) · \(row.date)\n\n" + String(row.message.text.prefix(1000)),
            preferredStyle: .alert)
        if row.category != .link {
            alert.addAction(UIAlertAction(title: "Открыть файл", style: .default) { [weak self = self] _ in self?.open(row) })
        }
        alert.addAction(UIAlertAction(title: "Перейти к сообщению", style: .default) { [weak self = self] _ in self?.jump(row.message.id) })
        alert.addAction(UIAlertAction(title: "В личное избранное", style: .default) { [weak self = self] _ in
            self?.revalidate(row) { [weak self = self] current in
                guard let self else { return }
                GoldgramAuthorSearchBridge.addBookmark(from: self, context: self.context, message: current.message)
            }
        })
        alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel)); present(alert, animated: true)
    }
    private func revalidate(_ row: GoldgramMediaEntry, action: @escaping (GoldgramMediaEntry) -> Void) {
        guard accountOK else { return }
        previewGeneration += 1
        let token = previewGeneration
        let signal = context.engine.data.get(
            TelegramEngine.EngineData.Item.Messages.Message(id: row.message.id),
            TelegramEngine.EngineData.Item.Peer.Peer(id: row.message.id.peerId)) |> take(1) |> deliverOnMainQueue
        previewTask.set(signal.start(next: { [weak self = self] message, peer in
            guard let self, self.accountOK, self.previewGeneration == token, self.viewIfLoaded?.window != nil else { return }
            guard let message, let peer, GoldgramMediaEntry.acceptsPeer(peer),
                  let current = GoldgramMediaEntry.from(message, category: row.category) else {
                self.error("Не удалось подтвердить доступность обычного медиа. Откройте исходное сообщение."); return
            }
            DispatchQueue.main.async { [weak self = self] in
                guard let self, self.accountOK, self.previewGeneration == token, self.viewIfLoaded?.window != nil else { return }
                action(current)
            }
        }))
    }
    private func open(_ row: GoldgramMediaEntry) {
        revalidate(row) { [weak self = self] current in self?.checkCache(current, afterDownload: false) }
    }
    private func checkCache(_ row: GoldgramMediaEntry, afterDownload: Bool) {
        guard accountOK, let resource = row.previewResource() else { error("Откройте файл в исходном сообщении."); return }
        previewGeneration += 1
        let token = previewGeneration
        previewTask.set((context.engine.resources.data(resource: resource.0, pathExtension: resource.3)
            |> take(1) |> deliverOnMainQueue).start(next: { [weak self = self] data in
            guard let self, self.accountOK, self.previewGeneration == token, self.viewIfLoaded?.window != nil else { return }
            if data.isComplete, FileManager.default.fileExists(atPath: data.path) {
                let url = URL(fileURLWithPath: data.path)
                if QLPreviewController.canPreview(url as NSURL) {
                    self.navigationController?.pushViewController(GoldgramMediaPreview(url: url), animated: true)
                } else {
                    self.offerNative(row, message: "Формат не поддерживается системным предпросмотром. Откройте в Telegram.")
                }
            } else if afterDownload {
                self.offerNative(row, message: "Файл ещё недоступен в кэше. Откройте в Telegram.")
            } else {
                let alert = UIAlertController(title: "Файл не загружен", message: "\(row.sizeText). Загрузить через обычный медиакэш Telegram?", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Загрузить", style: .default) { [weak self = self] _ in self?.download(row) })
                alert.addAction(UIAlertAction(title: "Открыть в Telegram", style: .default) { [weak self = self] _ in self?.jump(row.message.id) })
                alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); self.present(alert, animated: true)
            }
        }))
    }
    private func download(_ row: GoldgramMediaEntry) {
        revalidate(row) { [weak self = self] current in
            guard let self, let resource = current.previewResource(), self.presentedViewController == nil else { return }
            self.previewGeneration += 1
            let token = self.previewGeneration
            let alert = UIAlertController(title: "Загрузка", message: "Файл сохраняется в штатном медиакэше Telegram.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Отменить", style: .cancel) { [weak self = self] _ in
                self?.previewGeneration += 1; self?.downloadTask.set(nil); self?.previewAlert = nil
            })
            self.previewAlert = alert; self.present(alert, animated: true)
            let signal = self.context.engine.resources.fetch(reference: resource.1, userLocation: .peer(current.message.id.peerId), userContentType: resource.2)
                |> deliverOnMainQueue
            self.downloadTask.set(signal.start(error: { [weak self = self] _ in
                self?.endDownload(current, token: token, success: false)
            }, completed: { [weak self = self] in
                self?.endDownload(current, token: token, success: true)
            }))
        }
    }
    private func endDownload(_ row: GoldgramMediaEntry, token: Int, success: Bool) {
        guard previewGeneration == token, accountOK else { return }
        previewGeneration += 1
        let alert = previewAlert; previewAlert = nil
        alert?.dismiss(animated: true) { [weak self = self] in
            guard let self, self.accountOK else { return }
            if success { self.revalidate(row) { [weak self = self] current in self?.checkCache(current, afterDownload: true) } }
            else { self.offerNative(row, message: "Не удалось загрузить файл.") }
        }
    }
    private func offerNative(_ row: GoldgramMediaEntry, message: String) {
        let alert = UIAlertController(title: "Медиацентр", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Перейти к сообщению", style: .default) { [weak self = self] _ in self?.jump(row.message.id) })
        alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel)); present(alert, animated: true)
    }
    private func error(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Медиацентр", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
    private func jump(_ id: EngineMessage.Id) {
        guard accountOK, !handingOff, let navigation = navigationController, navigation.topViewController === self,
              let presenter = navigation.presentingViewController, let jump = GoldgramAuthorSearchBridge.nativeJump else {
            error("Не удалось открыть точное сообщение."); return
        }
        handingOff = true
        let snapshot = navigation.view.snapshotView(afterScreenUpdates: false)
        presenter.dismiss(animated: true) { [weak self = self] in
            guard let self else { return }
            if !jump(self.context, id, navigation, presenter, snapshot) {
                self.handingOff = false
                guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return }
                presenter.present(navigation, animated: false) { [weak self = self] in self?.error("Сообщение недоступно.") }
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
private struct GoldgramSearchPreset: Codable, Equatable {
    var name: String
    var text: String
    var source: Int
    var period: Int
    var event: Int
    var media: Int
    var oldest: Bool
    var from: Int32?
    var through: Int32?
    var authorId: Int64?
    var authorName: String?
    var peerKind: Int32?
    var peerId: Int64?
    var peerName: String?
    var valid: Bool {
        !name.isEmpty && name.count <= 50 && text.count <= 200 &&
        (0...2).contains(source) && (0...3).contains(period) &&
        (0...2).contains(event) && (0...5).contains(media) &&
        (media == 0 || (source == 0 && event == 0)) &&
        (event == 0 || source == 1) &&
        ((from == nil && through == nil) || (period == 0 && (from ?? 0) > 0 && (through ?? 0) >= (from ?? 0))) &&
        (authorId == nil || (authorId ?? 0) > 0) &&
        (peerKind == nil) == (peerId == nil) &&
        (peerKind.map { (0...3).contains($0) } ?? true) &&
        (peerId == nil || (peerId ?? 0) > 0) &&
        (authorName?.count ?? 0) <= 180 && (peerName?.count ?? 0) <= 180
    }
}
private struct GoldgramPersonalData: Codable {
    let version: Int
    let account: Int64
    var bookmarks: [GoldgramPersonalBookmark]
    var contacts: [GoldgramPersonalContact]
    var presets: [GoldgramSearchPreset]? = nil
    init(account: Int64) { version = 1; self.account = account; bookmarks = []; contacts = [] }
    func validate(account: Int64) -> Bool {
        version == 1 && self.account == account && account > 0 &&
        bookmarks.count <= 2000 && contacts.count <= 1000 &&
        bookmarks.allSatisfy { $0.valid } && contacts.allSatisfy { $0.valid } &&
        Set(bookmarks.map { $0.key }).count == bookmarks.count &&
        Set(contacts.map { $0.id }).count == contacts.count &&
        (presets?.count ?? 0) <= 20 && (presets?.allSatisfy { $0.valid } ?? true) &&
        Set((presets ?? []).map { $0.name }).count == (presets?.count ?? 0)
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
    mutating func putPreset(_ preset: GoldgramSearchPreset) -> Bool {
        guard preset.valid else { return false }
        var values = presets ?? []
        if let index = values.firstIndex(where: { $0.name == preset.name }) { values[index] = preset }
        else { guard values.count < 20 else { return false }; values.append(preset) }
        presets = values
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
        catch { GoldgramPersonalUI.error(owner); return }
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
            catch { GoldgramPersonalUI.error(owner) }
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
