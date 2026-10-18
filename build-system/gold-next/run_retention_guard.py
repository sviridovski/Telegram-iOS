#!/usr/bin/env python3
"""Run production retention/validation decisions with a small transaction fake.

This is a unit fixture, not a substitute for the full host build or device test.
Extract functions so the tested policy cannot drift into a duplicated model.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
core = root / 'submodules/TelegramCore/Sources/State'
native = (core / 'GoldgramNativeHistory.swift').read_text()
validation = (core / 'HistoryViewStateValidation.swift').read_text()
def extract(source, start):
    begin = source.index(start)
    brace = source.index('{', begin)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[begin:end]
stubs = r'''
import Foundation
struct PeerId: Hashable { let value: Int }
struct MessageId: Hashable { let peerId: PeerId; let namespace: Int }
enum Namespaces { enum Message { static let Cloud = 0 } }
struct LocalMessageTags: OptionSet { let rawValue: Int }
let goldgramDeletedMessageTag = LocalMessageTags(rawValue: 1 << 30)
struct ChannelState { let invalidatedPts: Int32? }
class ChannelMessageStateVersionAttribute { let pts: Int32; init(_ pts: Int32) { self.pts = pts } }
class AutoremoveTimeoutMessageAttribute {}
class AutoclearTimeoutMessageAttribute {}
struct Message { let id: MessageId; var localTags: LocalMessageTags; var attributes: [Any] }
enum Update { case update(Message) }
final class Transaction {
    var rows: [MessageId: Message] = [:]
    var timers: [MessageId: Set<Int>] = [:]
    var writes = 0
    func getMessage(_ id: MessageId) -> Message? { rows[id] }
    func updateMessage(_ id: MessageId, preprocess: Bool, update: (Message) -> Update) {
        precondition(!preprocess, "maintenance must not manufacture an edit")
        if let current = rows[id], case let .update(message) = update(current) { rows[id] = message; writes += 1 }
    }
    func clearTimestampBasedAttribute(id: MessageId, tag: Int) { timers[id]?.remove(tag) }
}
// Fake storage adapter: the guard must ask for normalization and avoid recapture.
func goldgramStoredMessage(_ message: Message, localTags: LocalMessageTags) -> Message {
    var result = message
    result.localTags = localTags
    result.attributes.removeAll { $0 is AutoremoveTimeoutMessageAttribute || $0 is AutoclearTimeoutMessageAttribute }
    return result
}
'''
cases = r'''
let peer = PeerId(value: 1)
let id = MessageId(peerId: peer, namespace: 0)
let db = Transaction()
precondition(!goldgramPreserveRetained(transaction: db, id: id))
let live = Message(id: id, localTags: [], attributes: [AutoremoveTimeoutMessageAttribute()])
db.rows[id] = live; db.timers[id] = [0, 1]
precondition(!goldgramPreserveRetained(transaction: db, id: id))
precondition(db.timers[id] == [0, 1] && db.writes == 0, "ordinary timers stay active")
precondition(!HistoryState.channel(peer, ChannelState(invalidatedPts: 10)).isMessageValid(live))
var retained = live
retained.localTags.insert(goldgramDeletedMessageTag)
retained.attributes.append(AutoclearTimeoutMessageAttribute())
db.rows[id] = retained
// Delayed timer callback, then repeated navigation and newer channel invalidation.
for pts in [Int32(10), 20, 1000] {
    precondition(goldgramPreserveRetained(transaction: db, id: id))
    let row = db.rows[id]!
    precondition(row.localTags.contains(goldgramDeletedMessageTag))
    precondition(row.attributes.isEmpty && db.timers[id]!.isEmpty)
    precondition(HistoryState.channel(peer, ChannelState(invalidatedPts: pts)).isMessageValid(row))
}
precondition(db.writes == 1, "repeat expiry must not rewrite or create revisions")
let scheduledId = MessageId(peerId: peer, namespace: 1)
db.rows[scheduledId] = Message(id: scheduledId, localTags: goldgramDeletedMessageTag, attributes: [])
precondition(!goldgramPreserveRetained(transaction: db, id: scheduledId))
precondition(!HistoryState.scheduledMessages(peer).isMessageValid(db.rows[scheduledId]!))
// Explicit local cleanup is still possible; no global delete interception.
db.rows.removeValue(forKey: id)
precondition(!goldgramPreserveRetained(transaction: db, id: id))
print("Goldgram #90: production guard keeps retained rows valid across expiry/navigation, preserves ordinary timers and explicit cleanup")
'''
source = stubs + '\n' + extract(native, 'func goldgramPreserveRetained(') + '\n' + extract(validation, 'private enum HistoryState {') + '\n' + cases
with tempfile.TemporaryDirectory(prefix='goldgram-retention-') as temp:
    path = Path(temp)
    (path / 'main.swift').write_text(source)
    subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
