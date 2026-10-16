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

// Called BEFORE a real Postbox replacement, including history/difference replay.
// A native edit notification alone is not proof of a visible content change.
func goldgramCaptureMutation(accountPeerId: PeerId, transaction: Transaction, message: StoreMessage) {
    guard goldgramNativeHistoryEnabled(), case let .Id(id) = message.id,
          id.namespace == Namespaces.Message.Cloud, id.id > 0,
          let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)) else { return }
    let previous = transaction.getMessage(id)
    let edited = message.attributes.compactMap { $0 as? EditedMessageAttribute }.first
    let visibleEdit = edited.map { $0.date > 0 && !$0.isHidden } ?? false
    let newEntities = (message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    let verifiedChange = GoldgramEventPolicy.shouldArchiveEdit(previousText: previous?.text, currentText: message.text,
        previousMedia: previous.map { goldgramMediaKeys($0.media) } ?? [], currentMedia: goldgramMediaKeys(message.media),
        entitiesChanged: previous.map { ($0.textEntitiesAttribute?.entities ?? []) != newEntities } ?? false,
        editDate: edited?.date ?? 0, hidden: edited?.isHidden ?? true)
    // Recovery for an already visibly edited message loaded through another
    // native path: SQLite decides idempotently if this known version is missing.
    guard verifiedChange || visibleEdit else { return }
    let changed: Bool
    if let previous {
        changed = previous.text != message.text || goldgramMediaKeys(previous.media) != goldgramMediaKeys(message.media)
            || (previous.textEntitiesAttribute?.entities ?? []) != newEntities
    } else {
        // First observation is only an edit if Telegram explicitly displays it.
        guard visibleEdit else { return }
        changed = false
    }
    let sender = message.authorId
    var payload: [String: Any] = [
        "accountId": accountPeerId.id._internalGetInt64Value(), "peerKind": kind,
        "peerId": id.peerId.id._internalGetInt64Value(), "messageId": id.id, "eventKind": 1,
        "text": goldgramArchiveText(message.text, message.media), "changed": changed,
        "visibleEdit": visibleEdit, "observationOnly": !verifiedChange, "editedAt": Int64(edited?.date ?? 0) * 1000,
        "senderId": sender?.id._internalGetInt64Value() ?? 0,
        "senderKind": sender.flatMap { goldgramKind($0, transaction.getPeer($0)) } ?? -1,
        "sentAt": Int64(message.timestamp) * 1000, "threadId": message.threadId ?? 0,
        "mediaKeys": goldgramMediaKeys(message.media), "retained": false
    ]
    if let previous, verifiedChange {
        payload["beforeText"] = goldgramArchiveText(previous.text, previous.media)
        payload["beforeMediaKeys"] = goldgramMediaKeys(previous.media)
        payload["originalObserved"] = !previous.attributes.contains(where: { $0 is EditedMessageAttribute })
    }
    goldgramWrite(payload)
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
    if case let .Id(id) = message.id, let previous = transaction.getMessage(id),
       previous.localTags.contains(goldgramDeletedMessageTag) {
        return goldgramStoredMessage(previous, localTags: previous.localTags)
    }
    goldgramCaptureMutation(accountPeerId: accountPeerId, transaction: transaction, message: message)
    return message
}

// Preserve a full native message (including media references) at its real ID.
// Returns false for unknown/secret/local messages, which follow stock deletion.
func goldgramRetainDeletion(accountPeerId: PeerId, transaction: Transaction, mediaBox: MediaBox, id: MessageId) -> Bool {
    guard goldgramNativeHistoryEnabled(), id.namespace == Namespaces.Message.Cloud, id.id > 0,
          let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)) else { return false }
    let message = transaction.getMessage(id)
    let sender = message?.author?.id
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
        transaction.updateMessage(id, update: { current in
            var tags = current.localTags; tags.insert(goldgramDeletedMessageTag)
            return .update(goldgramStoredMessage(current, localTags: tags))
        })
    }
    transaction.clearTimestampBasedAttribute(id: id, tag: 0)
    transaction.clearTimestampBasedAttribute(id: id, tag: 1)
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
