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
        self.baseline = decoder.decodeStringForKey("b", orElse: "")
        self.originalObserved = decoder.decodeBoolForKey("o", orElse: false)
        self.entities = (decoder.decodeObjectForKey("e") as? TextEntitiesMessageAttribute)?.entities ?? []
        self.revisions = decoder.decodeStringArrayForKey("r")
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
private struct GoldgramSnapshot: Codable {
    let peer: Int64
    let namespace: Int32
    let id: Int32
    let unique: Int64?
    let grouping: Int64?
    let thread: Int64?
    let timestamp: Int32
    let flags: UInt32
    let tags: UInt32
    let globalTags: UInt32
    let localTags: UInt32
    let author: Int64?
    let text: String
    let objects: Data
    let forwardAuthor: Int64?
    let forwardSource: Int64?
    let forwardMessage: MessageId?
    let forwardDate: Int32?
    let forwardSignature: String?
    let forwardPsa: String?
    let forwardFlags: Int32?

    init?(_ message: StoreMessage) {
        guard case let .Id(id) = message.id else { return nil }
        self.peer = id.peerId.toInt64(); self.namespace = id.namespace; self.id = id.id
        self.unique = message.globallyUniqueId; self.grouping = message.groupingKey; self.thread = message.threadId
        self.timestamp = message.timestamp; self.flags = message.flags.rawValue
        self.tags = message.tags.rawValue; self.globalTags = message.globalTags.rawValue; self.localTags = message.localTags.rawValue
        self.author = message.authorId?.toInt64(); self.text = message.text
        let encoder = PostboxEncoder()
        encoder.encodeGenericObjectArray(message.attributes.map { $0 as PostboxCoding }, forKey: "a")
        encoder.encodeGenericObjectArray(message.media.map { $0 as PostboxCoding }, forKey: "m")
        self.objects = encoder.makeData()
        self.forwardAuthor = message.forwardInfo?.authorId?.toInt64()
        self.forwardSource = message.forwardInfo?.sourceId?.toInt64()
        self.forwardMessage = message.forwardInfo?.sourceMessageId
        self.forwardDate = message.forwardInfo?.date
        self.forwardSignature = message.forwardInfo?.authorSignature
        self.forwardPsa = message.forwardInfo?.psaType
        self.forwardFlags = message.forwardInfo?.flags.rawValue
    }
    var message: StoreMessage {
        let decoder = PostboxDecoder(buffer: MemoryBuffer(data: self.objects))
        let decodedAttributes: [PostboxCoding] = decoder.decodeObjectArrayForKey("a")
        let decodedMedia: [PostboxCoding] = decoder.decodeObjectArrayForKey("m")
        let attributes = decodedAttributes.compactMap { $0 as? MessageAttribute }
        let media = decodedMedia.compactMap { $0 as? Media }
        let forward = self.forwardDate.map { date in
            StoreMessageForwardInfo(authorId: self.forwardAuthor.map(PeerId.init), sourceId: self.forwardSource.map(PeerId.init),
                sourceMessageId: self.forwardMessage, date: date, authorSignature: self.forwardSignature,
                psaType: self.forwardPsa, flags: MessageForwardInfo.Flags(rawValue: self.forwardFlags ?? 0))
        }
        return StoreMessage(id: MessageId(peerId: PeerId(self.peer), namespace: self.namespace, id: self.id),
            customStableId: nil, globallyUniqueId: self.unique, groupingKey: self.grouping, threadId: self.thread,
            timestamp: self.timestamp, flags: StoreMessageFlags(rawValue: self.flags), tags: MessageTags(rawValue: self.tags),
            globalTags: GlobalMessageTags(rawValue: self.globalTags), localTags: LocalMessageTags(rawValue: self.localTags),
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
func goldgramSnapshotGlobalId(transaction: Transaction, id: Int32) -> MessageId? {
    return transaction.retrieveItemCacheEntry(id: goldgramGlobalKey(id))?.get(GoldgramSnapshotSlot.self)?.id
}
func goldgramSaveSnapshot(transaction: Transaction, message: StoreMessage) {
    guard case let .Id(id) = message.id, id.namespace == Namespaces.Message.Cloud,
          let snapshot = GoldgramSnapshot(message), let entry = CodableEntry(snapshot) else { return }
    let archived = message.localTags.contains(goldgramDeletedMessageTag) || message.attributes.contains(where: { $0 is GoldgramMessageHistoryAttribute })
    let key = goldgramSnapshotKey(id, archived: archived)
    if archived {
        if transaction.retrieveItemCacheEntry(id: key) != entry { transaction.putItemCacheEntry(id: key, entry: entry) }
        if id.peerId.namespace != Namespaces.Peer.CloudChannel, let slot = CodableEntry(GoldgramSnapshotSlot(id: id)) {
            transaction.putItemCacheEntry(id: goldgramGlobalKey(id.id), entry: slot)
        }
        return
    }
    let existing = transaction.retrieveItemCacheEntry(id: key)
    if existing == entry { return }
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
}
public func goldgramClearSnapshots(transaction: Transaction, accountPeerId: PeerId) {
    transaction.clearItemCacheCollection(collectionId: goldgramSnapshotCollection)
    transaction.clearItemCacheCollection(collectionId: goldgramArchivedSnapshotCollection)
    UserDefaults.standard.set(Int(Date().timeIntervalSince1970), forKey: "GoldgramNativeHistorySinceV2.\(accountPeerId.id._internalGetInt64Value())")
}
