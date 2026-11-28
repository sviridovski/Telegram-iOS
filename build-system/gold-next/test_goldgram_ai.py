#!/usr/bin/env python3
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
s = (root / "submodules/ChatListUI/Sources/GoldgramAI.swift").read_text()
chat = (root / "submodules/TelegramUI/Sources/ChatController.swift").read_text()
protocol = s.split("private enum GoldgramAIProtocol {",1)[1].split("\nfinal class GoldgramAISettings",1)[0]
fixture = '''
let request = GoldgramAIProtocol.request(key:"test",model:"deepseek-chat",prompt:"prompt",draft:"source")!
precondition(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
precondition(request.httpMethod == "POST")
let obj = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String:Any]
let messages = obj["messages"] as! [[String:String]]
precondition(messages[0]["content"] == "prompt" && messages[1]["content"] == "source")
precondition(GoldgramAIProtocol.request(key:"test",model:"x",prompt:"p",draft:" ") == nil)
let data = Data(#"{"choices":[{"message":{"content":" answer "}}]}"#.utf8)
precondition(GoldgramAIProtocol.answer(data) == "answer")
precondition(GoldgramAIProtocol.answer(Data("{}".utf8)) == nil)
print("Goldgram #268 native AI request/response fixtures passed")
'''
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)/"main.swift"
    path.write_text("import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\nprivate enum GoldgramAIProtocol {"+protocol+fixture)
    subprocess.run(["swift",str(path)],check=True)
assert "kSecAttrAccessibleWhenUnlockedThisDeviceOnly" in s and "completionHandler(nil)" in s
assert "self.snapshot() == draft" in s and "self.token == token" in s
assert "session?.invalidateAndCancel()" in s and "Передать текст в DeepSeek?" in s
assert "self.goldgramAIEpoch &+= 1" in chat and "interactive: false" in chat
assert "self.presentationInterfaceState.copyProtectionEnabled" in chat
print("Goldgram #268 privacy/lifecycle source contracts passed")

# #270 confirmation policy is native, opt-in, scoped to the installed plugin.
plugins = (root / "submodules/ChatListUI/Sources/GoldgramPlugins.swift").read_text()
policy = plugins.split("private struct GoldgramPluginConfirmationPolicy:",1)[1].split("\nprivate struct GoldgramPluginRecord",1)[0]
fixture = '''
let grants = ["network.fetch", "chat.write"]
precondition(!GoldgramPluginConfirmationPolicy.skipRequest(nil, grants: grants, event: "floating.tap"))
precondition(!GoldgramPluginConfirmationPolicy.skipDraft(nil, grants: grants))
let p = GoldgramPluginConfirmationPolicy(allowRequestWithoutPrompt: true, allowDraftWithoutPreview: true)
precondition(GoldgramPluginConfirmationPolicy.skipRequest(p, grants: grants, event: "floating.tap"))
precondition(GoldgramPluginConfirmationPolicy.skipRequest(p, grants: grants, event: "context.tap"))
precondition(!GoldgramPluginConfirmationPolicy.skipRequest(p, grants: grants, event: "settings.action"))
precondition(!GoldgramPluginConfirmationPolicy.skipRequest(p, grants: [], event: "floating.tap"))
precondition(GoldgramPluginConfirmationPolicy.skipDraft(p, grants: grants))
precondition(!GoldgramPluginConfirmationPolicy.skipDraft(p, grants: []))
let decoded = try! JSONDecoder().decode(GoldgramPluginConfirmationPolicy.self, from: JSONEncoder().encode(p))
precondition(decoded == p)
private struct LegacyRecord: Codable { var confirmationPolicy: GoldgramPluginConfirmationPolicy? }
private let legacy = try! JSONDecoder().decode(LegacyRecord.self, from: Data("{}".utf8))
precondition(legacy.confirmationPolicy == nil)
print("Goldgram #270 confirmation policy fixtures passed")
'''
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)/"main.swift"
    path.write_text("import Foundation\nprivate struct GoldgramPluginConfirmationPolicy:"+policy+fixture.replace("let p =", "private let p =").replace("let decoded =", "private let decoded ="))
    subprocess.run(["swift",str(path)],check=True)
# Source contract follows the shared replacement path introduced in #287.
# The native update policy fixture in test_plugin_engine.py also exercises the
# actual consent reset on update and rollback.
replacement = plugins.split("static func replacement(_ current: GoldgramPluginRecord, code: String) -> GoldgramPluginRecord {", 1)[1].split("\n}\n", 1)[0]
assert "next.confirmationPolicy = nil" in replacement
assert "next.enabled = false" in replacement and "next.grants = []" in replacement
assert "let next = GoldgramPluginUpdate.replacement(current, code: code)" in plugins
assert "self.applyReplacement(code, expected: current.code, editor: true)" in plugins
assert "confirmReplacement(previous, expected: p.code, rollback: true)" in plugins
assert "_ = self.applyReplacement(code, expected: expected)" in plugins
assert "p.confirmationPolicy = nil" in plugins
assert "current.code == record.code" in plugins and "current.grants == record.grants" in plugins
assert "if self.skipRequestConfirmation() { send(); return }" in s
assert "if policy.skip { _ = insert(draft, answer); return }" in s
assert "snapshot() == draft" in s and "completionHandler(nil)" in s
print("Goldgram #270 confirmation consent source contracts passed")


# #271 routing and three-way settings/storage merge; pure Swift fixtures.
routing = plugins.split("enum GoldgramPluginRouting {",1)[1].split("\nstruct GoldgramPluginRegistration",1)[0]
fixture = '''
let a = UUID(), b = UUID()
let x = GoldgramPluginRouting.actionKey(a, "same:local")
let y = GoldgramPluginRouting.actionKey(b, "same:local")
precondition(x != y)
precondition(GoldgramPluginRouting.splitAction(x)?.0 == a)
precondition(GoldgramPluginRouting.splitAction(x)?.1 == "same:local")
precondition(GoldgramPluginRouting.splitAction("invalid") == nil)
precondition(GoldgramPluginRouting.splitAction(a.uuidString + ":") == nil)
precondition(GoldgramPluginRouting.merge(base:["one":"1"],latest:["one":"1","other":"2"],proposed:["one":"3"]) == ["one":"3","other":"2"])
precondition(GoldgramPluginRouting.merge(base:["one":"1"],latest:["one":"2"],proposed:["one":"3"]) == nil)
precondition(GoldgramPluginRouting.merge(base:["one":"1"],latest:["one":"1","other":"2"],proposed:[:]) == ["other":"2"])
precondition(GoldgramPluginRouting.merge(base:["one":"1"],latest:["one":"2"],proposed:["one":"1"]) == ["one":"2"])
precondition(GoldgramPluginRouting.merge(base:[:], latest:["existing":String(repeating:"x",count:40000)], proposed:["new":String(repeating:"x",count:40000)]) == nil)
var slots = GoldgramPluginExecutionSlots()
let lease = slots.reserve(account:"one",id:a)!
precondition(slots.reserve(account:"one",id:a) == nil)
precondition(slots.reserve(account:"one",id:b) != nil)
precondition(slots.reserve(account:"two",id:a) != nil)
precondition(slots.reserve(account:"one",id:UUID()) != nil)
precondition(slots.reserve(account:"one",id:UUID()) == nil)
slots.release(lease)
precondition(slots.reserve(account:"one",id:a) != nil)
print("Goldgram #271 routing, state merge and independent execution slots passed")
'''
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)/"main.swift"
    path.write_text("import Foundation\nenum GoldgramPluginRouting {"+routing+fixture)
    subprocess.run(["swift",str(path)],check=True)
assert "running.count < 4" in plugins and "Self.slots.release(lease)" in plugins
assert "return entries.flatMap" in plugins and "static func selected(account:" not in plugins
assert "GoldgramPluginRouting.splitAction(key)" in s and "GoldgramAIButtonGroup" in chat
assert "pendingAlert = alert" in s and "hit === self ? nil : hit" in s
print("Goldgram #271 multi-plugin source contracts passed")


# #272 exact route allow-list, catalog sanitization, freshness and bounds.
policy = s.split("enum GoldgramNetworkPolicy {",1)[1].split("// BEGIN GOLDGRAM_AI_USAGE_V1",1)[0]
fixture = '''
let root = "https://api.deepseek.com"
precondition(GoldgramNetworkPolicy.route(url:root+"/models",method:"GET",hasBody:false) == .models)
precondition(GoldgramNetworkPolicy.route(url:root+"/user/balance",method:"GET",hasBody:false) == nil)
precondition(GoldgramNetworkPolicy.route(url:root+"/user/balance",method:"GET",hasBody:false,allowBalance:true) == .balance)
precondition(GoldgramNetworkPolicy.route(url:root+"/user/balance",method:"GET",hasBody:true,allowBalance:true) == nil)
precondition(GoldgramNetworkPolicy.route(url:root+"/user/balance?x=1",method:"GET",hasBody:false,allowBalance:true) == nil)
precondition(GoldgramNetworkPolicy.route(url:root+"/models",method:"GET",hasBody:true) == nil)
precondition(GoldgramNetworkPolicy.route(url:root+"/models?secret=x",method:"GET",hasBody:false) == nil)
precondition(GoldgramNetworkPolicy.route(url:root+"/models",method:"POST",hasBody:true) == nil)
precondition(GoldgramNetworkPolicy.route(url:root+"/chat/completions",method:"POST",hasBody:true) == .completion)
precondition(GoldgramNetworkPolicy.route(url:root+"/chat/completions",method:"GET",hasBody:false) == nil)
precondition(GoldgramNetworkPolicy.route(url:"https://api.deepseek.com.evil.example/models",method:"GET",hasBody:false) == nil)
precondition(GoldgramNetworkPolicy.route(url:"http://127.0.0.1/models",method:"GET",hasBody:false) == nil)
precondition(GoldgramNetworkPolicy.modelID("deepseek-flash"))
precondition(!GoldgramNetworkPolicy.modelID("bad id"))
let catalogData = Data(#"{"object":"list","data":[{"id":"test-model","object":"model","name":"Test","context_window":1048576,"max_output_tokens":4096,"input_modalities":["text","image","invalid"],"effort":{"supported_levels":["low","high"],"default_level":"high"},"secret":"drop"},{"id":"test-model","object":"model"},{"id":"bad id","object":"model"}]}"#.utf8)
let models = GoldgramNetworkPolicy.catalog(catalogData)!
precondition(models.count == 1)
precondition(models[0]["id"] as? String == "test-model")
precondition(models[0]["secret"] == nil)
precondition(models[0]["context_window"] as? Int == 1048576)
precondition(models[0]["input_modalities"] as? [String] == ["image","text"])
precondition(GoldgramNetworkPolicy.catalog(Data(#"{"object":"list","data":[]}"#.utf8)) == nil)
precondition(GoldgramNetworkPolicy.catalog(Data(repeating:0,count:131073)) == nil)
precondition(GoldgramNetworkPolicy.fresh(updated:100,now:200))
precondition(!GoldgramNetworkPolicy.fresh(updated:100,now:86500))
precondition(!GoldgramNetworkPolicy.fresh(updated:100,now:99))
print("Goldgram #272 endpoint and catalog fixtures passed")
'''
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)/"main.swift"
    path.write_text("import Foundation\nenum GoldgramNetworkPolicy {"+policy+fixture)
    subprocess.run(["swift",str(path)],check=True)
assert 'self.config.readKey() == key' in s and 'GoldgramAINoRedirect()' in s
assert 'self.config.saveCatalog(models)' in s and 'if saved { clearCatalog() }' in s
assert 'modelSource' in plugins and 'refreshModels' in plugins
print("Goldgram #272 catalog and secure transport source contracts passed")


# #274 SSE parser: actual helper source, packet split, CRLF, UTF-8,
# bounded inputs, terminal usage and partial compatibility.
stream = s.split("struct GoldgramStreamOptions:",1)[1].split("// URLSession owns the delegate",1)[0]
fixture = r'''
let options = GoldgramStreamOptions()
precondition(!options.enabled && options.preview && options.reasoning && !options.partial && options.usage)
let encoded = try! JSONEncoder().encode(options)
precondition(try! JSONDecoder().decode(GoldgramStreamOptions.self, from: encoded) == options)
struct OldPluginRecord: Codable { var streamingOptions: GoldgramStreamOptions? }
precondition(try! JSONDecoder().decode(OldPluginRecord.self, from: Data("{}".utf8)).streamingOptions == nil)
var p = GoldgramSSEParser()
let chunks = ": keepalive\r\n\r\ndata: {\"choices\":[{\"delta\":{\"reasoning_content\":\"private\"}}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"Привет 🌍\"}}]}\n\n"
for byte in chunks.utf8 { precondition(p.feed(Data([byte]))) }
precondition(p.text == "Привет 🌍" && !p.thinking && !p.done)
precondition(p.feed(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"total_tokens\":12,\"completion_tokens\":4}}\n\n".utf8)))
precondition(p.usage["total_tokens"] == 12 && !p.done)
precondition(p.feed(Data("data: [DONE]\n\n".utf8)) && p.done)
let result = p.response(partial:false)
precondition(result["goldgram_partial"] as? Bool == false)
let msg = (result["choices"] as! [[String:Any]])[0]["message"] as! [String:String]
precondition(msg["content"] == "Привет 🌍" && msg["reasoning_content"] == nil)
precondition((p.response(partial:true)["choices"] as! [[String:Any]])[0]["finish_reason"] as? String == "cancelled")
var q = GoldgramSSEParser()
precondition(q.feed(Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"private\"}}]}\n\n".utf8)) && q.thinking && q.text.isEmpty)
precondition(!q.feed(Data("data: invalid\n\n".utf8)))
var oversized = GoldgramSSEParser()
precondition(!oversized.feed(Data(repeating:65,count:65537)))
var error = GoldgramSSEParser()
precondition(!error.feed(Data("data: {\"error\":{},\"choices\":[]}\n\n".utf8)))
var incomplete = GoldgramSSEParser()
precondition(incomplete.feed(Data("data: {\"choices\":[]}\n\n".utf8)) && !incomplete.done)
var multi = GoldgramSSEParser()
precondition(multi.feed(Data("data: {\"choices\":\ndata: []}\n\n".utf8)))
var limit = GoldgramSSEParser()
precondition(!limit.feed(Data(repeating:10,count:524289)))
var invalidEnd = GoldgramSSEParser()
precondition(!invalidEnd.feed(Data("data: [DONE]\n\n".utf8)))
var filtered = GoldgramSSEParser()
precondition(!filtered.feed(Data("data: {\"choices\":[{\"finish_reason\":\"content_filter\"}]}\n\n".utf8)))
print("Goldgram #274 SSE parser and default options fixtures passed")
'''
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)/"main.swift"
    path.write_text("import Foundation\nimport CoreFoundation\nenum GoldgramNetworkPolicy {"+policy+"\n"+s.split("// BEGIN GOLDGRAM_AI_USAGE_V1\n",1)[1].split("// END GOLDGRAM_AI_USAGE_V1",1)[0]+"\nstruct GoldgramStreamOptions:"+stream+fixture)
    subprocess.run(["swift",str(path)],check=True)
assert "streamingOptions() == options" in s and "streamGuard?() == true" in s
assert "task?.cancel(); session?.invalidateAndCancel()" in s
assert "self?.replyProgress" in plugins and "progressHandlers.delete" in plugins
assert "streamingOptions: GoldgramStreamOptions?" in plugins
print("Goldgram #274 lifecycle and policy source contracts passed")


# #275 UI options and bounds (exact native policy source, no UIKit).
ui = plugins.split("struct GoldgramPluginUIOptions:",1)[1].split("\nprivate struct GoldgramPluginRecord",1)[0]
fixture = '''
let options = GoldgramPluginUIOptions()
let actions = [["id":"one","title":"One"],["id":"two","title":"Two"]]
precondition(options.enhanced && options.visibleActions(actions) == actions)
var changed = options
changed.hiddenActions = ["one"]
precondition(changed.visibleActions(actions) == [actions[1]])
changed.contextEnabled = false
precondition(changed.visibleActions(actions).isEmpty)
precondition(try! JSONDecoder().decode(GoldgramPluginUIOptions.self,from:JSONEncoder().encode(changed)) == changed)
precondition(GoldgramPluginUIRules.number(7.3,min:0,max:10,step:0.5) == 7.5)
precondition(GoldgramPluginUIRules.number(100,min:0,max:10,step:0.5) == 10)
precondition(GoldgramPluginUIRules.number(-1,min:0,max:10,step:0.5) == 0)
precondition(GoldgramPluginUIRules.number(.nan,min:0,max:10,step:1) == nil)
precondition(GoldgramPluginUIRules.number(2,min:10,max:0,step:1) == nil)
precondition(GoldgramPluginUIRules.number(2,min:0,max:10,step:0) == nil)
precondition(GoldgramPluginUIRules.text("hello",limit:5) == "hello")
precondition(GoldgramPluginUIRules.text("hello",limit:4) == nil)
precondition(GoldgramPluginUIRules.text(String(repeating:"🌍",count:2100),limit:6000) == nil)
struct OldUIRecord: Codable { var uiOptions: GoldgramPluginUIOptions? }
precondition(try! JSONDecoder().decode(OldUIRecord.self,from:Data("{}".utf8)).uiOptions == nil)
print("Goldgram #275 UI options, action routing and numeric/text bounds passed")
'''
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)/"main.swift"
    path.write_text("import Foundation\nstruct GoldgramPluginUIOptions:"+ui+fixture)
    subprocess.run(["swift",str(path)],check=True)
assert "Self.visibleActions(p).contains" in plugins and "Self.visibleActions(current).contains" in plugins
assert "current.settingsSchema = schema" in plugins and "current.settingsSchema == record.settingsSchema" in plugins
assert "clearSections:" in plugins and 'result["schemaCleared"] as? Bool == true' in plugins
assert "UISwitch()" in plugins and "UISlider()" in plugins and "UIStepper()" in plugins and "UIProgressView(" in plugins
print("Goldgram #275 native UI and hidden-action source contracts passed")

# GoldAPI 1.4 balance and bounded persistent usage ledger policy.
usage_policy = s.split("// BEGIN GOLDGRAM_AI_USAGE_V1\n",1)[1].split("// END GOLDGRAM_AI_USAGE_V1",1)[0]
fixture = r'''
let sample = Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"2.50","granted_balance":"0.50","topped_up_balance":"2.00","secret":"drop"}]}"#.utf8)
let balance = GoldgramAIUsagePolicy.balance(sample)!
precondition(balance["is_available"] as? Bool == true)
let rows = balance["balance_infos"] as! [[String:String]]
precondition(rows[0]["total_balance"] == "2.50" && rows[0]["secret"] == nil)
precondition(GoldgramAIUsagePolicy.balance(Data(#"{"is_available":1,"balance_infos":[]}"#.utf8)) == nil)
precondition(GoldgramAIUsagePolicy.balance(Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"NaN","granted_balance":"0","topped_up_balance":"0"}]}"#.utf8)) == nil)
let usage = GoldgramAIUsagePolicy.tokens(["total_tokens": 10, "prompt_tokens": true, "completion_tokens": -1, "completion_tokens_details":["reasoning_tokens": 2], "secret": 1])
precondition(usage == ["total_tokens":10,"reasoning_tokens":2])
precondition(GoldgramAIUsagePolicy.elapsed(10,now:10.5) == 500)
var ledger = GoldgramAIUsageLedger(data:nil)
for i in 0..<140 { ledger.append(GoldgramAIUsageRecord(timestamp:Double(i),durationMs:10,outcome:"completed",model:"mock",httpStatus:200,tokens:usage)) }
precondition(ledger.records.count == 128 && ledger.records.first?.timestamp == 12)
let restored = GoldgramAIUsageLedger(data:ledger.encoded())
precondition(restored.records.count == 128)
let report = GoldgramAIUsagePolicy.report(restored.records)
precondition(report["requests"] as? Int == 128)
precondition((report["totals"] as? [String:Int64])?["total_tokens"] == 1280)
precondition(report["cost"] is NSNull)
print("Goldgram AI usage/balance native policy passed")
'''
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)/"main.swift"
    path.write_text("import Foundation\nimport CoreFoundation\n"+usage_policy+fixture)
    subprocess.run(["swift",str(path)],check=True)
assert 'allowBalance: true, completion: diagnosticNetworkCallback(callback)' in plugins
assert 'if route != .balance {' in s
assert 'usageStart = nil' in s and 'if route == .completion { self.beginUsage() }' in s

# Finance V2: pure Foundation pricing/aggregation fixture.
finance = s.split("// BEGIN GOLDGRAM_FINANCE_V2\n",1)[1].split("// END GOLDGRAM_FINANCE_V2",1)[0]
record = s.split("struct GoldgramAIUsageRecord: Codable {",1)[1].split("\nstruct GoldgramAIUsageLedger",1)[0]
fixture = r'''
let t = GoldgramFinancePricing.validFrom
func record(_ timestamp: Double, model: String? = "deepseek-flash", outcome: String = "completed", tokens: [String:Int] = ["prompt_tokens":1000,"prompt_cache_hit_tokens":500,"prompt_cache_miss_tokens":500,"completion_tokens":100,"total_tokens":1100]) -> GoldgramAIUsageRecord {
    GoldgramAIUsageRecord(timestamp:timestamp,durationMs:1000,outcome:outcome,model:model,httpStatus:200,tokens:tokens)
}
let price = GoldgramFinancePricing.estimate(record(t))!
precondition(price.low == Decimal(string:"0.0001365")! && price.high == price.low)
let weekday = GoldgramFinancePricing.estimate(record(t + 2*86400 + 2*3600))!
precondition(weekday.high == weekday.low*2)
precondition(GoldgramFinancePricing.estimate(record(t-1)) == nil)
precondition(GoldgramFinancePricing.estimate(record(t+30*86400)) == nil)
precondition(GoldgramFinancePricing.estimate(record(t,model:"unknown")) == nil)
precondition(GoldgramFinancePricing.estimate(record(t,outcome:"partial")) == nil)
precondition(GoldgramFinancePricing.estimate(record(t,tokens:["prompt_tokens":1000])) == nil)
precondition(GoldgramFinancePricing.positive("1.25") == Decimal(string:"1.25"))
precondition(GoldgramFinancePricing.positive("0") == nil && GoldgramFinancePricing.positive("nan") == nil)
var ledger = GoldgramFinanceLedger(data:nil,legacy:[record(t)])
precondition(GoldgramFinanceLedger.totals(ledger.selected(3,now:Date(timeIntervalSince1970:t))).priced == 0)
for _ in 0..<140 { ledger.append(record(t)) }
let totals = GoldgramFinanceLedger.totals(ledger.selected(0,now:Date(timeIntervalSince1970:t)))
precondition(ledger.recent.count == 128 && totals.requests == 141 && totals.priced == 140)
precondition(totals.tokens["total_tokens"] == 155100 && totals.high == price.high * 140)
let restored = GoldgramFinanceLedger(data:try! JSONEncoder().encode(ledger),legacy:[record(t)])
precondition(GoldgramFinanceLedger.totals(restored.selected(0,now:Date(timeIntervalSince1970:t))).requests == 141)
precondition(restored.selected(0,now:Date(timeIntervalSince1970:t+86400)).isEmpty)
precondition(!restored.selected(1,now:Date(timeIntervalSince1970:t+86400)).isEmpty)
ledger.append(record(t+366*86400))
precondition(ledger.days.count == 1)
print("Finance V2: 16 checks passed")
'''
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)/"main.swift"
    path.write_text("import Foundation\nstruct GoldgramAIUsageRecord: Codable {"+record+"\n"+finance+fixture)
    subprocess.run(["swift",str(path)],check=True,timeout=90)
assert 'route == .completion && self.config.financeBudgetReached()' in s
assert 'network.fetch(["url":"https://api.deepseek.com/user/balance","method":"GET"],allowBalance:true)' in s
assert 'GoldgramFinanceScreen(config:' in plugins
assert 'GoldgramPluginRun.releaseUpdateLease(lease)' in plugins


# AI Search Foundation: strict provider proposal, local dates, no message history in payload.
search = (root / "submodules/ChatListUI/Sources/GoldgramAuthorSearch.swift").read_text()
planner = search.split("// BEGIN GOLDGRAM_AI_SEARCH_FOUNDATION\n",1)[1].split("// END GOLDGRAM_AI_SEARCH_FOUNDATION",1)[0]
fixture = r'''
var cal = Calendar(identifier:.gregorian); cal.timeZone = TimeZone(secondsFromGMT:0)!
let now = GoldgramAIQueryPlan.day("2026-11-28",calendar:cal)!
private let p = GoldgramAIQueryPlan.parse(#"{"terms":["отпуск","ОТПУСК","график"],"author":"Лёша","relativeDays":7,"source":"all"}"#,now:now,calendar:cal)!
precondition(p.terms == ["отпуск","график"] && p.author == "Лёша" && p.source == 2)
precondition(p.dates!.0 == Int32(GoldgramAIQueryPlan.day("2026-11-22",calendar:cal)!.timeIntervalSince1970))
precondition(p.dates!.1 == Int32(GoldgramAIQueryPlan.day("2026-11-29",calendar:cal)!.timeIntervalSince1970)-1)
precondition(GoldgramAIQueryPlan.parse(#"{"terms":[],"from":"2026-02-30","through":"2026-03-01"}"#) == nil)
precondition(GoldgramAIQueryPlan.parse(#"{"terms":[],"from":"2026-11-30","through":"2026-11-01"}"#) == nil)
precondition(GoldgramAIQueryPlan.parse(#"{"terms":[],"relativeDays":true}"#) == nil)
precondition(GoldgramAIQueryPlan.parse(#"{"terms":[],"relativeDays":2,"relativeMonths":1}"#) == nil)
precondition(GoldgramAIQueryPlan.parse(#"{"terms":[],"peerId":"123"}"#) == nil)
precondition(GoldgramAIQueryPlan.parse(#"{"terms":[],"source":"secret"}"#) == nil)
precondition(GoldgramAIQueryPlan.parse(#"{"terms":[],"event":"edited","media":"photos"}"#) == nil)
precondition(GoldgramAIQueryPlan.parse(#"{"terms":["x","y","z","a","b","c","d"]}"#) == nil)
precondition(GoldgramAIQueryPlan.parse(#"{"terms":[],"author":null,"chat":null}"#) != nil)
precondition(GoldgramAIQueryPlan.parse(#"{"terms":[],"source":"telegram","event":"deleted"}"#) == nil)
precondition(GoldgramAIQueryPlan.parse(#"{"terms":[],"relativeMonths":3}"#,now:now,calendar:cal)!.dates!.0 == Int32(GoldgramAIQueryPlan.day("2026-08-28",calendar:cal)!.timeIntervalSince1970))
precondition(GoldgramAIQueryPlan.response(#"{"choices":[{"finish_reason":"length","message":{"content":"{\"terms\":[]}"}}]}"#) == nil)
precondition(GoldgramAIQueryPlan.response(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"terms\":[\"x\"]}"}}]}"#)?.terms == ["x"])
precondition(GoldgramAIQueryPlan.query(String(repeating:"a",count:1001)) == nil)
print("AI Search Foundation: 17 checks passed")
'''
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)/"main.swift"
    path.write_text("import Foundation\nimport CoreFoundation\n"+planner+fixture)
    subprocess.run(["swift",str(path)],check=True,timeout=90)
assert 'self.config = GoldgramAIConfig(account: id + ".native-search")' in search
assert '["role":"user","content":query]' in search
assert 'self.authorHint = plan.author; self.chatHint = plan.chat' in search
assert 'analyzed,authorHint == nil,chatHint == nil' in search
assert 'self.updateButtons(); self.submit()' in search
