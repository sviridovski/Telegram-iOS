import Foundation
import UIKit
import WebKit
import UniformTypeIdentifiers

// #267: deliberately foreground, on-demand and local-only. Never expose Telegram,
// account objects, credentials, filesystem or network to imported JavaScript.
private struct GoldgramPluginManifest {
    static let supported: Set<String> = ["settings.read", "events", "console", "ui.read", "storage", "chat.read", "chat.write", "messages.read", "network.fetch", "ui.mutate", "clipboard"]
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

private struct GoldgramPluginConfirmationPolicy: Codable, Equatable {
    var allowRequestWithoutPrompt = false
    var allowDraftWithoutPreview = false
    static func skipRequest(_ policy: Self?, grants: [String], event: String) -> Bool {
        policy?.allowRequestWithoutPrompt == true && grants.contains("network.fetch") &&
            (event == "floating.tap" || event == "context.tap")
    }
    static func skipDraft(_ policy: Self?, grants: [String]) -> Bool {
        policy?.allowDraftWithoutPreview == true && grants.contains("chat.write")
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
    var floatingTitle: String?
    var contextActions: [[String: String]]?
    // Native-only consent policy; absent on older installs means always ask.
    var confirmationPolicy: GoldgramPluginConfirmationPolicy?
    var chatButtonHidden: Bool?
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
    private let account: String
    private(set) var state = GoldgramPluginState()
    private(set) var failure: String?
    init(account: String, isCurrent: @escaping () -> Bool) {
        self.isCurrent = isCurrent; self.account = account
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = root.appendingPathComponent("GoldgramPlugins", isDirectory: true).appendingPathComponent(account + ".json")
        refresh()
    }
    func refresh() {
        failure = nil
        if FileManager.default.fileExists(atPath: url.path) {
            do { state = try JSONDecoder().decode(GoldgramPluginState.self, from: Data(contentsOf: url)) }
            catch { failure = "Хранилище не читается. Исходный файл сохранён." }
        } else { state = GoldgramPluginState() }
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
            let account = self.account
            DispatchQueue.main.async { NotificationCenter.default.post(name: .goldgramPluginsChanged, object: account) }
            return true
        } catch { return false }
    }
    func record(_ id: UUID) -> GoldgramPluginRecord? { state.plugins.first { $0.id == id } }
    @discardableResult func put(_ record: GoldgramPluginRecord) -> Bool {
        refresh()
        guard failure == nil else { return false }
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
                guard let key = item["key"] as? String, (safeKey(key) || (key == "apiKey" && item["type"] as? String == "secret")), seen.insert(key).inserted,
                      let title = item["title"] as? String, title.count <= 160,
                      let kind = item["type"] as? String, ["toggle", "text", "textarea", "select", "slider", "stepper", "button", "secret"].contains(kind) else { return nil }
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

extension Notification.Name {
    static let goldgramPluginsChanged = Notification.Name("GoldgramPluginsChanged.v1")
}

enum GoldgramPluginRouting {
    static func actionKey(_ plugin: UUID, _ local: String) -> String { plugin.uuidString + ":" + local }
    static func splitAction(_ key: String) -> (UUID, String)? {
        guard let colon = key.firstIndex(of: ":"), let id = UUID(uuidString: String(key[..<colon])) else { return nil }
        let local = String(key[key.index(after: colon)...])
        guard !local.isEmpty, local.count <= 100 else { return nil }
        return (id, local)
    }
    static func merge(base: [String: String], latest: [String: String], proposed: [String: String]) -> [String: String]? {
        var result = latest
        for key in Set(base.keys).union(proposed.keys) where base[key] != proposed[key] {
            guard latest[key] == base[key] || latest[key] == proposed[key] else { return nil }
            result[key] = proposed[key]
        }
        guard result.count <= 128, result.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 65536 else { return nil }
        return result
    }
}

struct GoldgramPluginExecutionSlots {
    private var running = Set<String>()
    mutating func reserve(account: String, id: UUID) -> String? {
        let key = account + ":" + id.uuidString
        guard running.count < 4, running.insert(key).inserted else { return nil }
        return key
    }
    mutating func release(_ lease: String) { running.remove(lease) }
}

struct GoldgramPluginRegistration: Equatable {
    let id: UUID
    let name: String
    let title: String?
    let actions: [[String: String]]
    let code: String
    let grants: [String]
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
    private var broker: GoldgramPluginNetwork?
    private let grants: Set<String>
    private let interactive: Bool
    private let lease: String
    private let valid: () -> Bool
    private static var slots = GoldgramPluginExecutionSlots()
    static func reserve(account: String, id: UUID) -> String? {
        slots.reserve(account: account, id: id)
    }

    init(lease: String, host: UIView, record: GoldgramPluginRecord, event: String, key: String?, value: Any?, account: String = "", presenter: UIViewController? = nil, context: [String: Any] = [:], valid: @escaping () -> Bool = { true }, completion: @escaping ([String: Any]?, String?) -> Void) {
        self.lease = lease; self.valid = valid
        grants = Set(record.grants)
        interactive = event == "settings.action" || event == "floating.tap" || event == "context.tap"
        let credential = GoldgramAIConfig(account: account + "." + record.id.uuidString)
        var input: [String: Any] = ["source": record.code, "grants": record.grants, "event": event,
            "settings": GoldgramPluginStore.decodeValues(record.settings), "storage": GoldgramPluginStore.decodeValues(record.storage)]
        input["context"] = context
        input["pluginId"] = record.id.uuidString
        input["managedKey"] = !account.isEmpty && credential.readKey() != nil
        if let key { input["key"] = key }
        if let value { input["value"] = value }
        payload = (try? JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.completion = completion
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(registryChanged(_:)), name: .goldgramPluginsChanged, object: nil)
        if let presenter, interactive {
            let skipRequest = GoldgramPluginConfirmationPolicy.skipRequest(record.confirmationPolicy, grants: record.grants, event: event)
            broker = GoldgramPluginNetwork(config: credential, presenter: presenter, valid: valid, skipRequestConfirmation: {
                guard skipRequest, valid() else { return false }
                let latest = GoldgramPluginStore(account: account, isCurrent: valid)
                guard latest.failure == nil, !latest.state.safe, let current = latest.record(record.id),
                      current.enabled, current.code == record.code, current.grants == record.grants else { return false }
                return GoldgramPluginConfirmationPolicy.skipRequest(current.confirmationPolicy, grants: current.grants, event: event)
            })
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "goldgramResult")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        host.addSubview(view)
        web = view
        view.navigationDelegate = self
        let seconds: Double = event == "plugin.start" || event == "settings.changed" ? 8 : (broker == nil ? 8 : 300)
        let timeout = DispatchWorkItem { [weak self] in self?.finish(nil, "Превышено время выполнения.") }
        timer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
        view.loadHTMLString(Self.page, baseURL: nil)
    }
    @objc private func registryChanged(_ note: Notification) {
        guard let account = note.object as? String, lease.hasPrefix(account + ":") else { return }
        if !valid() { cancel() }
    }
    func cancel() { finish(nil, "Выполнение остановлено.") }
    private func finish(_ result: [String: Any]?, _ error: String?) {
        guard let done = completion else { return }
        completion = nil
        Self.slots.release(lease)
        NotificationCenter.default.removeObserver(self)
        broker?.cancel(); broker = nil
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
        guard valid() else { cancel(); return }
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
        guard valid() else { finish(nil, "Контекст плагина изменился."); return }
        guard message.name == "goldgramResult", message.frameInfo.isMainFrame,
              let raw = message.body as? String, raw.utf8.count <= 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            finish(nil, "Некорректный ответ плагина."); return
        }
        if let rpc = object["rpc"] as? Int {
            guard interactive, let broker, let method = object["method"] as? String, let args = object["args"] as? [String: Any] else { replyRPC(rpc, result: ["error": "Permission denied"]); return }
            let callback: ([String: Any]) -> Void = { [weak self] response in self?.replyRPC(rpc, result: response) }
            if method == "network.fetch", grants.contains("network.fetch") { broker.fetch(args, completion: callback) }
            else if method == "ui.select", grants.contains("ui.mutate") { broker.select(args, completion: callback) }
            else if method == "files.pick", grants.contains("storage") { broker.pickJSON(completion: callback) }
            else if method == "files.share", grants.contains("storage") { broker.shareJSON(args, completion: callback) }
            else { replyRPC(rpc, result: ["error": "Permission denied"]) }
            return
        }
        if let error = object["error"] as? String { finish(nil, String(error.prefix(500))) }
        else { finish(object, nil) }
    }

    private func replyRPC(_ id: Int, result: [String: Any]) {
        guard completion != nil, let data = try? JSONSerialization.data(withJSONObject: ["rpcResult": id, "result": result]), let json = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.goldReply(" + json + ");", completionHandler: nil)
    }

    private static let page = #"""
<!doctype html><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; worker-src blob:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
<script>
// BEGIN GOLDGRAM_WORKER_V1
function goldWorkerMain() {
  const send = self.postMessage.bind(self);
  const pending = new Map(); let serial = 0;
  self.onmessage = async function(e) {
    if (e.data && e.data.rpcResult !== undefined) { const fn = pending.get(e.data.rpcResult); if(fn){pending.delete(e.data.rpcResult);fn(e.data.result);} return; }
    const p = e.data;
    const grants = new Set(p.grants || []);
    const allowed = t => grants.has(t);
    const need = t => { if (!allowed(t)) throw Error("Permission denied: " + t); };
    const sections = [], logs = [], handlers = Object.create(null), buttons = Object.create(null), actions = Object.create(null), actionTitles = Object.create(null);
    const ctx = p.context || {}; let draft = typeof ctx.draft === "string" ? ctx.draft : null, changed = false, output = null, floating = null;
    const keyAlias = "sk-goldgram-managed";
    const isSecret = k => k === "apiKey" || k === "aicc_api_key_v2";
    const rpc = (method,args) => new Promise((resolve,reject)=>{const id=++serial; pending.set(id,r=>r && r.error ? reject(Error(r.error)) : resolve(r)); send(JSON.stringify({rpc:id,method,args}));});
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
        if (!it || (!validKey(it.key) && it.key !== "apiKey") || !["toggle","text","textarea","select","slider","stepper","button"].includes(it.type)) continue;
        if (it.key === "apiKey") { if(it.type==="text") items.push({type:"secret",key:"apiKey",title:String(it.title||"API key").slice(0,160)}); continue; }
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
    const base = {
      runtime:Object.freeze({apiVersion:()=>5,features:()=>({scopedChat:!!ctx.peerId,localOnly:!allowed("network.fetch")}),pluginId:()=>p.pluginId||"",hasPermission:allowed,grants:()=>Array.from(grants)}),
      settings:Object.freeze({addSection:section,define:section,getPlugin:(k,f)=>{need("settings.read");if(isSecret(k))return p.managedKey?keyAlias:f;return own(settings,k)?settings[k]:f;},setPlugin:(k,v)=>{need("settings.read");if(isSecret(k)){if(v===""||v===keyAlias)return true;throw Error("Use native secure field");}return write(settings,k,v);}}),
      storage:Object.freeze({get:k=>{need("storage");if(isSecret(k))return p.managedKey?keyAlias:null;return own(storage,k)?storage[k]:null;},set:(k,v)=>{need("storage");if(isSecret(k)){if(v===keyAlias&&p.managedKey)return true;throw Error("Use native secure field");}return write(storage,k,v);},getJSON:(k,f)=>{need("storage");return own(storage,k)?storage[k]:f;},setJSON:(k,v)=>{need("storage");return write(storage,k,v);},remove:k=>{need("storage");delete storage[k];}}),
      events:Object.freeze({on:(name,fn)=>{need("events");if (!["plugin.start","settings.changed","settings.action"].includes(name)||typeof fn!=="function")return null; const list=handlers[name]||(handlers[name]=[]);if(list.length<24)list.push(fn);return String(list.length);}}),
      console:logging,log,toast,app:Object.freeze({toast,alert:(title,text)=>toast(String(title)+"\n"+String(text))})
    };
    const localOutput=(title,text)=>{need("ui.read");output={kind:"sheet",title:String(title).slice(0,160),text:String(text).slice(0,16000)};return true;};
    base.app=Object.freeze({toast,alert:localOutput,restartHint:()=>toast("Обновите настройки")});
    if(allowed("chat.read")||allowed("chat.write")) base.chat=Object.freeze({
      currentPeerId:()=>{need("chat.read");return ctx.peerId||null;}, currentChatInfo:()=>{need("chat.read");return ctx.peerId?{peerId:ctx.peerId,type:ctx.type||"user",isGroup:ctx.type==="group"}:null;},
      draftText:()=>{need("chat.read");return draft||"";},setDraftText:t=>{need("chat.write");if(draft===null)throw Error("Open a writable chat");draft=String(t).slice(0,4096);changed=true;return true;},insertText:t=>{need("chat.write");if(draft===null)throw Error("Open a writable chat");draft=(draft+String(t)).slice(0,4096);changed=true;return true;},setTyping:()=>{need("ui.mutate");return true;} });
    if(allowed("messages.read")) {const rows=Array.isArray(ctx.messages)?ctx.messages:[];const visible=n=>rows.slice(-Math.max(1,Math.min(36,Number(n)||8)));base.messages=Object.freeze({visible,current:visible,get:id=>rows.find(m=>String(m.id)===String(id))||null,getSelectedMessage:()=>ctx.selectedMessage||null});}
    if(allowed("ui.mutate")||allowed("ui.read")) base.ui=Object.freeze({showToast:toast,showSheet:v=>localOutput(v.title||"AI",v.text||""),addFloatingButton:(cfg,fn)=>{need("ui.mutate");if(!cfg||typeof cfg.id!=="string"||typeof fn!=="function")throw Error("Invalid button");floating={id:cfg.id.slice(0,100),title:String(cfg.title||"AI").slice(0,12)};buttons[floating.id]=fn;return floating.id;},removeFloatingButton:id=>{need("ui.mutate");delete buttons[id];if(floating&&floating.id===id)floating=null;},addMessageContextAction:(cfg,fn)=>{need("ui.mutate");if(!cfg||typeof cfg.id!=="string"||typeof fn!=="function")throw Error("Invalid action");const id=cfg.id.slice(0,100);if(Object.keys(actions).length>=24&&!own(actions,id))throw Error("Too many actions");actions[id]=fn;actionTitles[id]=String(cfg.title||id).slice(0,160);return id;},removeMessageContextAction:id=>{need("ui.mutate");delete actions[id];delete actionTitles[id];},removeChatMenuButton:()=>{need("ui.mutate");},select:async(title,choices)=>{need("ui.mutate");const r=await rpc("ui.select",{title:String(title),choices});return r.value;},setChatHeaderBadge:()=>{need("ui.mutate");},clearChatHeaderBadge:()=>{need("ui.mutate");}});
    if(allowed("clipboard"))base.clipboard=Object.freeze({setText:t=>{output={kind:"clipboard",title:"Копировать результат",text:String(t).slice(0,16000)};return true;}});
    if(allowed("network.fetch"))base.network=Object.freeze({fetch:async(url,opt)=>{if(!opt||opt.proxy)throw Error("Telegram proxy not supported");const r=await rpc("network.fetch",{url:String(url),method:String(opt.method||"GET"),body:opt.body,timeoutMs:opt.timeoutMs||opt.timeout||75000});return {status:r.status,ok:r.status>=200&&r.status<300,text:()=>Promise.resolve(r.body),json:()=>Promise.resolve(JSON.parse(r.body))};}});
    if(allowed("storage")){
      const files=Object.create(null);
      base.files=Object.freeze({writeJSON:(name,value)=>{if(typeof name!=="string"||!name.endsWith(".json")||name.length>100||/[\\/]/.test(name))throw Error("Invalid filename");const raw=JSON.stringify(value);if(typeof raw!=="string"||raw.length>65536)throw Error("File too large");files[name]=raw;return {name};},readJSON:name=>own(files,name)?JSON.parse(files[name]):null,pick:async()=>{const r=await rpc("files.pick",{});return r.value===null?null:{value:r.value};},share:async name=>{if(!own(files,name))throw Error("Unknown file");await rpc("files.share",{name,body:files[name]});return true;}});
    }
    const api=Object.freeze(base);
    try {
      const run = new Function("GGAPI","GG","console",p.source);
      await run(api,api,logging);
      for (const fn of handlers[p.event] || []) await fn({key:p.key,value:p.value,pluginId:p.pluginId});
      if(p.event==="floating.tap"&&floating&&buttons[floating.id]) await buttons[floating.id]();
      if(p.event==="context.tap"&&actions[p.key])await actions[p.key]({message:ctx.selectedMessage});
      if(p.event==="settings.action"||p.event==="context.tap"){ await new Promise(resolve=>setTimeout(resolve,0)); let idle=0; while(idle<12){await new Promise(resolve=>setTimeout(resolve,100));idle=pending.size?0:idle+1;} }
      if(changed && !output)output={kind:"draft",title:"Результат плагина",text:draft};
      const raw = JSON.stringify({sections,settings,storage,logs,floating,output,contextActions:Object.keys(actions).map(id=>({id,title:actionTitles[id]}))});
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
  window.goldReply=data=>worker.postMessage(data);
  worker.onmessage=e=>{if(typeof e.data!=="string"){finish(JSON.stringify({error:"Invalid result"}));return;}try{const data=JSON.parse(e.data);if(data.rpc!==undefined){window.webkit.messageHandlers.goldgramResult.postMessage(e.data);return;}}catch(_){}finish(e.data);};
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
    private let aiAccount: String
    init(account: String, isCurrent: @escaping () -> Bool) {
        self.aiAccount = account
        store = GoldgramPluginStore(account: account, isCurrent: isCurrent)
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() { super.viewDidLoad(); title = "Goldgram Plugins" }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); store.refresh(); tableView.reloadData() }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Установленные" : (section == 1 ? "Управление" : "Встроенные сервисы") }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? (store.failure ?? "GGAPI: открытый чат и локальные настройки; подтверждения управляются для каждого плагина. Не все методы Ghostgram поддерживаются.") : "Импортируйте только доверенный код. Не вводите API-ключи в обычные настройки."
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? (store.isCurrent() ? store.state.plugins.count : 0) : (section == 1 ? 6 : 1) }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0 {
            let p = store.state.plugins[indexPath.row]
            cell.textLabel?.text = p.manifest.name
            cell.detailTextLabel?.text = p.manifest.version + " · " + (p.enabled ? "Разрешён" : "Выключен")
            cell.imageView?.image = UIImage(systemName: "puzzlepiece.extension")
        } else if indexPath.section == 2 {
            cell.textLabel?.text = "AI Command Center · Native"
            cell.detailTextLabel?.text = "DeepSeek · промпт и плавающая кнопка"
            cell.imageView?.image = UIImage(systemName: "sparkles")
        } else {
            cell.textLabel?.text = ["Вставить JavaScript", "Импортировать .js из файлов", "Установить тестовый плагин", "Безопасный режим", "Подтверждения плагинов", "Установить тесты многоплагинности"][indexPath.row]
            if indexPath.row == 3 { cell.detailTextLabel?.text = store.state.safe ? "Включён — выполнение заблокировано" : "Выключен" }
            if indexPath.row == 4 { cell.detailTextLabel?.text = "Запросы к сервисам и вставка ответа" }
        }
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard store.isCurrent(), store.failure == nil else { notice("Аккаунт изменился или хранилище недоступно."); return }
        if indexPath.section == 0 {
            let id = store.state.plugins[indexPath.row].id
            navigationController?.pushViewController(GoldgramPluginDetail(store: store, id: id, account: aiAccount), animated: true)
            return
        }
        if indexPath.section == 2 {
            navigationController?.pushViewController(GoldgramAISettings(account: aiAccount, isCurrent: store.isCurrent), animated: true)
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
        case 4: navigationController?.pushViewController(GoldgramPluginConfirmations(store: store), animated: true)
        case 5:
            store.refresh()
            var next = store.state
            for code in Self.multiExamples where !next.plugins.contains(where: { $0.code == code }) { next.plugins.append(GoldgramPluginRecord(code: code)) }
            if !store.save(next) { notice("Не удалось установить тесты.") }
            tableView.reloadData()
        default:
            store.refresh()
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
    static let multiExamples: [String] = ["A", "B"].map { suffix in
        """
        // @name Goldgram Test \(suffix)
        // @version 1.0
        // @permission.settings.read required
        // @permission.events required
        // @permission.ui.read required
        // @permission.ui.mutate required
        // @permission.storage required
        // @permission.messages.read required
        GGAPI.settings.addSection({title:"Тест \(suffix)",items:[{type:"text",key:"label",title:"Метка",default:"\(suffix)"},{type:"button",key:"reset",title:"Сбросить счётчик"}]});
        function hit(){ const n=Number(GGAPI.storage.get("count")||0)+1; GGAPI.storage.set("count",n); GGAPI.ui.showSheet({title:"Тест \(suffix)",text:GGAPI.settings.getPlugin("label","\(suffix)")+" · "+n}); }
        GGAPI.ui.addFloatingButton({id:"shared",title:"\(suffix)"},hit);
        GGAPI.ui.addMessageContextAction({id:"shared",title:"Тест \(suffix)"},hit);
        GGAPI.events.on("settings.action",p=>{if(p.key==="reset")GGAPI.storage.set("count",0);});
        """
    }
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

private final class GoldgramPluginConfirmations: UITableViewController {
    private let store: GoldgramPluginStore
    init(store: GoldgramPluginStore) { self.store = store; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() { super.viewDidLoad(); title = "Подтверждения плагинов" }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); store.refresh(); tableView.reloadData() }
    override func numberOfSections(in tableView: UITableView) -> Int { store.isCurrent() ? store.state.plugins.count + 1 : 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : 2 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard store.isCurrent(), section > 0, section <= store.state.plugins.count else { return nil }
        return store.state.plugins[section - 1].manifest.name
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "По умолчанию все запросы подтверждаются. Настройки действуют только для этого аккаунта и версии установленного кода. После изменения кода или повторного включения подтверждения возвращаются. Отправка сообщений в Telegram остаётся ручной." : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            cell.textLabel?.text = "Восстановить все подтверждения"
            cell.detailTextLabel?.text = "Для всех плагинов этого аккаунта"
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        guard store.isCurrent(), indexPath.section <= store.state.plugins.count else { return cell }
        let p = store.state.plugins[indexPath.section - 1]
        let network = indexPath.row == 0
        let allowed = p.enabled && p.grants.contains(network ? "network.fetch" : "chat.write")
        let skipped = network ? p.confirmationPolicy?.allowRequestWithoutPrompt == true : p.confirmationPolicy?.allowDraftWithoutPreview == true
        cell.textLabel?.text = network ? "Подтверждать запрос к DeepSeek" : "Предпросмотр перед вставкой"
        cell.detailTextLabel?.text = allowed ? (skipped ? "Выключено" : "Включено") : "Нет разрешения или плагин выключен"
        let toggle = UISwitch(); toggle.isOn = !skipped; toggle.isEnabled = allowed
        toggle.accessibilityLabel = cell.textLabel?.text
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            toggle?.setOn(!skipped, animated: false)
            guard let self, let index = self.store.state.plugins.firstIndex(where: { $0.id == p.id }) else { return }
            self.tableView(self.tableView, didSelectRowAt: IndexPath(row: network ? 0 : 1, section: index + 1))
        }, for: .valueChanged)
        cell.accessoryView = toggle
        cell.selectionStyle = allowed ? .default : .none
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard store.isCurrent(), store.failure == nil else { return }
        if indexPath.section == 0 {
            store.refresh()
            var next = store.state
            for i in next.plugins.indices { next.plugins[i].confirmationPolicy = nil }
            if !store.save(next) { showPluginError("Не удалось сохранить настройки.") }
            tableView.reloadData(); return
        }
        guard indexPath.section <= store.state.plugins.count else { return }
        let p = store.state.plugins[indexPath.section - 1]
        let network = indexPath.row == 0, grant = network ? "network.fetch" : "chat.write"
        guard p.enabled, p.grants.contains(grant) else { return }
        let skipped = network ? p.confirmationPolicy?.allowRequestWithoutPrompt == true : p.confirmationPolicy?.allowDraftWithoutPreview == true
        let apply: (Bool) -> Void = { [weak self] skip in
            guard let self, self.store.isCurrent() else { return }; self.store.refresh()
            guard var current = self.store.record(p.id),
                  current.enabled, current.code == p.code, current.grants == p.grants else { return }
            var policy = current.confirmationPolicy ?? GoldgramPluginConfirmationPolicy()
            if network { policy.allowRequestWithoutPrompt = skip } else { policy.allowDraftWithoutPreview = skip }
            current.confirmationPolicy = policy
            if !self.store.put(current) { self.showPluginError("Не удалось сохранить настройки.") }
            self.tableView.reloadData()
        }
        if skipped { apply(false); return }
        let message = network
            ? "Разрешить этому плагину при нажатии его кнопки или команды отправлять промпт, текст и доступный контекст переписки в api.deepseek.com без повторного окна? Запросы могут расходовать баланс. Фоновые запросы, другие адреса и запросы из настроек не разрешаются автоматически."
            : "Разрешить этому плагину заменять текущий неизменённый черновик без предпросмотра? Текст останется в поле ввода, а отправку сообщения вы выполните сами."
        let alert = UIAlertController(title: "Отключить подтверждение?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Разрешить", style: .default) { _ in apply(true) })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        present(alert, animated: true)
    }
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
    private let account: String
    private var run: GoldgramPluginRun?
    private var sections: [[String: Any]] = []
    private var logs: [String] = []
    private var status = "Не запускался"
    init(store: GoldgramPluginStore, id: UUID, account: String) { self.store = store; self.id = id; self.account = account; super.init(style: .insetGrouped) }
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
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if navigationController?.topViewController !== self || isBeingDismissed || navigationController?.isBeingDismissed == true { run?.cancel() } }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); store.refresh(); tableView.reloadData() }
    override func numberOfSections(in tableView: UITableView) -> Int { 1 + sections.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Управление" : sections[section-1]["title"] as? String }
    private func items(_ section: Int) -> [[String: Any]] { sections[section-1]["items"] as? [[String: Any]] ?? [] }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 8 : items(section).count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { section == 0 ? status : nil }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 2
        if indexPath.section == 0 {
            let enabled = store.record(id)?.enabled == true
            cell.textLabel?.text = [enabled ? "Выключить" : "Включить и разрешить", run == nil ? "Запустить / обновить настройки" : "Остановить", "Редактор JavaScript", "Разрешения", "Консоль", "Откатить код", "Удалить плагин", "Показывать кнопку в чате"][indexPath.row]
            if indexPath.row == 7 { cell.detailTextLabel?.text = store.record(id)?.chatButtonHidden == true ? "Выключено" : "Включено" }
        } else {
            let item = items(indexPath.section)[indexPath.row]
            let key = item["key"] as? String ?? ""
            cell.textLabel?.text = item["title"] as? String
            if item["type"] as? String == "secret" { cell.detailTextLabel?.text = GoldgramAIConfig(account: account + "." + id.uuidString).readKey() == nil ? "Не задан" : "Сохранён в Keychain" }
            else if item["type"] as? String != "button", let p = store.record(id) {
                let value = GoldgramPluginStore.decodeValues(p.settings)[key] ?? item["default"] ?? ""
                if item["type"] as? String == "toggle" { cell.detailTextLabel?.text = (value as? Bool == true) ? "Включено" : "Выключено" }
                else if item["type"] as? String == "select", let options = item["options"] as? [[String: Any]], let option = options.first(where: { $0["value"] as? String == value as? String }) { cell.detailTextLabel?.text = option["title"] as? String }
                else { cell.detailTextLabel?.text = String(describing: value) }
            }
        }
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        store.refresh()
        guard store.isCurrent(), var p = store.record(id) else { return }
        if indexPath.section > 0 { if run == nil && p.enabled && !store.state.safe { editSetting(items(indexPath.section)[indexPath.row], record: p) }; return }
        if indexPath.row == 1, let run { run.cancel(); return }
        guard run == nil else { return }
        switch indexPath.row {
        case 0:
            if p.enabled { p.enabled = false; p.grants = []; p.floatingTitle = nil; p.contextActions = nil; p.confirmationPolicy = nil; if store.put(p) { sections = []; status = "Выключен" }; tableView.reloadData(); return }
            let unsupported = p.manifest.required.subtracting(GoldgramPluginManifest.supported)
            guard unsupported.isEmpty else { showPluginError("Не поддерживаются обязательные разрешения: " + unsupported.sorted().joined(separator: ", ")); return }
            let grants = p.manifest.required.union(p.manifest.optional.intersection(GoldgramPluginManifest.supported)).sorted()
            let alert = UIAlertController(title: "Разрешить выполнение плагина?", message: (grants.isEmpty ? "Без нативных разрешений" : grants.joined(separator: "\n")) + "\nТолько открытый разрешённый чат, локальный черновик и подтверждённый запрос к DeepSeek. Без автоотправки и доступа к секретам.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Разрешить", style: .default) { [weak self] _ in
                guard let self else { return }; self.store.refresh()
                guard self.store.isCurrent(), self.store.failure == nil, !self.store.state.safe, let latest = self.store.record(self.id), latest.code == p.code, !latest.enabled else { return }
                p = latest; p.enabled = true; p.grants = grants; p.confirmationPolicy = nil
                if self.store.put(p) { self.execute(event: "plugin.start") } else { self.showPluginError("Не удалось сохранить.") }
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
        case 1: execute(event: "plugin.start")
        case 2:
            navigationController?.pushViewController(GoldgramPluginEditor(title: "JavaScript", text: p.code) { [weak self] code in
                guard let self else { return }; self.store.refresh()
                guard self.store.isCurrent(), var current = self.store.record(self.id), current.code == p.code, !code.isEmpty, code.utf8.count <= GoldgramPluginStore.maxCode else { return }
                current.previousCode = current.code; current.code = code; current.enabled = false; current.grants = []; current.settingsSchema = nil; current.floatingTitle = nil; current.contextActions = nil; current.confirmationPolicy = nil
                if self.store.put(current) { self.sections = []; self.status = "Код обновлён; разрешите заново."; self.title = current.manifest.name; self.navigationController?.popViewController(animated: true); self.tableView.reloadData() }
                else { (self.navigationController?.topViewController)?.showPluginError("Не удалось сохранить.") }
            }, animated: true)
        case 3: showPluginError("Запрошено: " + p.manifest.required.sorted().joined(separator: ", ") + "\nДополнительно: " + p.manifest.optional.sorted().joined(separator: ", ") + "\nРазрешено: " + p.grants.joined(separator: ", "))
        case 4: showPluginError(logs.isEmpty ? "Нет записей." : logs.joined(separator: "\n"))
        case 5:
            guard let previous = p.previousCode else { showPluginError("Нет предыдущей версии."); return }
            p.previousCode = p.code; p.code = previous; p.enabled = false; p.grants = []; p.settingsSchema = nil; p.floatingTitle = nil; p.contextActions = nil; p.confirmationPolicy = nil
            if store.put(p) { sections = []; status = "Код восстановлен; разрешите заново."; title = p.manifest.name; tableView.reloadData() }
        case 7:
            p.chatButtonHidden = !(p.chatButtonHidden ?? false)
            if !store.put(p) { showPluginError("Не удалось сохранить.") }; tableView.reloadData()
        default:
            let alert = UIAlertController(title: "Удалить плагин?", message: "Удалятся код и его локальные настройки.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in
                guard let self else { return }; self.store.refresh(); var next = self.store.state
                next.plugins.removeAll { $0.id == self.id }
                if self.store.save(next) { self.navigationController?.popViewController(animated: true) }
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
        }
    }
    private func execute(event: String, key: String? = nil, value: Any? = nil) {
        store.refresh()
        guard run == nil, store.isCurrent(), !store.state.safe, let p = store.record(id), p.enabled,
              p.manifest.required.isSubset(of: Set(p.grants)), Set(p.grants).isSubset(of: GoldgramPluginManifest.supported) else { showPluginError("Включите плагин и выключите безопасный режим."); return }
        guard let lease = GoldgramPluginRun.reserve(account: account, id: id) else { showPluginError("Плагин занят или достигнут лимит 4 выполнений."); return }
        status = "Выполняется…"; tableView.reloadData()
        run = GoldgramPluginRun(lease: lease, host: view, record: p, event: event, key: key, value: value, account: account, presenter: self, valid: { [weak self] in
            guard let self, self.store.isCurrent() else { return false }
            let latest = GoldgramPluginStore(account: self.account, isCurrent: self.store.isCurrent)
            guard latest.failure == nil, !latest.state.safe, let current = latest.record(self.id) else { return false }
            return current.enabled && current.code == p.code && current.grants == p.grants
        }) { [weak self] result, error in
            guard let self else { return }; self.run = nil; self.store.refresh()
            guard self.store.isCurrent(), self.store.failure == nil, !self.store.state.safe, let result, var current = self.store.record(self.id), current.enabled, current.code == p.code, current.grants == p.grants else {
                self.status = error ?? "Выполнение отменено."; self.tableView.reloadData(); return
            }
            guard let values = result["settings"] as? [String: Any], let storage = result["storage"] as? [String: Any],
                  let settingsEncoded = GoldgramPluginStore.encodeValues(values), let storageEncoded = GoldgramPluginStore.encodeValues(storage),
                  let rawSections = result["sections"] as? [[String: Any]],
                  let sections = GoldgramPluginStore.validatedSections(rawSections),
                  let schema = try? JSONSerialization.data(withJSONObject: sections), schema.count <= 220000 else {
                self.status = "Некорректные данные плагина."; self.tableView.reloadData(); return
            }
            guard let mergedSettings = GoldgramPluginRouting.merge(base: p.settings, latest: current.settings, proposed: settingsEncoded), let mergedStorage = GoldgramPluginRouting.merge(base: p.storage, latest: current.storage, proposed: storageEncoded) else { self.status = "Настройки изменились; повторите действие."; self.tableView.reloadData(); return }
            if current.grants.contains("settings.read") { current.settings = mergedSettings; current.settingsSchema = schema }
            if current.grants.contains("storage") { current.storage = mergedStorage }
            current.floatingTitle = current.grants.contains("ui.mutate") ? (result["floating"] as? [String: Any])?["title"] as? String : nil
            current.contextActions = current.grants.contains("ui.mutate") ? GoldgramPluginChatRun.validateActions(result["contextActions"]) : nil
            guard self.store.put(current) else { self.status = "Не удалось сохранить настройки."; self.tableView.reloadData(); return }
            self.sections = current.grants.contains("settings.read") ? sections : []
            self.logs = Array((self.logs + (result["logs"] as? [String] ?? [])).suffix(80))
            self.status = "Выполнено"; self.tableView.reloadData()
            if event == "settings.action" {
                if let output = result["output"] as? [String: Any], let text = output["text"] as? String { self.showPluginError(text) }
                else if let last = (result["logs"] as? [String])?.last { self.showPluginError(last) }
            }
        }
    }
    private func editSetting(_ item: [String: Any], record: GoldgramPluginRecord) {
        guard let key = item["key"] as? String, let kind = item["type"] as? String else { return }
        let credential = GoldgramAIConfig(account: account + "." + id.uuidString)
        if kind == "secret", key == "apiKey" {
            let alert = UIAlertController(title: item["title"] as? String ?? "API key", message: "Ключ сохраняется только в Keychain. Плагин получает условный идентификатор, не сам ключ.", preferredStyle: .alert)
            alert.addTextField { $0.isSecureTextEntry = true; $0.autocorrectionType = .no; $0.autocapitalizationType = .none }
            alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] _ in
                guard let self, self.store.isCurrent(), let text = alert?.textFields?.first?.text else { return }
                if credential.saveKey(text) { self.tableView.reloadData() } else { self.showPluginError("Не удалось сохранить ключ.") }
            }); alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true); return
        }
        guard GoldgramPluginStore.safeKey(key) else { return }
        if key == "btnDeleteKey", kind == "button", sections.flatMap({ $0["items"] as? [[String: Any]] ?? [] }).contains(where: { $0["type"] as? String == "secret" }) {
            let alert = UIAlertController(title: "Удалить ключ плагина?", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in guard let self, self.store.isCurrent() else { return }; if credential.deleteKey() { self.execute(event: "settings.action", key: key) } }); alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true); return
        }
        let old = GoldgramPluginStore.decodeValues(record.settings)[key] ?? item["default"] ?? ""
        let apply: (Any) -> Void = { [weak self] value in
            guard let self else { return }; self.store.refresh()
            guard self.store.isCurrent(), self.store.failure == nil, !self.store.state.safe, var current = self.store.record(self.id), current.enabled, current.code == record.code, current.grants == record.grants, current.grants.contains("settings.read") else { return }
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

// Native AI is opt-in, and the manager's account-specific safe mode applies to it as well.
func goldgramAIAllowed(account: String) -> Bool {
    let store = GoldgramPluginStore(account: account, isCurrent: { true })
    return store.failure == nil && !store.state.safe
}


// Only an enabled plugin that registered its own floating button is selected.
@MainActor
final class GoldgramPluginChatRun {
    private var run: GoldgramPluginRun?
    static func registrations(account: String) -> [GoldgramPluginRegistration] {
        let store = GoldgramPluginStore(account: account, isCurrent: { true })
        guard store.failure == nil, !store.state.safe else { return [] }
        return store.state.plugins.compactMap { p in
            guard p.enabled, p.grants.contains("ui.mutate"), p.manifest.required.isSubset(of: Set(p.grants)), Set(p.grants).isSubset(of: GoldgramPluginManifest.supported) else { return nil }
            let title = p.chatButtonHidden == true ? nil : p.floatingTitle
            let actions = p.grants.contains("messages.read") ? validateActions(p.contextActions) : []
            guard title != nil || !actions.isEmpty else { return nil }
            return GoldgramPluginRegistration(id: p.id, name: p.manifest.name, title: title, actions: actions, code: p.code, grants: p.grants)
        }
    }
    static func authorized(account: String, registration: GoldgramPluginRegistration) -> Bool {
        let store = GoldgramPluginStore(account: account, isCurrent: { true })
        guard store.failure == nil, !store.state.safe, let p = store.record(registration.id), p.enabled else { return false }
        return p.code == registration.code && p.grants == registration.grants
    }
    static func validateActions(_ raw: Any?) -> [[String: String]] {
        guard let list = raw as? [[String: String]] else { return [] }
        var seen = Set<String>()
        return Array(list.filter { item in guard let id = item["id"], let title = item["title"], !id.isEmpty, id.count <= 100, !title.isEmpty, title.count <= 160 else { return false }; return seen.insert(id).inserted }.prefix(24))
    }
    static func draftPolicy(account: String, id: UUID) -> (allowed: Bool, skip: Bool) {
        let store = GoldgramPluginStore(account: account, isCurrent: { true })
        guard store.failure == nil, !store.state.safe, let current = store.record(id), current.enabled,
              current.grants.contains("chat.write"), registrations(account: account).contains(where: { $0.id == id }) else { return (false, false) }
        return (true, GoldgramPluginConfirmationPolicy.skipDraft(current.confirmationPolicy, grants: current.grants))
    }
    static func menu(account: String) -> [[String: String]] {
        let entries = registrations(account: account)
        return entries.flatMap { p in
            p.actions.compactMap { action -> [String: String]? in
                guard let id = action["id"], let title = action["title"] else { return nil }
                return ["id": GoldgramPluginRouting.actionKey(p.id, id), "title": entries.count == 1 ? title : p.name + " · " + title]
            }
        }
    }
    func cancel() { let old = run; run = nil; old?.cancel() }
    func start(account: String, presenter: UIViewController, id: UUID, context: [String: Any], event: String = "floating.tap", key: String? = nil, valid: @escaping () -> Bool, completion: @escaping ([String: Any]?, String?) -> Void) {
        let store = GoldgramPluginStore(account: account, isCurrent: valid)
        guard valid(), store.failure == nil, !store.state.safe, let p = store.record(id), p.enabled, p.grants.contains("ui.mutate"),
              p.manifest.required.isSubset(of: Set(p.grants)), Set(p.grants).isSubset(of: GoldgramPluginManifest.supported),
              (event == "floating.tap" && p.floatingTitle != nil && p.chatButtonHidden != true) || (event == "context.tap" && p.grants.contains("messages.read") && Self.validateActions(p.contextActions).contains(where: { $0["id"] == key })) else { completion(nil, "Действие плагина недоступно."); return }
        guard let lease = GoldgramPluginRun.reserve(account: account, id: id) else { completion(nil, "Плагин занят или достигнут лимит 4 выполнений."); return }
        let stillValid = {
            guard valid() else { return false }
            let latest = GoldgramPluginStore(account: account, isCurrent: valid)
            guard latest.failure == nil, !latest.state.safe, let current = latest.record(id) else { return false }
            return current.enabled && current.code == p.code && current.grants == p.grants &&
                ((event == "floating.tap" && current.floatingTitle != nil && current.chatButtonHidden != true) || (event == "context.tap" && Self.validateActions(current.contextActions).contains(where: { $0["id"] == key })))
        }
        var input = context
        if !p.grants.contains("messages.read") { input.removeValue(forKey: "messages"); input.removeValue(forKey: "selectedMessage") }
        if !p.grants.contains("chat.read") { input.removeValue(forKey: "draft"); input.removeValue(forKey: "peerId"); input.removeValue(forKey: "type") }
        run = GoldgramPluginRun(lease: lease, host: presenter.view, record: p, event: event, key: key, value: nil, account: account, presenter: presenter, context: input, valid: stillValid) { [weak self] result, error in
            guard let self else { return }; self.run = nil
            guard stillValid(), let result else { completion(nil, error ?? "Чат изменился."); return }
            let latest = GoldgramPluginStore(account: account, isCurrent: valid)
            guard var current = latest.record(id), let settings = result["settings"] as? [String: Any], let storage = result["storage"] as? [String: Any],
                  let encoded = GoldgramPluginStore.encodeValues(settings), let stored = GoldgramPluginStore.encodeValues(storage) else { completion(nil, "Некорректный результат."); return }
            guard let mergedSettings = GoldgramPluginRouting.merge(base: p.settings, latest: current.settings, proposed: encoded), let mergedStorage = GoldgramPluginRouting.merge(base: p.storage, latest: current.storage, proposed: stored) else { completion(nil, "Настройки изменились; повторите действие."); return }
            if current.grants.contains("settings.read") { current.settings = mergedSettings }
            if current.grants.contains("storage") { current.storage = mergedStorage }
            if current.grants.contains("ui.mutate") { current.contextActions = Self.validateActions(result["contextActions"]); current.floatingTitle = (result["floating"] as? [String: Any])?["title"] as? String }
            guard latest.put(current) else { completion(nil, "Не удалось сохранить настройки."); return }
            let output = result["output"] as? [String: Any]
            if let kind = output?["kind"] as? String {
                guard (kind == "draft" && current.grants.contains("chat.write")) || (kind == "clipboard" && current.grants.contains("clipboard")) || (kind == "sheet" && current.grants.contains("ui.read")) else { completion(nil, "Недостаточно разрешений."); return }
            }
            completion(output, output == nil ? (result["logs"] as? [String])?.last : nil)
        }
    }
}
