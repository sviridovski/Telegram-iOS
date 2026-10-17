import Foundation
import Darwin
import Postbox
import SwiftSignalKit

@inline(never)
@_cdecl("goldgram_native_history_host_v1")
public func goldgramNativeHistoryHostV1() -> Int32 { return 1 }

// Persisted in Postbox's existing local-tags column; no registration/decoder.
// Stock TelegramCore currently reserves only bits 0 and 1.
public let goldgramDeletedMessageTag = LocalMessageTags(rawValue: 1 << 30)
private typealias GoldgramEventWriter = @convention(c) (UnsafePointer<CChar>?) -> Int32
private func goldgramNativeWriter() -> GoldgramEventWriter? {
    guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "goldgram_capture_event_v1") else { return nil }
    return unsafeBitCast(symbol, to: GoldgramEventWriter.self)
}

func goldgramNativeHistoryEnabled() -> Bool {
    return goldgramNativeHistoryHostV1() == 1 && goldgramNativeWriter() != nil && UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled")
}

private func goldgramKind(_ id: PeerId, _ peer: Peer?) -> Int32? {
    switch id.namespace {
    case Namespaces.Peer.CloudUser: return 0
    case Namespaces.Peer.CloudGroup: return 1
    case Namespaces.Peer.CloudChannel:
        guard let peer = peer as? TelegramChannel else { return nil }
        switch peer.info { case .group: return 2; case .broadcast: return 3 }
    default: return nil
    }
}

private func goldgramMediaKeys(_ media: [Media]) -> [String] {
    // Web-page refreshes, views and reactions are not user content edits.
    return media.compactMap { value in
        if value is TelegramMediaWebpage || value is TelegramMediaAction { return nil }
        guard let id = value.id else { return nil }
        return "\(id.namespace):\(id.id)"
    }
}

private func goldgramArchiveText(_ text: String, _ media: [Media]) -> String {
    if !text.isEmpty { return text }
    if let image = media.first(where: { $0 is TelegramMediaImage }) as? TelegramMediaImage {
        if let representation = image.representations.last {
            return "[Фото \(representation.dimensions.width)×\(representation.dimensions.height)]"
        }
        return "[Фото]"
    }
    if let file = media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile {
        return file.isVideo ? "[Видео]" : file.isVoice ? "[Голосовое сообщение]" : "[Файл]"
    }
    return media.isEmpty ? "[Без текста]" : "[Медиа / без текста]"
}

@discardableResult
private func goldgramWrite(_ payload: [String: Any]) -> Bool {
    guard let writer = goldgramNativeWriter(),
          let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else { return false }
    return json.withCString { writer($0) == 1 }
}

// First activation of the corrected logger, per authenticated account. Old
// edit dates loaded by scrolling cannot become new archive events.
private func goldgramCaptureSince(_ account: PeerId) -> Int32 {
    let key = "GoldgramNativeHistorySinceV2.\(account.id._internalGetInt64Value())"
    let value = UserDefaults.standard.integer(forKey: key)
    if value > 0 { return Int32(clamping: value) }
    let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
    UserDefaults.standard.set(Int(now), forKey: key)
    return now
}

// Returns local history metadata to persist together with the server version.
private func goldgramCaptureMutation(accountPeerId: PeerId, transaction: Transaction,
    message: StoreMessage, previous: StoreMessage?) -> GoldgramMessageHistoryAttribute? {
    let history = previous?.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) as? GoldgramMessageHistoryAttribute
    guard case let .Id(id) = message.id,
          let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)) else { return history }
    let edited = message.attributes.compactMap { $0 as? EditedMessageAttribute }.first
    let entities = (message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    let oldEntities = (previous?.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    let verified = GoldgramEventPolicy.shouldArchiveEdit(previousText: previous?.text, currentText: message.text,
        previousMedia: previous.map { goldgramMediaKeys($0.media) } ?? [], currentMedia: goldgramMediaKeys(message.media),
        entitiesChanged: oldEntities != entities, editDate: edited?.date ?? 0, hidden: edited?.isHidden ?? true,
        captureSince: goldgramCaptureSince(accountPeerId),
        previousEditDate: (previous?.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date ?? 0)
    guard verified else { return history }
    // A replay of an identical version is not another revision; there is no
    // observation-only backfill from arbitrary historical messages anymore.
    let sender = message.authorId ?? previous?.authorId
    var payload: [String: Any] = [
        "accountId": accountPeerId.id._internalGetInt64Value(), "peerKind": kind,
        "peerId": id.peerId.id._internalGetInt64Value(), "messageId": id.id, "eventKind": 1,
        "text": goldgramArchiveText(message.text, message.media), "changed": true,
        "visibleEdit": true, "editedAt": Int64(edited?.date ?? 0) * 1000,
        "senderId": sender?.id._internalGetInt64Value() ?? 0,
        "senderKind": sender.flatMap { goldgramKind($0, transaction.getPeer($0)) } ?? -1,
        "sentAt": Int64(message.timestamp) * 1000, "threadId": message.threadId ?? 0,
        "mediaKeys": goldgramMediaKeys(message.media), "retained": false
    ]
    if let previous {
        payload["beforeText"] = goldgramArchiveText(previous.text, previous.media)
        payload["beforeMediaKeys"] = goldgramMediaKeys(previous.media)
        payload["originalObserved"] = !previous.attributes.contains(where: { $0 is EditedMessageAttribute })
    }
    guard goldgramWrite(payload) else { return history }
    // An unavailable original is never invented. Start inline history with the
    // earliest actually received version, labelled honestly by the renderer.
    let baseline = history?.baseline ?? previous?.text ?? ""
    let original = history?.originalObserved ?? (previous.map { !$0.attributes.contains(where: { $0 is EditedMessageAttribute }) } ?? false)
    var revisions = history?.revisions ?? []
    var dates = history?.editDates ?? []
    if previous != nil || history == nil {
        revisions.append(goldgramArchiveText(message.text, message.media))
        dates.append(edited?.date ?? 0)
    }
    return GoldgramMessageHistoryAttribute(baseline: baseline, originalObserved: original,
        entities: history?.entities ?? (previous == nil ? entities : oldEntities), revisions: revisions, editDates: dates)
}

private func goldgramStoredMessage(_ message: Message, localTags: LocalMessageTags) -> StoreMessage {
    let forward = message.forwardInfo.map {
        StoreMessageForwardInfo(authorId: $0.author?.id, sourceId: $0.source?.id, sourceMessageId: $0.sourceMessageId,
            date: $0.date, authorSignature: $0.authorSignature, psaType: $0.psaType, flags: $0.flags)
    }
    return StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId,
        groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp,
        flags: StoreMessageFlags(message.flags), tags: message.tags, globalTags: message.globalTags,
        localTags: localTags, forwardInfo: forward, authorId: message.author?.id, text: message.text,
        attributes: message.attributes.filter { !($0 is AutoremoveTimeoutMessageAttribute) && !($0 is AutoclearTimeoutMessageAttribute) },
        media: message.media)
}

// Keep tombstones intact when a later history/reaction fetch repeats an item.
func goldgramPrepareIncoming(accountPeerId: PeerId, transaction: Transaction, message: StoreMessage) -> StoreMessage {
    guard case let .Id(id) = message.id, id.namespace == Namespaces.Message.Cloud, id.id > 0 else { return message }
    let stored = transaction.getMessage(id).map { goldgramStoredMessage($0, localTags: $0.localTags) }
    // Existing retained content must not be erased by a duplicate payload,
    // even after the user turns off capture of NEW events.
    if message.localTags.contains(goldgramDeletedMessageTag) { return message }
    if let stored, stored.localTags.contains(goldgramDeletedMessageTag) { return stored }
    guard goldgramNativeHistoryEnabled() else { return message }
    let snapshot = goldgramSnapshot(transaction: transaction, id: id)
    if let snapshot, snapshot.localTags.contains(goldgramDeletedMessageTag) { return snapshot }
    // The independent snapshot is the last captured version. A native path
    // may already have replaced the live row; comparing only that row would
    // lose the original again. This also orders repeated IDs in one batch.
    var previous = snapshot ?? stored
    let snapshotDate = (snapshot?.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date ?? 0
    let incomingDate = (message.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date ?? 0
    if let snapshot, snapshotDate > incomingDate { return snapshot }
    // Other native fetch paths may have replaced the row without our local
    // attribute. Carry the independently saved history through that refresh.
    if let current = previous, !current.attributes.contains(where: { $0 is GoldgramMessageHistoryAttribute }),
       let history = snapshot?.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) {
        previous = current.withUpdatedAttributes(current.attributes + [history])
    }
    let history = goldgramCaptureMutation(accountPeerId: accountPeerId, transaction: transaction, message: message, previous: previous)
    var attributes = message.attributes.filter { !($0 is GoldgramMessageHistoryAttribute) }
    if let history { attributes.append(history) }
    var prepared = message.withUpdatedAttributes(attributes)
    if prepared.authorId == nil, let sender = previous?.authorId {
        prepared = StoreMessage(id: prepared.id, customStableId: prepared.customStableId,
            globallyUniqueId: prepared.globallyUniqueId, groupingKey: prepared.groupingKey, threadId: prepared.threadId,
            timestamp: prepared.timestamp, flags: prepared.flags, tags: prepared.tags, globalTags: prepared.globalTags,
            localTags: prepared.localTags, forwardInfo: prepared.forwardInfo, authorId: sender, text: prepared.text,
            attributes: prepared.attributes, media: prepared.media)
    }
    goldgramSaveSnapshot(transaction: transaction, message: prepared)
    return prepared
}

// Archive navigation can reinsert a full previously received snapshot. It
// never manufactures content from an ID or fetches a deleted server message.
public func goldgramRestoreSnapshot(transaction: Transaction, id: MessageId, deleted: Bool = false) -> Message? {
    if let message = transaction.getMessage(id) {
        if !message.attributes.contains(where: { $0 is GoldgramMessageHistoryAttribute }),
           let snapshot = goldgramSnapshot(transaction: transaction, id: id), snapshot.text == message.text,
           let history = snapshot.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) {
            transaction.updateMessage(id, preprocess: false, update: { current in
                let hydrated = goldgramStoredMessage(current, localTags: current.localTags)
                    .withUpdatedAttributes(current.attributes + [history])
                return .update(hydrated)
            })
        }
        if deleted && !message.localTags.contains(goldgramDeletedMessageTag) {
            transaction.updateMessage(id, preprocess: false, update: { current in
                var tags = current.localTags; tags.insert(goldgramDeletedMessageTag)
                return .update(goldgramStoredMessage(current, localTags: tags))
            })
            transaction.clearTimestampBasedAttribute(id: id, tag: 0)
            transaction.clearTimestampBasedAttribute(id: id, tag: 1)
        }
        return transaction.getMessage(id)
    }
    guard let snapshot = goldgramSnapshot(transaction: transaction, id: id) else { return nil }
    var restored = snapshot
    if deleted {
        var tags = snapshot.localTags; tags.insert(goldgramDeletedMessageTag)
        restored = snapshot.withUpdatedLocalTags(tags).withUpdatedAttributes(snapshot.attributes.filter {
            !($0 is AutoremoveTimeoutMessageAttribute) && !($0 is AutoclearTimeoutMessageAttribute)
        })
    }
    let _ = transaction.addMessages([restored], location: .Random, preprocess: false)
    return transaction.getMessage(id)
}

// Preserve a full native message (including media references) at its real ID.
// Returns false for unknown/secret/local messages, which follow stock deletion.
func goldgramRetainDeletion(accountPeerId: PeerId, transaction: Transaction, mediaBox: MediaBox, id: MessageId) -> Bool {
    guard goldgramNativeHistoryEnabled(), id.namespace == Namespaces.Message.Cloud, id.id > 0,
          let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)) else { return false }
    let message = goldgramRestoreSnapshot(transaction: transaction, id: id)
    let sender = message?.author?.id ?? goldgramSnapshotAuthor(transaction: transaction, id: id)?.id
    let payload: [String: Any] = [
        "accountId": accountPeerId.id._internalGetInt64Value(), "peerKind": kind,
        "peerId": id.peerId.id._internalGetInt64Value(), "messageId": id.id, "eventKind": 2,
        "text": message.map { goldgramArchiveText($0.text, $0.media) } ?? "[Содержимое не было получено]",
        "senderId": sender?.id._internalGetInt64Value() ?? 0,
        "senderKind": sender.flatMap { goldgramKind($0, transaction.getPeer($0)) } ?? -1,
        "sentAt": Int64(message?.timestamp ?? 0) * 1000, "threadId": message?.threadId ?? 0,
        "retained": message != nil,
        "originalObserved": message.map { !$0.attributes.contains(where: { $0 is EditedMessageAttribute }) } ?? false
    ]
    guard goldgramWrite(payload), let message else { return false }
    if !message.localTags.contains(goldgramDeletedMessageTag) {
        transaction.updateMessage(id, preprocess: false, update: { current in
            var tags = current.localTags; tags.insert(goldgramDeletedMessageTag)
            return .update(goldgramStoredMessage(current, localTags: tags))
        })
    }
    transaction.clearTimestampBasedAttribute(id: id, tag: 0)
    transaction.clearTimestampBasedAttribute(id: id, tag: 1)
    if let retained = transaction.getMessage(id) {
        goldgramSaveSnapshot(transaction: transaction, message: goldgramStoredMessage(retained, localTags: retained.localTags))
    }
    goldgramBackupMedia(accountId: accountPeerId.id._internalGetInt64Value(), mediaBox: mediaBox, media: message.media)
    return true
}

func goldgramUnresolvedDeletions(accountPeerId: PeerId, ids: [Int32]) {
    guard goldgramNativeHistoryEnabled() else { return }
    for id in ids where id > 0 {
        goldgramWrite(["accountId": accountPeerId.id._internalGetInt64Value(), "eventKind": 2,
            "peerKind": -1, "peerId": 0, "messageId": id])
    }
}

private let goldgramMediaQueue = DispatchQueue(label: "goldgram.retained.media", qos: .utility)
private func goldgramMediaDirectory(_ accountId: Int64) -> URL {
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Goldgram/Accounts/\(accountId)/retained-media", isDirectory: true)
}
private func goldgramMediaName(_ id: MediaResourceId) -> String {
    return Data(id.stringRepresentation.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
}
private func goldgramResourceIds(_ media: [Media]) -> [MediaResourceId] {
    var ids: [MediaResourceId] = []
    for value in media {
        addMessageMediaResourceIdsToRemove(media: value, resourceIds: &ids)
        if let page = value as? TelegramMediaWebpage, case let .Loaded(content) = page.content {
            if let image = content.image { addMessageMediaResourceIdsToRemove(media: image, resourceIds: &ids) }
            if let file = content.file { addMessageMediaResourceIdsToRemove(media: file, resourceIds: &ids) }
        }
    }
    return Array(Set(ids))
}
private func goldgramBackupMedia(accountId: Int64, mediaBox: MediaBox, media: [Media]) {
    let ids = goldgramResourceIds(media)
    let pins = ids.map { mediaBox.keepResource(id: $0).start() }
    goldgramMediaQueue.async {
        defer { pins.forEach { $0.dispose() } }
        let folder = goldgramMediaDirectory(accountId)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var url = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            for id in ids {
                let destination = folder.appendingPathComponent(goldgramMediaName(id))
                guard !FileManager.default.fileExists(atPath: destination.path),
                      let source = mediaBox.completedResourcePath(id: id) else { continue }
                // Hard links preserve downloaded bytes when the media cache is
                // unlinked, without duplicating large files. Copy is fallback.
                do { try FileManager.default.linkItem(atPath: source, toPath: destination.path) }
                catch { try? FileManager.default.copyItem(atPath: source, toPath: destination.path) }
            }
        } catch { /* Retained native message still works for cached resources. */ }
    }
}

public func goldgramRestoreRetainedMedia(accountId: Int64, mediaBox: MediaBox, media: [Media], completion: @escaping () -> Void) {
    let ids = goldgramResourceIds(media)
    goldgramMediaQueue.async {
        for id in ids where mediaBox.completedResourcePath(id: id) == nil {
            let path = goldgramMediaDirectory(accountId).appendingPathComponent(goldgramMediaName(id))
            if let data = try? Data(contentsOf: path, options: .mappedIfSafe) {
                mediaBox.storeResourceData(id, data: data, synchronous: true)
            }
        }
        DispatchQueue.main.async(execute: completion)
    }
}

public func goldgramClearRetainedMedia(accountId: Int64, completion: @escaping () -> Void) {
    goldgramMediaQueue.async {
        try? FileManager.default.removeItem(at: goldgramMediaDirectory(accountId))
        DispatchQueue.main.async(execute: completion)
    }
}
