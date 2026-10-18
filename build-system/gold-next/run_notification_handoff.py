#!/usr/bin/env python3
"""Exercise production notification consent + handoff with an encoded cache fake."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'submodules/TelegramCore/Sources/State/GoldgramNativeHistory.swift').read_text()
def extract(start):
 a=s.index(start); b=s.index('{',a); depth=1; end=b+1
 while depth:
  depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[a:end]
source=r'''
import Foundation
struct RawId { let value: Int64; func _internalGetInt64Value() -> Int64 { value } }
struct PeerId { let value: Int64; var id: RawId { RawId(value: value) }; func toInt64() -> Int64 { value } }
struct ValueBoxKey: Hashable { let length: Int }
struct ItemCacheEntryId: Hashable { let collectionId: Int; let key: ValueBoxKey }
struct CodableEntry {
 let data: Data
 init?<T: Encodable>(_ value: T) { guard let data = try? JSONEncoder().encode(value) else { return nil }; self.data=data }
 func get<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type,from:data) }
}
final class Transaction {
 var cache: [ItemCacheEntryId: CodableEntry] = [:]
 func retrieveItemCacheEntry(id: ItemCacheEntryId) -> CodableEntry? { cache[id] }
 func putItemCacheEntry(id: ItemCacheEntryId, entry: CodableEntry) { cache[id]=entry }
}
var host = false
var consent = false
typealias Writer = (UnsafePointer<CChar>?) -> Int32
func goldgramNativeWriter() -> Writer? { host ? { _ in 1 } : nil }
func goldgramNativeHistoryEnabled() -> Bool { consent }
func goldgramCaptureSince(_ account: PeerId) -> Int32 { 123 }
'''
for start in ['private struct GoldgramCaptureSettings:', 'private struct GoldgramPendingEvent:', 'private struct GoldgramPendingEvents:']:
 source+='\n'+extract(start)
for line in s.splitlines():
 if line.startswith('private let goldgramSettingsKey ') or line.startswith('private let goldgramPendingKey '): source+='\n'+line
source+='\n'+extract('func goldgramCaptureEnabled(')+'\n'+extract('private func goldgramWrite(')
source+=r'''
let a = PeerId(value: 1), b = PeerId(value: 2)
let db = Transaction()
precondition(!goldgramCaptureEnabled(accountPeerId: a, transaction: db), "extension defaults to OFF")
host=true; consent=true
precondition(goldgramCaptureEnabled(accountPeerId: a, transaction: db))
host=false; consent=false // extension standard defaults do not inherit host defaults
precondition(goldgramCaptureEnabled(accountPeerId: a, transaction: db))
precondition(!goldgramCaptureEnabled(accountPeerId: b, transaction: db), "account identity is checked")
for index in 0..<700 {
 precondition(goldgramWrite(["accountId":1,"eventKind":0,"text":String(repeating:"я",count:4000),"messageId":index],transaction:db))
}
precondition(goldgramWrite(["accountId":1,"eventKind":2,"text":"Сохранённое удаление","messageId":42],transaction:db))
private let pending=db.retrieveItemCacheEntry(id: goldgramPendingKey)!.get(GoldgramPendingEvents.self)!
precondition(pending.items.count <= 512)
precondition(pending.items.reduce(0) { $0 + $1.data.count } <= 4 * 1024 * 1024)
precondition(pending.items.last?.kind == 2, "discard old observations before event bodies")
let replay = try! JSONSerialization.jsonObject(with: pending.items.last!.data) as! [String:Any]
precondition(replay["text"] as? String == "Сохранённое удаление")
host=true; consent=false
precondition(!goldgramCaptureEnabled(accountPeerId:a,transaction:db))
host=false
precondition(!goldgramCaptureEnabled(accountPeerId:a,transaction:db), "extension follows explicit OFF from host")
print("Goldgram #91: production notification consent, account isolation, Codable handoff and bounded event retention passed")
'''
with tempfile.TemporaryDirectory(prefix='goldgram-push-') as tmp:
 p=Path(tmp);(p/'main.swift').write_text(source)
 subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
