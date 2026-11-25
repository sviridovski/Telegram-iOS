import Foundation
import UIKit
import WebKit
import UniformTypeIdentifiers

// #267: deliberately foreground, on-demand and local-only. Never expose Telegram,
// account objects, credentials, filesystem or network to imported JavaScript.
private struct GoldgramPluginManifest {
    static let supported: Set<String> = ["settings.read", "events", "console", "ui.read", "storage"]
    let name: String
    let version: String
    let author: String
    let required: Set<String>
    let optional: Set<String>

    init(_ code: String) {
        var fields: [String: String] = [:]
        var required = Set<String>()
        var optional = Set<String>()
        for raw in code.split(separator: "\n", omittingEmptySubsequences: false).prefix(100) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard line.hasPrefix("//") else { break }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@"), let space = body.firstIndex(where: { $0.isWhitespace }) else { continue }
            let key = String(body[body.index(after: body.startIndex)..<space])
            let value = body[space...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("permission.") {
                let token = String(key.dropFirst("permission.".count))
                if value == "optional" { optional.insert(token) } else { required.insert(token) }
            } else if key == "permissions" {
                required.formUnion(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            } else { fields[key] = value }
        }
        name = String((fields["name"] ?? "Без названия").prefix(100))
        version = String((fields["version"] ?? "1.0").prefix(40))
        author = String((fields["author"] ?? "").prefix(100))
        self.required = required
        self.optional = optional.subtracting(required)
    }
}

private struct GoldgramPluginRecord: Codable {
    var id = UUID()
    var code: String
    var enabled = false
    var grants: [String] = []
    // JSON scalar strings, not secrets. Separate from archive and Telegram DB.
    var settings: [String: String] = [:]
    var storage: [String: String] = [:]
    var previousCode: String?
    var settingsSchema: Data?
    var manifest: GoldgramPluginManifest { GoldgramPluginManifest(code) }
}

private struct GoldgramPluginState: Codable {
    var safe = false
    var plugins: [GoldgramPluginRecord] = []
}

private final class GoldgramPluginStore {
    static let maxCode = 512 * 1024
    let isCurrent: () -> Bool
    private let url: URL
    private(set) var state = GoldgramPluginState()
    private(set) var failure: String?
    init(account: String, isCurrent: @escaping () -> Bool) {
        self.isCurrent = isCurrent
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = root.appendingPathComponent("GoldgramPlugins", isDirectory: true).appendingPathComponent(account + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { state = try JSONDecoder().decode(GoldgramPluginState.self, from: Data(contentsOf: url)) }
            catch { failure = "Хранилище не читается. Исходный файл сохранён." }
        }
    }
    @discardableResult func save(_ next: GoldgramPluginState) -> Bool {
        guard isCurrent(), failure == nil, next.plugins.count <= 24,
              next.plugins.allSatisfy({ $0.code.utf8.count <= Self.maxCode }) else { return false }
        do {
            let bytes = try JSONEncoder().encode(next)
            guard bytes.count <= 26 * 1024 * 1024 else { return false }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            state = next
            return true
        } catch { return false }
    }
    func record(_ id: UUID) -> GoldgramPluginRecord? { state.plugins.first { $0.id == id } }
    @discardableResult func put(_ record: GoldgramPluginRecord) -> Bool {
        var next = state
        if let i = next.plugins.firstIndex(where: { $0.id == record.id }) { next.plugins[i] = record }
        else { next.plugins.append(record) }
        return save(next)
    }
    static func safeKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 100 && !["__proto__", "constructor", "prototype"].contains(key) &&
        key.range(of: "api.?key|password|secret|token|credential", options: [.regularExpression, .caseInsensitive]) == nil
    }
    static func validatedSections(_ input: [[String: Any]]) -> [[String: Any]]? {
        guard input.count <= 16 else { return nil }
        var seen = Set<String>()
        for section in input {
            guard let title = section["title"] as? String, title.count <= 160,
                  let items = section["items"] as? [[String: Any]], items.count <= 96 else { return nil }
            for item in items {
                guard let key = item["key"] as? String, safeKey(key), seen.insert(key).inserted,
                      let title = item["title"] as? String, title.count <= 160,
                      let kind = item["type"] as? String, ["toggle", "text", "textarea", "select", "slider", "stepper", "button"].contains(kind) else { return nil }
                if kind == "select" {
                    guard let options = item["options"] as? [[String: Any]], options.count <= 50,
                          options.allSatisfy({ ($0["value"] as? String ?? "").count <= 200 && ($0["title"] as? String ?? "").count <= 160 }) else { return nil }
                }
            }
        }
        return input
    }
    static func decodeValues(_ values: [String: String]) -> [String: Any] {
        values.compactMapValues { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
    }
    static func encodeValues(_ values: [String: Any]) -> [String: String]? {
        guard values.count <= 128 else { return nil }
        var result: [String: String] = [:]
        var total = 0
        for (key, value) in values {
            guard safeKey(key),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                  data.count <= 8192, let text = String(data: data, encoding: .utf8) else { return nil }
            total += data.count + key.utf8.count
            guard total <= 65536 else { return nil }
            result[key] = text
        }
        return result
    }
}

// A disposable WebKit worker, with no document or native objects in the script.
// A separate WebContent process and a worker termination deadline avoid putting
// imported loops on the UI thread. CSP denies external resource connections.
// This is a limited local runtime, not a complete Ghostgram API or a security audit.
@MainActor
private final class GoldgramPluginRun: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var web: WKWebView?
    private var timer: DispatchWorkItem?
    private var payload: String
    private var completion: (([String: Any]?, String?) -> Void)?

    init(host: UIView, record: GoldgramPluginRecord, event: String, key: String?, value: Any?, completion: @escaping ([String: Any]?, String?) -> Void) {
        var input: [String: Any] = ["source": record.code, "grants": record.grants, "event": event,
            "settings": GoldgramPluginStore.decodeValues(record.settings), "storage": GoldgramPluginStore.decodeValues(record.storage)]
        if let key { input["key"] = key }
        if let value { input["value"] = value }
        payload = (try? JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.completion = completion
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "goldgramResult")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        host.addSubview(view)
        web = view
        view.navigationDelegate = self
        let timeout = DispatchWorkItem { [weak self] in self?.finish(nil, "Превышено время выполнения (8 с).") }
        timer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        view.loadHTMLString(Self.page, baseURL: nil)
    }
    func cancel() { finish(nil, "Выполнение остановлено.") }
    private func finish(_ result: [String: Any]?, _ error: String?) {
        guard let done = completion else { return }
        completion = nil
        timer?.cancel(); timer = nil
        if let web {
            web.evaluateJavaScript("if(window.goldWorker){window.goldWorker.terminate();}", completionHandler: nil)
            web.configuration.userContentController.removeScriptMessageHandler(forName: "goldgramResult")
            web.stopLoading(); web.navigationDelegate = nil; web.removeFromSuperview()
        }
        web = nil
        done(result, error)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        webView.evaluateJavaScript("window.goldRun(" + payload + ");") { [weak self] _, error in
            if error != nil { self?.finish(nil, "Не удалось запустить JavaScript.") }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url == nil || url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil, "JavaScript-процесс остановлен.") }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "goldgramResult", message.frameInfo.isMainFrame,
              let raw = message.body as? String, raw.utf8.count <= 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            finish(nil, "Некорректный ответ плагина."); return
        }
        if let error = object["error"] as? String { finish(nil, String(error.prefix(500))) }
        else { finish(object, nil) }
    }

    private static let page = #"""
<!doctype html><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; worker-src blob:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
<script>
// BEGIN GOLDGRAM_WORKER_V1
function goldWorkerMain() {
  const send = self.postMessage.bind(self);
  self.onmessage = async function(e) {
    const p = e.data;
    const grants = new Set(p.grants || []);
    const allowed = t => grants.has(t);
    const need = t => { if (!allowed(t)) throw Error("Permission denied: " + t); };
    const sections = [], logs = [], handlers = Object.create(null);
    const settings = Object.assign(Object.create(null), p.settings || {});
    const storage = Object.assign(Object.create(null), p.storage || {});
    const own = (o,k) => Object.prototype.hasOwnProperty.call(o,k);
    const validKey = k => typeof k === "string" && k.length > 0 && k.length <= 100 &&
      !/api.?key|password|secret|token|credential/i.test(k) && !["__proto__","constructor","prototype"].includes(k);
    function write(bucket,k,v) {
      if (!validKey(k)) throw Error("Invalid or secret key");
      const raw = JSON.stringify(v);
      if (typeof raw !== "string" || raw.length > 8192) throw Error("Value too large");
      if (!own(bucket,k) && Object.keys(bucket).length >= 128) throw Error("Too many values");
      bucket[k] = JSON.parse(raw); return true;
    }
    const log = v => { if (logs.length < 80) logs.push(String(v).slice(0,1000)); };
    const toast = v => { need("ui.read"); log(v); };
    const section = c => {
      need("settings.read");
      if (!c || !Array.isArray(c.items) || sections.length >= 16) throw Error("Invalid settings section");
      const items = [];
      for (const it of c.items.slice(0,96)) {
        if (!it || !validKey(it.key) || !["toggle","text","textarea","select","slider","stepper","button"].includes(it.type)) continue;
        const i = {type:it.type,key:it.key,title:String(it.title || it.key).slice(0,160)};
        if (it.type === "toggle") i.default = !!it.default;
        if (["text","textarea"].includes(it.type)) i.default = String(it.default || "").slice(0,6000);
        if (["slider","stepper"].includes(it.type)) {
          i.min = Number.isFinite(it.min) ? it.min : 0; i.max = Number.isFinite(it.max) ? it.max : 100;
          if (i.max < i.min) continue;
          i.default = Math.max(i.min,Math.min(i.max,Number(it.default)||0));
        }
        if (it.type === "select") {
          i.options = (Array.isArray(it.options)?it.options:[]).slice(0,50).filter(o=>o && typeof o.value === "string").map(o=>({value:o.value.slice(0,200),title:String(o.title||o.value).slice(0,160)}));
          if (!i.options.length) continue;
          i.default = i.options.some(o=>o.value===it.default)?it.default:i.options[0].value;
        }
        if (it.type !== "button" && !own(settings,i.key)) write(settings,i.key,i.default);
        items.push(i);
      }
      sections.push({title:String(c.title||"Settings").slice(0,160),items});
      return true;
    };
    const logging = Object.freeze({log,info:log,warn:log,error:log});
    const api = Object.freeze({
      runtime:Object.freeze({apiVersion:()=>1,features:()=>({localOnly:true}),hasPermission:allowed,grants:()=>Array.from(grants)}),
      settings:Object.freeze({addSection:section,define:section,getPlugin:(k,f)=>{need("settings.read");return own(settings,k)?settings[k]:f;},setPlugin:(k,v)=>{need("settings.read");return write(settings,k,v);}}),
      storage:Object.freeze({get:k=>{need("storage");return own(storage,k)?storage[k]:null;},set:(k,v)=>{need("storage");return write(storage,k,v);},getJSON:(k,f)=>{need("storage");return own(storage,k)?storage[k]:f;},setJSON:(k,v)=>{need("storage");return write(storage,k,v);},remove:k=>{need("storage");delete storage[k];}}),
      events:Object.freeze({on:(name,fn)=>{need("events");if (!["plugin.start","settings.changed","settings.action"].includes(name)||typeof fn!=="function")return null; const list=handlers[name]||(handlers[name]=[]);if(list.length<24)list.push(fn);return String(list.length);}}),
      console:logging,log,toast,app:Object.freeze({toast,alert:(title,text)=>toast(String(title)+"\n"+String(text))})
    });
    try {
      const run = new Function("GGAPI","GG","console",p.source);
      await run(api,api,logging);
      for (const fn of handlers[p.event] || []) await fn({key:p.key,value:p.value});
      const raw = JSON.stringify({sections,settings,storage,logs});
      if (raw.length>220000) throw Error("Result too large");
      send(raw);
    } catch (_) { send(JSON.stringify({error:"Ошибка JavaScript или отсутствующее разрешение/API. Проверьте код и совместимость."})); }
  };
}
// END GOLDGRAM_WORKER_V1
window.goldRun = function(payload) {
  const url=URL.createObjectURL(new Blob(["("+goldWorkerMain.toString()+")()"],{type:"text/javascript"}));
  const worker=new Worker(url); window.goldWorker=worker;
  const finish=raw=>{worker.terminate();URL.revokeObjectURL(url);window.webkit.messageHandlers.goldgramResult.postMessage(raw);};
  worker.onmessage=e=>finish(typeof e.data==="string"?e.data:JSON.stringify({error:"Invalid result"}));
  worker.onerror=()=>finish(JSON.stringify({error:"Ошибка запуска JavaScript Worker."}));
  worker.postMessage(payload);
};
</script>
"""#
}

private final class GoldgramPluginEditor: UIViewController {
    private let input = UITextView()
    private let original: String
    private let onSave: (String) -> Void
    init(title: String, text: String, onSave: @escaping (String) -> Void) {
        original = text; self.onSave = onSave
        super.init(nibName: nil, bundle: nil); self.title = title
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        input.text = original; input.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        input.autocorrectionType = .no; input.autocapitalizationType = .none; input.smartQuotesType = .no; input.smartDashesType = .no
        input.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(input)
        NSLayoutConstraint.activate([input.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            input.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            input.leadingAnchor.constraint(equalTo: view.leadingAnchor), input.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
    }
    @objc private func save() { onSave(input.text ?? "") }
}

final class GoldgramPluginManager: UITableViewController, UIDocumentPickerDelegate {
    private let store: GoldgramPluginStore
    init(account: String, isCurrent: @escaping () -> Bool) {
        store = GoldgramPluginStore(account: account, isCurrent: isCurrent)
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() { super.viewDidLoad(); title = "Goldgram Plugins" }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); tableView.reloadData() }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Установленные" : "Управление" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? (store.failure ?? "Версия 1.0: локальные плагины запускаются вручную, без фоновой работы и сети.") : "Импортируйте только доверенный код. Не вводите API-ключи в обычные настройки."
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? (store.isCurrent() ? store.state.plugins.count : 0) : 4 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0 {
            let p = store.state.plugins[indexPath.row]
            cell.textLabel?.text = p.manifest.name
            cell.detailTextLabel?.text = p.manifest.version + " · " + (p.enabled ? "Разрешён" : "Выключен")
            cell.imageView?.image = UIImage(systemName: "puzzlepiece.extension")
        } else {
            cell.textLabel?.text = ["Вставить JavaScript", "Импортировать .js из файлов", "Установить тестовый плагин", "Безопасный режим"][indexPath.row]
            if indexPath.row == 3 { cell.detailTextLabel?.text = store.state.safe ? "Включён — выполнение заблокировано" : "Выключен" }
        }
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard store.isCurrent(), store.failure == nil else { notice("Аккаунт изменился или хранилище недоступно."); return }
        if indexPath.section == 0 {
            let id = store.state.plugins[indexPath.row].id
            navigationController?.pushViewController(GoldgramPluginDetail(store: store, id: id), animated: true)
            return
        }
        switch indexPath.row {
        case 0:
            let editor = GoldgramPluginEditor(title: "Новый JavaScript", text: "") { [weak self] code in
                guard let self else { return }
                if self.install(code) { self.navigationController?.popViewController(animated: true) }
                else { (self.navigationController?.topViewController as? GoldgramPluginEditor)?.showPluginError("Не удалось сохранить код (пустой, слишком большой или лимит плагинов).") }
            }
            navigationController?.pushViewController(editor, animated: true)
        case 1:
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "js") ?? .plainText], asCopy: true)
            picker.delegate = self; picker.allowsMultipleSelection = false; present(picker, animated: true)
        case 2: if !install(Self.example) { notice("Не удалось установить пример.") }
        default:
            var next = store.state; next.safe.toggle()
            if !store.save(next) { notice("Не удалось сохранить режим.") }
            tableView.reloadData()
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard store.isCurrent(), let url = urls.first, url.pathExtension.lowercased() == "js" else { notice("Выберите файл .js."); return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let data = try file.read(upToCount: GoldgramPluginStore.maxCode + 1) ?? Data()
            guard data.count <= GoldgramPluginStore.maxCode, let code = String(data: data, encoding: .utf8), install(code) else { notice("Нужен корректный UTF-8 .js до 512 КБ."); return }
        } catch { notice("Не удалось прочитать файл.") }
    }
    private func install(_ code: String) -> Bool {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, code.utf8.count <= GoldgramPluginStore.maxCode else { return false }
        let result = store.put(GoldgramPluginRecord(code: code))
        tableView.reloadData(); return result
    }
    private func notice(_ text: String) { showPluginError(text) }
    static let example = #"""
// @name Тест Goldgram
// @version 1.0.0
// @permission.settings.read required
// @permission.events required
// @permission.ui.read required
GGAPI.settings.addSection({title:"Мои настройки",items:[
  {type:"text",key:"name",title:"Имя",default:"Goldgram"},
  {type:"toggle",key:"enabled",title:"Приветствие",default:true},
  {type:"select",key:"mode",title:"Режим",default:"short",options:[{value:"short",title:"Кратко"},{value:"long",title:"Подробно"}]},
  {type:"slider",key:"level",title:"Уровень",min:1,max:10,default:5},
  {type:"textarea",key:"prompt",title:"Промпт",default:"Ответь кратко"},
  {type:"button",key:"test",title:"Проверить настройки"}
]});
GGAPI.events.on("settings.action", function(p) {
  if(p.key==="test") GGAPI.toast(GGAPI.settings.getPlugin("enabled",true) ? "Привет, "+GGAPI.settings.getPlugin("name","")+"!" : "Приветствие выключено");
});
GGAPI.events.on("plugin.start",function(){ GGAPI.log("Плагин запущен"); });
"""#
}

private extension UIViewController {
    func showPluginError(_ text: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Goldgram Plugins", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}

private final class GoldgramPluginDetail: UITableViewController {
    private let store: GoldgramPluginStore
    private let id: UUID
    private var run: GoldgramPluginRun?
    private var sections: [[String: Any]] = []
    private var logs: [String] = []
    private var status = "Не запускался"
    init(store: GoldgramPluginStore, id: UUID) { self.store = store; self.id = id; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = store.record(id)?.manifest.name ?? "Плагин"
        if let p = store.record(id), p.enabled, let data = p.settingsSchema,
           let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let valid = GoldgramPluginStore.validatedSections(raw) { sections = valid; status = "Настройки сохранены; запуск по запросу." }
        NotificationCenter.default.addObserver(self, selector: #selector(stopInBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func stopInBackground() { run?.cancel() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); run?.cancel() }
    override func numberOfSections(in tableView: UITableView) -> Int { 1 + sections.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Управление" : sections[section-1]["title"] as? String }
    private func items(_ section: Int) -> [[String: Any]] { sections[section-1]["items"] as? [[String: Any]] ?? [] }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 7 : items(section).count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { section == 0 ? status : nil }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 2
        if indexPath.section == 0 {
            let enabled = store.record(id)?.enabled == true
            cell.textLabel?.text = [enabled ? "Выключить" : "Включить и разрешить", run == nil ? "Запустить / обновить настройки" : "Остановить", "Редактор JavaScript", "Разрешения", "Консоль", "Откатить код", "Удалить плагин"][indexPath.row]
        } else {
            let item = items(indexPath.section)[indexPath.row]
            let key = item["key"] as? String ?? ""
            cell.textLabel?.text = item["title"] as? String
            if item["type"] as? String != "button", let p = store.record(id) {
                let value = GoldgramPluginStore.decodeValues(p.settings)[key] ?? item["default"] ?? ""
                if item["type"] as? String == "toggle" { cell.detailTextLabel?.text = (value as? Bool == true) ? "Включено" : "Выключено" }
                else { cell.detailTextLabel?.text = String(describing: value) }
            }
        }
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard store.isCurrent(), var p = store.record(id) else { return }
        if indexPath.section > 0 { if run == nil && p.enabled && !store.state.safe { editSetting(items(indexPath.section)[indexPath.row], record: p) }; return }
        if indexPath.row == 1, let run { run.cancel(); return }
        guard run == nil else { return }
        switch indexPath.row {
        case 0:
            if p.enabled { p.enabled = false; p.grants = []; if store.put(p) { sections = []; status = "Выключен" }; tableView.reloadData(); return }
            let unsupported = p.manifest.required.subtracting(GoldgramPluginManifest.supported)
            guard unsupported.isEmpty else { showPluginError("Не поддерживаются обязательные разрешения: " + unsupported.sorted().joined(separator: ", ")); return }
            let grants = p.manifest.required.union(p.manifest.optional.intersection(GoldgramPluginManifest.supported)).sorted()
            let alert = UIAlertController(title: "Разрешить локальное выполнение?", message: (grants.isEmpty ? "Без нативных разрешений" : grants.joined(separator: "\n")) + "\nНет доступа к Telegram, сети и секретам.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Разрешить", style: .default) { [weak self] _ in
                guard let self, !self.store.state.safe else { return }
                p.enabled = true; p.grants = grants
                if self.store.put(p) { self.execute(event: "plugin.start") } else { self.showPluginError("Не удалось сохранить.") }
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
        case 1: execute(event: "plugin.start")
        case 2:
            navigationController?.pushViewController(GoldgramPluginEditor(title: "JavaScript", text: p.code) { [weak self] code in
                guard let self, var current = self.store.record(self.id), !code.isEmpty, code.utf8.count <= GoldgramPluginStore.maxCode else { return }
                current.previousCode = current.code; current.code = code; current.enabled = false; current.grants = []; current.settingsSchema = nil
                if self.store.put(current) { self.sections = []; self.status = "Код обновлён; разрешите заново."; self.title = current.manifest.name; self.navigationController?.popViewController(animated: true); self.tableView.reloadData() }
                else { (self.navigationController?.topViewController)?.showPluginError("Не удалось сохранить.") }
            }, animated: true)
        case 3: showPluginError("Запрошено: " + p.manifest.required.sorted().joined(separator: ", ") + "\nДополнительно: " + p.manifest.optional.sorted().joined(separator: ", ") + "\nРазрешено: " + p.grants.joined(separator: ", "))
        case 4: showPluginError(logs.isEmpty ? "Нет записей." : logs.joined(separator: "\n"))
        case 5:
            guard let previous = p.previousCode else { showPluginError("Нет предыдущей версии."); return }
            p.previousCode = p.code; p.code = previous; p.enabled = false; p.grants = []; p.settingsSchema = nil
            if store.put(p) { sections = []; status = "Код восстановлен; разрешите заново."; title = p.manifest.name; tableView.reloadData() }
        default:
            let alert = UIAlertController(title: "Удалить плагин?", message: "Удалятся код и его локальные настройки.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in
                guard let self else { return }; var next = self.store.state
                next.plugins.removeAll { $0.id == self.id }
                if self.store.save(next) { self.navigationController?.popViewController(animated: true) }
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
        }
    }
    private func execute(event: String, key: String? = nil, value: Any? = nil) {
        guard run == nil, store.isCurrent(), !store.state.safe, let p = store.record(id), p.enabled,
              p.manifest.required.isSubset(of: Set(p.grants)), Set(p.grants).isSubset(of: GoldgramPluginManifest.supported) else { showPluginError("Включите плагин и выключите безопасный режим."); return }
        status = "Выполняется…"; tableView.reloadData()
        run = GoldgramPluginRun(host: view, record: p, event: event, key: key, value: value) { [weak self] result, error in
            guard let self else { return }; self.run = nil
            guard self.store.isCurrent(), let result, var current = self.store.record(self.id), current.enabled else {
                self.status = error ?? "Выполнение отменено."; self.tableView.reloadData(); return
            }
            guard let values = result["settings"] as? [String: Any], let storage = result["storage"] as? [String: Any],
                  let settingsEncoded = GoldgramPluginStore.encodeValues(values), let storageEncoded = GoldgramPluginStore.encodeValues(storage),
                  let rawSections = result["sections"] as? [[String: Any]],
                  let sections = GoldgramPluginStore.validatedSections(rawSections),
                  let schema = try? JSONSerialization.data(withJSONObject: sections), schema.count <= 220000 else {
                self.status = "Некорректные данные плагина."; self.tableView.reloadData(); return
            }
            if current.grants.contains("settings.read") { current.settings = settingsEncoded; current.settingsSchema = schema }
            if current.grants.contains("storage") { current.storage = storageEncoded }
            guard self.store.put(current) else { self.status = "Не удалось сохранить настройки."; self.tableView.reloadData(); return }
            self.sections = current.grants.contains("settings.read") ? sections : []
            self.logs = Array((self.logs + (result["logs"] as? [String] ?? [])).suffix(80))
            self.status = "Выполнено"; self.tableView.reloadData()
            if event == "settings.action", let last = (result["logs"] as? [String])?.last { self.showPluginError(last) }
        }
    }
    private func editSetting(_ item: [String: Any], record: GoldgramPluginRecord) {
        guard let key = item["key"] as? String, GoldgramPluginStore.safeKey(key), let kind = item["type"] as? String else { return }
        let old = GoldgramPluginStore.decodeValues(record.settings)[key] ?? item["default"] ?? ""
        let apply: (Any) -> Void = { [weak self] value in
            guard let self, self.store.isCurrent(), !self.store.state.safe, var current = self.store.record(self.id), current.enabled, current.grants.contains("settings.read") else { return }
            var values = GoldgramPluginStore.decodeValues(current.settings); values[key] = value
            guard let encoded = GoldgramPluginStore.encodeValues(values) else { self.showPluginError("Слишком большое значение."); return }
            current.settings = encoded
            if self.store.put(current) { self.execute(event: "settings.changed", key: key, value: value) }
        }
        if kind == "button" { execute(event: "settings.action", key: key); return }
        if kind == "toggle" { apply(!(old as? Bool ?? false)); return }
        if kind == "textarea" {
            navigationController?.pushViewController(GoldgramPluginEditor(title: item["title"] as? String ?? key, text: String(describing: old)) { [weak self] text in
                guard let self else { return }; self.navigationController?.popViewController(animated: false); apply(text)
            }, animated: true); return
        }
        let alert = UIAlertController(title: item["title"] as? String ?? key, message: nil, preferredStyle: .alert)
        if kind == "select" {
            for option in (item["options"] as? [[String: Any]] ?? []).prefix(50) {
                guard let value = option["value"] as? String else { continue }
                alert.addAction(UIAlertAction(title: option["title"] as? String ?? value, style: .default) { _ in apply(value) })
            }
        } else {
            alert.addTextField { field in field.text = String(describing: old); if kind == "slider" || kind == "stepper" { field.keyboardType = .numbersAndPunctuation } }
            alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak alert] _ in
                let text = alert?.textFields?.first?.text ?? ""
                if kind == "slider" || kind == "stepper" {
                    if let number = Double(text), number.isFinite { apply(max(item["min"] as? Double ?? 0, min(item["max"] as? Double ?? 100, number))) }
                } else { apply(text) }
            })
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
    }
}
