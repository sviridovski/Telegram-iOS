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
assert "current.confirmationPolicy = nil" in plugins and "p.confirmationPolicy = nil" in plugins
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
