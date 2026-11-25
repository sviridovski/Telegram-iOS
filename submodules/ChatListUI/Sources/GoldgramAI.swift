import Foundation
import UIKit
import Security

// #268: a built-in native AI command. Imported JavaScript receives no network,
// credentials, chat objects or send capability. User approves each request.
public struct GoldgramAIDraft: Equatable {
    public let identity: String
    public let text: String
    public init(identity: String, text: String) { self.identity = identity; self.text = text }
}

private struct GoldgramAIConfig {
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
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var query = keyQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
    func deleteKey() -> Bool {
        let status = SecItemDelete(keyQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

private final class GoldgramAINoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
        "Включите AI и вернитесь в чат. Вставьте текст в черновик, нажмите AI и подтвердите отправку текста и промпта в DeepSeek. Ответ вставляется только после подтверждения. Ключ хранится в Keychain, не в JS. Импортированный 2.1.8 пока не совместим."
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
            let alert = UIAlertController(title: "Модель DeepSeek", message: "ID Pro/Flash взяты из AI Commander 2.1.8. Доступность зависит от API.", preferredStyle: .alert)
            for model in ["deepseek-v4-pro", "deepseek-flash", "deepseek-chat", "deepseek-reasoner"] {
                alert.addAction(UIAlertAction(title: model, style: .default) { [weak self] _ in
                    guard let self, self.isCurrent() else { return }
                    self.config.model = model; self.tableView.reloadData()
                })
            }
            alert.addAction(UIAlertAction(title: "Другой ID", style: .default) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self else { return }
                    self.edit("ID модели DeepSeek", value: self.config.model, secure: false) { [weak self] value in
                        let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !model.isEmpty && model.utf8.count <= 100 { self?.config.model = model }
                    }
                }
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
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

    public static func isEnabled(account: String) -> Bool {
        GoldgramAIConfig(account: account).enabled && goldgramAIAllowed(account: account)
    }
    public init(account: String, presenter: UIViewController, snapshot: @escaping () -> GoldgramAIDraft?, insert: @escaping (GoldgramAIDraft, String) -> Bool) {
        config = GoldgramAIConfig(account: account); self.presenter = presenter; self.snapshot = snapshot; self.insert = insert
        super.init(frame: CGRect(x: 0, y: 0, width: 46, height: 38))
        backgroundColor = .systemBlue; layer.cornerRadius = 19
        setTitle("AI", for: .normal); setTitleColor(.white, for: .normal); titleLabel?.font = .boldSystemFont(ofSize: 15)
        accessibilityLabel = "Goldgram AI"; accessibilityHint = "Сгенерировать ответ на текст черновика"
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    required init?(coder: NSCoder) { return nil }
    deinit { NotificationCenter.default.removeObserver(self); task?.cancel(); session?.invalidateAndCancel() }
    @objc private func background() { cancel() }
    public func cancel() {
        token = UUID(); task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil
        setTitle("AI", for: .normal)
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
        guard let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return }
        activeAlert = alert; presenter.present(alert, animated: true)
    }
    private func notice(_ text: String) {
        let alert = UIAlertController(title: "Goldgram AI", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); presentAlert(alert)
    }
    @objc private func tapped() {
        if task != nil { cancel(); return }
        guard Self.isEnabled(account: config.account), let draft = snapshot() else { return }
        guard let key = config.readKey() else { notice("Задайте ключ в Goldgram → Плагины → AI Command Center."); return }
        let prompt = config.prompt, model = config.model
        guard let request = GoldgramAIProtocol.request(key: key, model: model, prompt: prompt, draft: draft.text) else {
            notice("Введите текст в поле сообщения. Проверьте размер текста, промпт и модель."); return
        }
        let alert = UIAlertController(title: "Передать текст в DeepSeek?", message: "Модель: " + model + "\n\nПромпт:\n" + prompt + "\n\nТекст:\n" + draft.text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Сгенерировать", style: .default) { [weak self] _ in
            guard let self, self.snapshot() == draft, Self.isEnabled(account: self.config.account) else { return }
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
                guard self.snapshot() == draft, Self.isEnabled(account: self.config.account) else { return }
                guard error == nil, let http = response as? HTTPURLResponse else { self.notice("Сетевая ошибка или тайм-аут."); return }
                guard http.statusCode == 200 else { self.notice("DeepSeek HTTP " + String(http.statusCode) + ". Проверьте ключ, баланс и ID модели."); return }
                guard let data, let answer = GoldgramAIProtocol.answer(data) else { self.notice("Нет ответа или ответ превышает 4096 символов."); return }
                self.preview(answer, draft: draft, token: current)
            }
        }
        self.task = task; task.resume()
    }
    private func preview(_ answer: String, draft: GoldgramAIDraft, token: UUID) {
        let alert = UIAlertController(title: "Ответ DeepSeek", message: answer, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Вставить в черновик", style: .default) { [weak self] _ in
            guard let self, self.token == token, self.snapshot() == draft, Self.isEnabled(account: self.config.account) else { return }
            self.activeAlert = nil
            _ = self.insert(draft, answer)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); presentAlert(alert)
    }
}
