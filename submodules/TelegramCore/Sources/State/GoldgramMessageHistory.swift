import Foundation
import Postbox

// Local-only presentation metadata. The real Telegram text/entities remain
// untouched for replies, copy, search, sending and server synchronization.
public final class GoldgramMessageHistoryAttribute: MessageAttribute {
    public let baseline: String
    public let originalObserved: Bool
    public let entities: [MessageTextEntity]
    public let revisions: [String]
    public let editDates: [Int32]

    init(baseline: String, originalObserved: Bool, entities: [MessageTextEntity], revisions: [String], editDates: [Int32]) {
        self.baseline = baseline; self.originalObserved = originalObserved
        self.entities = entities; self.revisions = revisions; self.editDates = editDates
    }
    public init(decoder: PostboxDecoder) {
        let baseline = decoder.decodeStringForKey("b", orElse: "")
        let original = decoder.decodeBoolForKey("o", orElse: false)
        let revisions = decoder.decodeStringArrayForKey("r")
        // #87 stored a first-observed edit as a baseline with zero revisions.
        // Keep the unknown original explicit and show that known edit in gray.
        let normalized = GoldgramEventPolicy.normalizeInlineHistory(baseline: baseline, originalObserved: original, revisions: revisions)
        let firstKnownEdit = !original && revisions.isEmpty
        self.baseline = normalized.baseline
        self.originalObserved = original
        self.entities = firstKnownEdit ? [] : (decoder.decodeObjectForKey("e") as? TextEntitiesMessageAttribute)?.entities ?? []
        self.revisions = normalized.revisions
        self.editDates = decoder.decodeInt32ArrayForKey("d")
    }
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeString(self.baseline, forKey: "b")
        encoder.encodeBool(self.originalObserved, forKey: "o")
        encoder.encodeObject(TextEntitiesMessageAttribute(entities: self.entities), forKey: "e")
        encoder.encodeStringArray(self.revisions, forKey: "r")
        encoder.encodeInt32Array(self.editDates, forKey: "d")
    }
}

// Full snapshots survive history-hole replacement. Ordinary baselines use a
// 5000-message ring; event-bearing snapshots stay until Clear Logs. Media bytes
// remain in MediaBox/the existing retained-media backup, not in this table.
// Stock Core collections are 0...55; application collections start at +64.
private let goldgramSnapshotCollection: Int8 = -100
private let goldgramArchivedSnapshotCollection: Int8 = -101
private extension GoldgramSnapshot {
    init?(_ message: StoreMessage, authorId: PeerId?, authorName: String?) {
        guard case let .Id(id) = message.id else { return nil }
        let encoder = PostboxEncoder()
        encoder.encodeGenericObjectArray(message.attributes.map { $0 as PostboxCoding }, forKey: "a")
        encoder.encodeGenericObjectArray(message.media.map { $0 as PostboxCoding }, forKey: "m")
        self.init(peer: id.peerId.toInt64(), namespace: id.namespace, id: id.id,
            unique: message.globallyUniqueId, grouping: message.groupingKey, thread: message.threadId,
            timestamp: message.timestamp, flags: Int32(bitPattern: message.flags.rawValue),
            tags: Int32(bitPattern: message.tags.rawValue), globalTags: Int32(bitPattern: message.globalTags.rawValue),
            localTags: Int32(bitPattern: message.localTags.rawValue), author: authorId?.toInt64(),
            authorName: authorName, text: message.text, objects: encoder.makeData(), forwardAuthor: message.forwardInfo?.authorId?.toInt64(),
            forwardSource: message.forwardInfo?.sourceId?.toInt64(),
            forwardMessagePeer: message.forwardInfo?.sourceMessageId?.peerId.toInt64(),
            forwardMessageNamespace: message.forwardInfo?.sourceMessageId?.namespace,
            forwardMessageId: message.forwardInfo?.sourceMessageId?.id, forwardDate: message.forwardInfo?.date,
            forwardSignature: message.forwardInfo?.authorSignature, forwardPsa: message.forwardInfo?.psaType,
            forwardFlags: message.forwardInfo?.flags.rawValue)
    }
    var message: StoreMessage {
        let decoder = PostboxDecoder(buffer: MemoryBuffer(data: self.objects))
        let decodedAttributes: [PostboxCoding] = decoder.decodeObjectArrayForKey("a")
        let decodedMedia: [PostboxCoding] = decoder.decodeObjectArrayForKey("m")
        let attributes = decodedAttributes.compactMap { $0 as? MessageAttribute }
        let media = decodedMedia.compactMap { $0 as? Media }
        let sourceMessageId: MessageId?
        if let peer = self.forwardMessagePeer, let namespace = self.forwardMessageNamespace, let id = self.forwardMessageId {
            sourceMessageId = MessageId(peerId: PeerId(peer), namespace: namespace, id: id)
        } else { sourceMessageId = nil }
        let forward = self.forwardDate.map { date in
            StoreMessageForwardInfo(authorId: self.forwardAuthor.map(PeerId.init), sourceId: self.forwardSource.map(PeerId.init),
                sourceMessageId: sourceMessageId, date: date, authorSignature: self.forwardSignature,
                psaType: self.forwardPsa, flags: MessageForwardInfo.Flags(rawValue: self.forwardFlags ?? 0))
        }
        return StoreMessage(id: MessageId(peerId: PeerId(self.peer), namespace: self.namespace, id: self.id),
            customStableId: nil, globallyUniqueId: self.unique, groupingKey: self.grouping, threadId: self.thread,
            timestamp: self.timestamp, flags: StoreMessageFlags(rawValue: UInt32(bitPattern: self.flags)), tags: MessageTags(rawValue: UInt32(bitPattern: self.tags)),
            globalTags: GlobalMessageTags(rawValue: UInt32(bitPattern: self.globalTags)), localTags: LocalMessageTags(rawValue: UInt32(bitPattern: self.localTags)),
            forwardInfo: forward, authorId: self.author.map(PeerId.init), text: self.text, attributes: attributes, media: media)
    }
}
private struct GoldgramSnapshotSlot: Codable { let id: MessageId }
private struct GoldgramSnapshotCursor: Codable { let next: Int32 }
private func goldgramSnapshotKey(_ id: MessageId, archived: Bool = false) -> ItemCacheEntryId {
    let key = ValueBoxKey(length: 16)
    key.setInt64(0, value: id.peerId.toInt64()); key.setInt32(8, value: id.namespace); key.setInt32(12, value: id.id)
    return ItemCacheEntryId(collectionId: archived ? goldgramArchivedSnapshotCollection : goldgramSnapshotCollection, key: key)
}
private func goldgramSlotKey(_ index: Int32) -> ItemCacheEntryId {
    let key = ValueBoxKey(length: 4); key.setInt32(0, value: index)
    return ItemCacheEntryId(collectionId: goldgramSnapshotCollection, key: key)
}
private func goldgramGlobalKey(_ id: Int32) -> ItemCacheEntryId {
    let key = ValueBoxKey(length: 5); key.setInt8(0, value: 1); key.setInt32(1, value: id)
    return ItemCacheEntryId(collectionId: goldgramSnapshotCollection, key: key)
}
func goldgramSnapshot(transaction: Transaction, id: MessageId) -> StoreMessage? {
    return (transaction.retrieveItemCacheEntry(id: goldgramSnapshotKey(id, archived: true)) ??
        transaction.retrieveItemCacheEntry(id: goldgramSnapshotKey(id)))?.get(GoldgramSnapshot.self)?.message
}
func goldgramPeerDisplayName(_ peer: Peer) -> String? {
    if let user = peer as? TelegramUser {
        let name = [user.firstName, user.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }
    if let channel = peer as? TelegramChannel { return channel.title }
    if let group = peer as? TelegramGroup { return group.title }
    return nil
}
public func goldgramSnapshotAuthor(transaction: Transaction, id: MessageId) -> (id: PeerId?, name: String?, sentAt: Int32)? {
    guard let record = (transaction.retrieveItemCacheEntry(id: goldgramSnapshotKey(id, archived: true)) ??
        transaction.retrieveItemCacheEntry(id: goldgramSnapshotKey(id)))?.get(GoldgramSnapshot.self) else { return nil }
    return (record.author.map(PeerId.init), record.authorName, record.timestamp)
}

func goldgramSnapshotGlobalId(transaction: Transaction, id: Int32) -> MessageId? {
    return transaction.retrieveItemCacheEntry(id: goldgramGlobalKey(id))?.get(GoldgramSnapshotSlot.self)?.id
}
@discardableResult
func goldgramSaveSnapshot(transaction: Transaction, message: StoreMessage) -> Bool {
    guard case let .Id(id) = message.id, id.namespace == Namespaces.Message.Cloud else { return false }
    let previousAuthor = goldgramSnapshotAuthor(transaction: transaction, id: id)
    let authorId = message.authorId ?? previousAuthor?.id
    let authorName = authorId.flatMap { transaction.getPeer($0) }.flatMap(goldgramPeerDisplayName) ?? previousAuthor?.name
    guard let snapshot = GoldgramSnapshot(message, authorId: authorId, authorName: authorName), let entry = CodableEntry(snapshot) else { return false }
    let archived = message.localTags.contains(goldgramDeletedMessageTag) || message.attributes.contains(where: { $0 is GoldgramMessageHistoryAttribute })
    let key = goldgramSnapshotKey(id, archived: archived)
    if archived {
        let changed = transaction.retrieveItemCacheEntry(id: key) != entry
        if changed { transaction.putItemCacheEntry(id: key, entry: entry) }
        if id.peerId.namespace != Namespaces.Peer.CloudChannel, let slot = CodableEntry(GoldgramSnapshotSlot(id: id)) {
            transaction.putItemCacheEntry(id: goldgramGlobalKey(id.id), entry: slot)
        }
        return changed
    }
    let existing = transaction.retrieveItemCacheEntry(id: key)
    if existing == entry { return false }
    if existing == nil {
        let cursorKey = goldgramSlotKey(-1)
        let next = transaction.retrieveItemCacheEntry(id: cursorKey)?.get(GoldgramSnapshotCursor.self)?.next ?? 0
        let slotKey = goldgramSlotKey(next)
        if let old = transaction.retrieveItemCacheEntry(id: slotKey)?.get(GoldgramSnapshotSlot.self)?.id {
            transaction.removeItemCacheEntry(id: goldgramSnapshotKey(old))
            if old.peerId.namespace != Namespaces.Peer.CloudChannel,
               transaction.retrieveItemCacheEntry(id: goldgramSnapshotKey(old, archived: true)) == nil {
                transaction.removeItemCacheEntry(id: goldgramGlobalKey(old.id))
            }
        }
        if let slot = CodableEntry(GoldgramSnapshotSlot(id: id)),
           let cursor = CodableEntry(GoldgramSnapshotCursor(next: (next + 1) % 5000)) {
            transaction.putItemCacheEntry(id: slotKey, entry: slot)
            transaction.putItemCacheEntry(id: cursorKey, entry: cursor)
            if id.peerId.namespace != Namespaces.Peer.CloudChannel { transaction.putItemCacheEntry(id: goldgramGlobalKey(id.id), entry: slot) }
        }
    }
    transaction.putItemCacheEntry(id: key, entry: entry)
    return true
}
public func goldgramClearSnapshots(transaction: Transaction, accountPeerId: PeerId) {
    transaction.clearItemCacheCollection(collectionId: goldgramSnapshotCollection)
    transaction.clearItemCacheCollection(collectionId: goldgramArchivedSnapshotCollection)
    UserDefaults.standard.set(Int(Date().timeIntervalSince1970), forKey: "GoldgramNativeHistorySinceV2.\(accountPeerId.id._internalGetInt64Value())")
}
