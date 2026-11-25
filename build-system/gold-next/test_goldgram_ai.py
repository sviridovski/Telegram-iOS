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
