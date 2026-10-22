import Foundation
import Darwin
import Postbox
import SwiftSignalKit
import TelegramApi

// #97: opt-in, account-scoped stage counts. No message contents, IDs,
// peer names or message hashes are recorded. Disabled outside explicit test.
private enum GoldgramCaptureDiagnostics {
    static let lock = NSLock()
    static func count(account: PeerId, stage: String) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "GoldgramDiagnosticEnabledV1") else { return }
        let key = "GoldgramDiagnosticCountsV1.\(account.id._internalGetInt64Value())"
        lock.lock()
        defer { lock.unlock() }
        var values = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        values[stage] = min(1_000_000, (values[stage] ?? 0) + 1)
        defaults.set(values, forKey: key)
    }
}
func goldgramDiagnosticRecord(accountPeerId: PeerId, stage: String) {
    GoldgramCaptureDiagnostics.count(account: accountPeerId, stage: stage)
}

// #101. Temporary account- and discussion-scoped diagnostic metadata.
// Only routing identifiers and stage labels; no chat text or sender information.
func goldgramTraceMessage(accountPeerId: PeerId, id: MessageId, stage: String) {
    let defaults = UserDefaults.standard
    let account = accountPeerId.id._internalGetInt64Value()
    guard defaults.bool(forKey: "GoldgramDiagnosticTraceActiveV2.\(account)") else { return }
    let prefix: String
    switch id.peerId.namespace {
    case Namespaces.Peer.CloudUser: prefix = "u"
    case Namespaces.Peer.CloudGroup: prefix = "g"
    case Namespaces.Peer.CloudChannel: prefix = "c"
    default: return
    }
    let peer = "\(prefix):\(id.peerId.id._internalGetInt64Value())"
    guard (defaults.stringArray(forKey: "GoldgramDiagnosticTraceScopeV2.\(account)") ?? []).contains(peer) else { return }
    let key = "\(peer):\(id.id)"
    let storage = "GoldgramDiagnosticTraceRowsV2.\(account)"
    GoldgramCaptureDiagnostics.lock.lock()
    defer { GoldgramCaptureDiagnostics.lock.unlock() }
    var rows = defaults.array(forKey: storage) as? [[String: Any]] ?? []
    if let index = rows.firstIndex(where: { ($0["key"] as? String) == key }) {
        var row = rows.remove(at: index)
        var stages = row["stages"] as? [String] ?? []
        if !stages.contains(stage) { stages.append(stage) }
        row["stages"] = stages
        rows.append(row)
    } else {
        rows.append(["key": key, "stages": [stage]])
        if rows.count > 256 { rows.removeFirst(rows.count - 256) }
    }
    defaults.set(rows, forKey: storage)
}

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

public func goldgramNativeHistoryEnabled() -> Bool {
    return goldgramNativeHistoryHostV1() == 1 && goldgramNativeWriter() != nil && UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled")
}

// The notification service has its own defaults and does not load Mx. Share
// explicit account-local consent through Postbox, never infer it from a push.
private struct GoldgramCaptureSettings: Codable, Equatable {
    let account: Int64
    let enabled: Bool
    let since: Int32
}
private struct GoldgramPendingEvent: Codable { let data: Data; let kind: Int32 }
private struct GoldgramPendingEvents: Codable { let items: [GoldgramPendingEvent] }
private let goldgramSettingsKey = ItemCacheEntryId(collectionId: -103, key: ValueBoxKey(length: 0))
private let goldgramPendingKey = ItemCacheEntryId(collectionId: -104, key: ValueBoxKey(length: 0))

func goldgramCaptureEnabled(accountPeerId: PeerId, transaction: Transaction) -> Bool {
    let old = transaction.retrieveItemCacheEntry(id: goldgramSettingsKey)?.get(GoldgramCaptureSettings.self)
    if goldgramNativeWriter() != nil {
        let value = GoldgramCaptureSettings(account: accountPeerId.toInt64(), enabled: goldgramNativeHistoryEnabled(), since: goldgramCaptureSince(accountPeerId))
        if value != old, let entry = CodableEntry(value) { transaction.putItemCacheEntry(id: goldgramSettingsKey, entry: entry) }
        return value.enabled
    }
    return old?.account == accountPeerId.toInt64() && old?.enabled == true
}

private func goldgramDrainPending(accountPeerId: PeerId, transaction: Transaction) {
    guard goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction), goldgramNativeWriter() != nil,
          let pending = transaction.retrieveItemCacheEntry(id: goldgramPendingKey)?.get(GoldgramPendingEvents.self) else { return }
    var remaining: [GoldgramPendingEvent] = []
    for item in pending.items {
        guard let payload = (try? JSONSerialization.jsonObject(with: item.data)) as? [String: Any],
              (payload["accountId"] as? NSNumber)?.int64Value == accountPeerId.id._internalGetInt64Value() else { continue }
        if !goldgramWrite(payload) { remaining.append(item) }
    }
    // Flush accepted events before discarding the durable extension handoff.
    typealias Flush = @convention(c) () -> Int32
    guard let handle = dlopen(nil, RTLD_NOW) else { return }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "goldgram_flush_capture_v1"), unsafeBitCast(symbol, to: Flush.self)() == 1 else { return }
    if remaining.isEmpty { transaction.removeItemCacheEntry(id: goldgramPendingKey) }
    else if let entry = CodableEntry(GoldgramPendingEvents(items: remaining)) { transaction.putItemCacheEntry(id: goldgramPendingKey, entry: entry) }
}

private func goldgramSavedOriginal(accountPeerId: PeerId, kind: Int32, id: MessageId) -> String? {
    goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: "sqlOriginalLookupAttempt")
    typealias Read = @convention(c) (Int64, Int32, Int64, Int32) -> UnsafeMutablePointer<CChar>?
    guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "goldgram_read_original_v1"),
          let text = unsafeBitCast(symbol, to: Read.self)(accountPeerId.id._internalGetInt64Value(), kind, id.peerId.id._internalGetInt64Value(), id.id) else { return nil }
    defer { free(text) }
    guard let data = String(cString: text).data(using: .utf8),
          let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let result = value["text"] as? String
    if result != nil {
        goldgramDiagnosticRecord(accountPeerId: accountPeerId, stage: "sqliteLookupHit")
        goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: "sqlOriginalLookupHit")
    }
    return result
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
private func goldgramWrite(_ payload: [String: Any], transaction: Transaction? = nil) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), data.count <= 300000,
          let json = String(data: data, encoding: .utf8) else { return false }
    if let writer = goldgramNativeWriter() { return json.withCString { writer($0) == 1 } }
    guard let transaction, payload["text"] as? String != "[Содержимое не было получено]" else { return false }
    var items = transaction.retrieveItemCacheEntry(id: goldgramPendingKey)?.get(GoldgramPendingEvents.self)?.items ?? []
    items.append(GoldgramPendingEvent(data: data, kind: (payload["eventKind"] as? NSNumber)?.int32Value ?? 0))
    var bytes = items.reduce(0) { $0 + $1.data.count }
    while items.count > 512 || bytes > 4 * 1024 * 1024 {
        let index = items.firstIndex(where: { $0.kind == 0 }) ?? 0
        bytes -= items[index].data.count; items.remove(at: index)
    }
    guard let entry = CodableEntry(GoldgramPendingEvents(items: items)) else { return false }
    transaction.putItemCacheEntry(id: goldgramPendingKey, entry: entry)
    return true
}

// First activation of the corrected logger, per authenticated account. Old
// edit dates loaded by scrolling cannot become new archive events.
private func goldgramCaptureSince(_ account: PeerId, transaction: Transaction? = nil) -> Int32 {
    if goldgramNativeWriter() == nil, let transaction,
       let settings = transaction.retrieveItemCacheEntry(id: goldgramSettingsKey)?.get(GoldgramCaptureSettings.self), settings.account == account.toInt64() { return settings.since }
    let key = "GoldgramNativeHistorySinceV2.\(account.id._internalGetInt64Value())"
    let value = UserDefaults.standard.integer(forKey: key)
    if value > 0 { return Int32(clamping: value) }
    let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
    UserDefaults.standard.set(Int(now), forKey: key)
    return now
}

// A real new-message update may be replaced by a newer edit before Postbox
// gets to archive its first snapshot. Record positively received unedited
// server content immediately, independently of that transaction/replay path.
// A delayed original repairs the baseline only, never the latest revision.
func goldgramCaptureServerOriginal(accountPeerId: PeerId, message: StoreMessage, peerKind: Int32) {
    guard goldgramNativeHistoryEnabled(), (0...3).contains(peerKind),
          case let .Id(id) = message.id, id.namespace == Namespaces.Message.Cloud, id.id > 0,
          !message.attributes.contains(where: { $0 is EditedMessageAttribute }),
          !message.text.isEmpty || !message.media.isEmpty else { return }
    goldgramDiagnosticRecord(accountPeerId: accountPeerId, stage: "serverEligible")
    goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: "originalEligible")
    let sender = message.authorId
    let original = goldgramArchiveText(message.text, message.media)
    if goldgramWrite([
        "accountId": accountPeerId.id._internalGetInt64Value(), "peerKind": peerKind,
        "peerId": id.peerId.id._internalGetInt64Value(), "messageId": id.id, "eventKind": 0,
        "text": original, "originalText": original, "originalObserved": true,
        "baselineOnly": true,
        "senderId": sender?.id._internalGetInt64Value() ?? 0,
        "senderKind": sender.flatMap { goldgramKind($0, nil) } ?? -1,
        "sentAt": Int64(message.timestamp) * 1000, "threadId": message.threadId ?? 0,
        "mediaKeys": goldgramMediaKeys(message.media)
    ]) {
        goldgramDiagnosticRecord(accountPeerId: accountPeerId, stage: "writerAccepted")
        goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: "originalQueued")
    }
}

// #103: cross-process notification diagnostics, scoped to a selected folder.
// The Postbox entry is shared by the app and its notification extension. Only
// routing IDs and fixed stages are stored; no message/preview content.
private struct GoldgramNotificationTraceEntry: Codable {
    let peer: Int64
    let message: Int32
    var stages: [String]
}
private struct GoldgramNotificationTrace: Codable {
    let account: Int64
    let peers: [Int64]
    let startedAt: Int64
    var entries: [GoldgramNotificationTraceEntry]
}
private let goldgramNotificationTraceKey = ItemCacheEntryId(collectionId: -105, key: ValueBoxKey(length: 0))

public func goldgramSetNotificationTrace(transaction: Transaction, accountPeerId: PeerId, peers: [PeerId]) {
    if peers.isEmpty {
        transaction.removeItemCacheEntry(id: goldgramNotificationTraceKey)
        return
    }
    guard goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction) else { return }
    let trace = GoldgramNotificationTrace(
        account: accountPeerId.toInt64(), peers: Array(Set(peers.map { $0.toInt64() })).prefix(16).map { $0 },
        startedAt: Int64(Date().timeIntervalSince1970), entries: []
    )
    if let value = CodableEntry(trace) {
        transaction.putItemCacheEntry(id: goldgramNotificationTraceKey, entry: value)
    }
}
public func goldgramNoteNotificationTrace(transaction: Transaction, accountPeerId: PeerId, id: MessageId, stage: String) {
    guard case let .some(trace) = transaction.retrieveItemCacheEntry(id: goldgramNotificationTraceKey)?.get(GoldgramNotificationTrace.self),
          trace.account == accountPeerId.toInt64(),
          Int64(Date().timeIntervalSince1970) - trace.startedAt < 86400,
          trace.peers.contains(id.peerId.toInt64()), id.id > 0 else { return }
    var updated = trace
    if let index = updated.entries.firstIndex(where: { $0.peer == id.peerId.toInt64() && $0.message == id.id }) {
        var entry = updated.entries.remove(at: index)
        if !entry.stages.contains(stage) { entry.stages.append(stage) }
        updated.entries.append(entry)
    } else {
        updated.entries.append(GoldgramNotificationTraceEntry(peer: id.peerId.toInt64(), message: id.id, stages: [stage]))
        if updated.entries.count > 192 { updated.entries.removeFirst(updated.entries.count - 192) }
    }
    if let value = CodableEntry(updated) {
        transaction.putItemCacheEntry(id: goldgramNotificationTraceKey, entry: value)
    }
}
public func goldgramNotificationTraceStages(transaction: Transaction, accountPeerId: PeerId, id: MessageId) -> [String] {
    guard let trace = transaction.retrieveItemCacheEntry(id: goldgramNotificationTraceKey)?.get(GoldgramNotificationTrace.self),
          trace.account == accountPeerId.toInt64(),
          trace.peers.contains(id.peerId.toInt64()) else { return [] }
    return trace.entries.first(where: { $0.peer == id.peerId.toInt64() && $0.message == id.id })?.stages ?? []
}

// A notification service extension may run when iOS has suspended the app.
// Only a complete, actually materialized, unedited Postbox message is evidence.
// Never archive an APNs preview or infer an original from the first edit.
// The extension has no app-host C writer, so it uses the existing bounded
// account-scoped Postbox handoff (-104), drained by the app on next execution.
public func goldgramCaptureNotificationOriginal(
    accountPeerId: PeerId, transaction: Transaction, message: Message
) {
    guard goldgramNativeWriter() == nil,
          goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction) else {
        goldgramNoteNotificationTrace(transaction: transaction, accountPeerId: accountPeerId,
            id: message.id, stage: "extensionCaptureDisabled")
        return
    }
    guard message.id.namespace == Namespaces.Message.Cloud, message.id.id > 0,
          !message.containsSecretMedia,
          !message.attributes.contains(where: { $0 is EditedMessageAttribute }),
          !message.text.isEmpty || !message.media.isEmpty,
          let kind = goldgramKind(message.id.peerId, transaction.getPeer(message.id.peerId))
    else {
        goldgramNoteNotificationTrace(transaction: transaction, accountPeerId: accountPeerId,
            id: message.id, stage: "extensionOriginalIneligible")
        return
    }
    goldgramNoteNotificationTrace(transaction: transaction, accountPeerId: accountPeerId,
        id: message.id, stage: "extensionOriginalEligible")
    let original = goldgramArchiveText(message.text, message.media)
    let author = message.author?.id
    let payload: [String: Any] = [
        "accountId": accountPeerId.id._internalGetInt64Value(),
        "peerKind": kind, "peerId": message.id.peerId.id._internalGetInt64Value(),
        "messageId": message.id.id, "eventKind": 0,
        "text": original, "originalText": original,
        "originalObserved": true, "baselineOnly": true,
        "senderId": author?.id._internalGetInt64Value() ?? 0,
        "senderKind": author.flatMap { goldgramKind($0, transaction.getPeer($0)) } ?? -1,
        "sentAt": Int64(message.timestamp) * 1000,
        "threadId": message.threadId ?? 0,
        "mediaKeys": goldgramMediaKeys(message.media)
    ]
    let accepted = goldgramWrite(payload, transaction: transaction)
    goldgramNoteNotificationTrace(transaction: transaction, accountPeerId: accountPeerId,
        id: message.id, stage: accepted ? "extensionOriginalQueued" : "extensionQueueRejected")
}

// Returns local history metadata to persist together with the server version.
private func goldgramCaptureMutation(accountPeerId: PeerId, transaction: Transaction,
    message: StoreMessage, previous: StoreMessage?) -> GoldgramMessageHistoryAttribute? {
    var history = previous?.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) as? GoldgramMessageHistoryAttribute
    guard case let .Id(id) = message.id,
          let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)) else { return history }
    if let saved = history, !saved.originalObserved,
       let original = goldgramSavedOriginal(accountPeerId: accountPeerId, kind: kind, id: id) {
        history = GoldgramMessageHistoryAttribute(baseline: original, originalObserved: true, entities: [], revisions: saved.revisions, editDates: saved.editDates)
    }
    let edited = message.attributes.compactMap { $0 as? EditedMessageAttribute }.first
    let entities = (message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    let oldEntities = (previous?.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    let verified = GoldgramEventPolicy.shouldArchiveEdit(previousText: previous?.text, currentText: message.text,
        previousMedia: previous.map { goldgramMediaKeys($0.media) } ?? [], currentMedia: goldgramMediaKeys(message.media),
        entitiesChanged: oldEntities != entities, editDate: edited?.date ?? 0, hidden: edited?.isHidden ?? true,
        captureSince: goldgramCaptureSince(accountPeerId, transaction: transaction),
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
    if let history, history.originalObserved {
        payload["originalObserved"] = true
        payload["originalText"] = history.baseline
    }
    guard goldgramWrite(payload, transaction: transaction) else { return history }
    // An unavailable original is never invented. Start inline history with the
    // earliest actually received version, labelled honestly by the renderer.
    let previousIsOriginal = previous.map { !$0.attributes.contains(where: { $0 is EditedMessageAttribute }) } ?? false
    let recovered = (history?.originalObserved == true || previousIsOriginal) ? nil : goldgramSavedOriginal(accountPeerId: accountPeerId, kind: kind, id: id)
    let baseline = history?.originalObserved == true ? history!.baseline : recovered ?? history?.baseline ?? previous?.text ?? ""
    let original = history?.originalObserved == true || previousIsOriginal || recovered != nil
    var revisions = history?.revisions ?? []
    var dates = history?.editDates ?? []
    if previous != nil || history == nil {
        revisions.append(goldgramArchiveText(message.text, message.media))
        dates.append(edited?.date ?? 0)
    }
    goldgramDiagnosticRecord(accountPeerId: accountPeerId, stage: original ? "inlineKnown" : "inlineUnknown")
    goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: original ? "inlineKnown" : "inlineMissing")
    return GoldgramMessageHistoryAttribute(baseline: baseline, originalObserved: original,
        entities: recovered == nil ? (history?.entities ?? (previous == nil ? entities : oldEntities)) : [], revisions: revisions, editDates: dates)
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

// A delayed original is still evidence, even after a newer version won the
// live-row race. Save its baseline separately from the current message body.
private func goldgramAcceptLateOriginal(accountPeerId: PeerId, transaction: Transaction,
    id: MessageId, incoming: StoreMessage, current: StoreMessage) -> StoreMessage {
    guard !incoming.attributes.contains(where: { $0 is EditedMessageAttribute }),
          current.attributes.contains(where: { $0 is EditedMessageAttribute }),
          goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction),
          let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)) else { return current }
    let history = current.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) as? GoldgramMessageHistoryAttribute
    if history?.originalObserved == true { return current }
    let sender = incoming.authorId ?? current.authorId
    let payload: [String: Any] = [
        "accountId": accountPeerId.id._internalGetInt64Value(), "peerKind": kind,
        "peerId": id.peerId.id._internalGetInt64Value(), "messageId": id.id, "eventKind": 0,
        "text": goldgramArchiveText(current.text, current.media),
        "originalText": goldgramArchiveText(incoming.text, incoming.media), "originalObserved": true,
        "baselineOnly": true, "senderId": sender?.id._internalGetInt64Value() ?? 0,
        "senderKind": sender.flatMap { goldgramKind($0, transaction.getPeer($0)) } ?? -1,
        "sentAt": Int64(incoming.timestamp) * 1000, "threadId": current.threadId ?? 0
    ]
    guard goldgramWrite(payload, transaction: transaction) else { return current }
    var repaired = current
    if let history {
        let entities = (incoming.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
        let fixed = GoldgramMessageHistoryAttribute(baseline: incoming.text, originalObserved: true,
            entities: entities, revisions: history.revisions, editDates: history.editDates)
        repaired = current.withUpdatedAttributes(current.attributes.filter { !($0 is GoldgramMessageHistoryAttribute) } + [fixed])
    }
    goldgramSaveSnapshot(transaction: transaction, message: repaired)
    return repaired
}

// Keep tombstones intact when a later history/reaction fetch repeats an item.
func goldgramPrepareIncoming(accountPeerId: PeerId, transaction: Transaction, message: StoreMessage) -> StoreMessage {
    guard case let .Id(id) = message.id, id.namespace == Namespaces.Message.Cloud, id.id > 0 else { return message }
    let edited = message.attributes.contains(where: { $0 is EditedMessageAttribute })
    goldgramDiagnosticRecord(accountPeerId: accountPeerId, stage: edited ? "postboxEdited" : "postboxUnedited")
    goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: edited ? "postboxEdited" : "postboxUnedited")
    let stored = transaction.getMessage(id).map { goldgramStoredMessage($0, localTags: $0.localTags) }
    // Existing retained content must not be erased by a duplicate payload,
    // even after the user turns off capture of NEW events.
    if message.localTags.contains(goldgramDeletedMessageTag) {
        return message.withUpdatedAttributes(message.attributes.filter {
            !($0 is AutoremoveTimeoutMessageAttribute) && !($0 is AutoclearTimeoutMessageAttribute)
        })
    }
    if let stored, stored.localTags.contains(goldgramDeletedMessageTag) {
        return goldgramAcceptLateOriginal(accountPeerId: accountPeerId, transaction: transaction, id: id, incoming: message, current: stored)
    }
    guard goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction) else { return message }
    goldgramDiagnosticRecord(accountPeerId: accountPeerId, stage: "postboxCaptureEnabled")
    goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: "postboxCaptureEnabled")
    let snapshot = goldgramSnapshot(transaction: transaction, id: id)
    if let snapshot, snapshot.localTags.contains(goldgramDeletedMessageTag) {
        return goldgramAcceptLateOriginal(accountPeerId: accountPeerId, transaction: transaction, id: id, incoming: message, current: snapshot)
    }
    // The independent snapshot is the last captured version. A native path
    // may already have replaced the live row; comparing only that row would
    // lose the original again. This also orders repeated IDs in one batch.
    var previous = snapshot ?? stored
    let snapshotDate = (snapshot?.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date ?? 0
    let incomingDate = (message.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date ?? 0
    if let snapshot, snapshotDate > incomingDate {
        return goldgramAcceptLateOriginal(accountPeerId: accountPeerId, transaction: transaction, id: id, incoming: message, current: snapshot)
    }
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
    goldgramRememberDiscussion(transaction: transaction, peerId: id.peerId)
    if goldgramSaveSnapshot(transaction: transaction, message: prepared),
       let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)) {
        // Observation has no edit/delete event. Keep received content in SQLite
        // too, so losing a ring snapshot cannot turn a known body into a receipt.
        let sender = prepared.authorId
        let _ = goldgramWrite([
            "accountId": accountPeerId.id._internalGetInt64Value(), "peerKind": kind,
            "peerId": id.peerId.id._internalGetInt64Value(), "messageId": id.id, "eventKind": 0,
            "text": goldgramArchiveText(prepared.text, prepared.media),
            "originalObserved": !prepared.attributes.contains(where: { $0 is EditedMessageAttribute }),
            "senderId": sender?.id._internalGetInt64Value() ?? 0,
            "senderKind": sender.flatMap { goldgramKind($0, transaction.getPeer($0)) } ?? -1,
            "sentAt": Int64(prepared.timestamp) * 1000, "threadId": prepared.threadId ?? 0,
            "editedAt": Int64(incomingDate) * 1000
        ], transaction: transaction)
    }
    return prepared
}

// Archive navigation can reinsert a full previously received snapshot. It
// never manufactures content from an ID or fetches a deleted server message.
private func goldgramHydrateOriginal(transaction: Transaction, id: MessageId, accountPeerId: PeerId?) {
    guard let accountPeerId, let message = transaction.getMessage(id),
          let history = message.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) as? GoldgramMessageHistoryAttribute,
          !history.originalObserved, let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)),
          let original = goldgramSavedOriginal(accountPeerId: accountPeerId, kind: kind, id: id) else { return }
    transaction.updateMessage(id, preprocess: false, update: { current in
        let fixed = GoldgramMessageHistoryAttribute(baseline: original, originalObserved: true, entities: [], revisions: history.revisions, editDates: history.editDates)
        return .update(goldgramStoredMessage(current, localTags: current.localTags).withUpdatedAttributes(current.attributes.filter { !($0 is GoldgramMessageHistoryAttribute) } + [fixed]))
    })
    if let updated = transaction.getMessage(id) { goldgramSaveSnapshot(transaction: transaction, message: goldgramStoredMessage(updated, localTags: updated.localTags)) }
}

public func goldgramRestoreSnapshot(transaction: Transaction, id: MessageId, deleted: Bool = false, accountPeerId: PeerId? = nil) -> Message? {
    goldgramHydrateOriginal(transaction: transaction, id: id, accountPeerId: accountPeerId)
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
        if deleted || message.localTags.contains(goldgramDeletedMessageTag) {
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
    if deleted || snapshot.localTags.contains(goldgramDeletedMessageTag) {
        var tags = snapshot.localTags; tags.insert(goldgramDeletedMessageTag)
        restored = snapshot.withUpdatedLocalTags(tags).withUpdatedAttributes(snapshot.attributes.filter {
            !($0 is AutoremoveTimeoutMessageAttribute) && !($0 is AutoclearTimeoutMessageAttribute)
        })
    }
    let _ = transaction.addMessages([restored], location: .Random, preprocess: false)
    goldgramHydrateOriginal(transaction: transaction, id: id, accountPeerId: accountPeerId)
    if restored.localTags.contains(goldgramDeletedMessageTag) {
        transaction.clearTimestampBasedAttribute(id: id, tag: 0)
        transaction.clearTimestampBasedAttribute(id: id, tag: 1)
    }
    return transaction.getMessage(id)
}

// A retained row is local history, not a server-owned row to expire again.
// This must work with capture OFF too; Clear Logs explicitly deletes these rows.
func goldgramPreserveRetained(transaction: Transaction, id: MessageId) -> Bool {
    guard id.namespace == Namespaces.Message.Cloud,
          let message = transaction.getMessage(id),
          message.localTags.contains(goldgramDeletedMessageTag) else { return false }
    if message.attributes.contains(where: { $0 is AutoremoveTimeoutMessageAttribute || $0 is AutoclearTimeoutMessageAttribute }) {
        transaction.updateMessage(id, preprocess: false, update: { current in
            return .update(goldgramStoredMessage(current, localTags: current.localTags))
        })
    }
    transaction.clearTimestampBasedAttribute(id: id, tag: 0)
    transaction.clearTimestampBasedAttribute(id: id, tag: 1)
    return true
}

// Preserve a full native message (including media references) at its real ID.
// Returns false for unknown/secret/local messages, which follow stock deletion.
public func goldgramRetainDeletion(accountPeerId: PeerId, transaction: Transaction, mediaBox: MediaBox, id: MessageId) -> Bool {
    if goldgramPreserveRetained(transaction: transaction, id: id) { return true }
    guard goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction), id.namespace == Namespaces.Message.Cloud, id.id > 0,
          let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)) else { return false }
    goldgramRememberDiscussion(transaction: transaction, peerId: id.peerId, explicitlyOpened: true)
    let message = goldgramRestoreSnapshot(transaction: transaction, id: id, accountPeerId: accountPeerId)
    let sender = message?.author?.id ?? goldgramSnapshotAuthor(transaction: transaction, id: id)?.id
    var payload: [String: Any] = [
        "accountId": accountPeerId.id._internalGetInt64Value(), "peerKind": kind,
        "peerId": id.peerId.id._internalGetInt64Value(), "messageId": id.id, "eventKind": 2,
        "text": message.map { goldgramArchiveText($0.text, $0.media) } ?? "[Содержимое не было получено]",
        "senderId": sender?.id._internalGetInt64Value() ?? 0,
        "senderKind": sender.flatMap { goldgramKind($0, transaction.getPeer($0)) } ?? -1,
        "sentAt": Int64(message?.timestamp ?? 0) * 1000, "threadId": message?.threadId ?? 0,
        "retained": message != nil,
        "originalObserved": message.map { !$0.attributes.contains(where: { $0 is EditedMessageAttribute }) } ?? false
    ]
    if let history = message?.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) as? GoldgramMessageHistoryAttribute, history.originalObserved {
        payload["originalObserved"] = true
        payload["originalText"] = history.baseline
    }
    guard goldgramWrite(payload, transaction: transaction), let message else { return false }
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

// #104: opt-in, account-local priority groups for linked channel discussions.
// This does not join groups, request notifications or keep iOS alive.
private struct GoldgramPriorityDiscussion: Codable {
    let channel: Int64
    let discussion: Int64
}
private struct GoldgramPriorityDiscussions: Codable {
    let account: Int64
    let items: [GoldgramPriorityDiscussion]
}
private let goldgramPriorityDiscussionsKey = ItemCacheEntryId(collectionId: -106, key: ValueBoxKey(length: 0))

// Accept only an actual broadcast channel and its validated linked group.
// An archive folder title or a nearby message never proves a relationship.
public func goldgramSetPriorityDiscussion(transaction: Transaction, accountPeerId: PeerId,
    channelPeerId: PeerId, enabled: Bool) -> (status: String, count: Int) {
    guard goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction),
          let channel = transaction.getPeer(channelPeerId) as? TelegramChannel,
          case .broadcast = channel.info else { return ("unavailable", 0) }
    let old = transaction.retrieveItemCacheEntry(id: goldgramPriorityDiscussionsKey)?
        .get(GoldgramPriorityDiscussions.self)
    var items = old?.account == accountPeerId.toInt64() ? old!.items : []
    items.removeAll(where: { $0.channel == channelPeerId.toInt64() })
    if enabled {
        guard let cached = transaction.getPeerCachedData(peerId: channelPeerId) as? CachedChannelData,
              case let .known(linkedId) = cached.linkedDiscussionPeerId,
              let linkedId,
              let discussion = transaction.getPeer(linkedId) as? TelegramChannel,
              case .group = discussion.info,
              apiInputPeer(discussion) != nil else {
            return ("linked_group_unavailable", old?.items.count ?? 0)
        }
        // A known reverse mapping must be consistent.
        if let opposite = transaction.getPeerCachedData(peerId: linkedId) as? CachedChannelData,
           case let .known(backId) = opposite.linkedDiscussionPeerId,
           backId != channelPeerId {
            return ("linked_group_unavailable", old?.items.count ?? 0)
        }
        guard items.count < 8 else { return ("limit_reached", items.count) }
        items.append(GoldgramPriorityDiscussion(
            channel: channelPeerId.toInt64(), discussion: linkedId.toInt64()))
    }
    let value = GoldgramPriorityDiscussions(account: accountPeerId.toInt64(), items: items)
    guard let entry = CodableEntry(value) else { return ("unavailable", items.count) }
    transaction.putItemCacheEntry(id: goldgramPriorityDiscussionsKey, entry: entry)
    return (enabled ? "enabled" : "disabled", items.count)
}

private func goldgramPriorityPeers(transaction: Transaction, accountPeerId: PeerId) -> [PeerId] {
    guard let stored = transaction.retrieveItemCacheEntry(id: goldgramPriorityDiscussionsKey)?
        .get(GoldgramPriorityDiscussions.self),
        stored.account == accountPeerId.toInt64() else { return [] }
    var result: [PeerId] = []
    for entry in stored.items.prefix(8) {
        let channelId = PeerId(entry.channel)
        let groupId = PeerId(entry.discussion)
        guard let channel = transaction.getPeer(channelId) as? TelegramChannel,
              case .broadcast = channel.info,
              let cached = transaction.getPeerCachedData(peerId: channelId) as? CachedChannelData,
              case let .known(linkedId) = cached.linkedDiscussionPeerId, linkedId == groupId,
              let discussion = transaction.getPeer(groupId) as? TelegramChannel,
              case .group = discussion.info, apiInputPeer(discussion) != nil else { continue }
        if let reverse = transaction.getPeerCachedData(peerId: groupId) as? CachedChannelData,
           case let .known(backId) = reverse.linkedDiscussionPeerId,
           backId != channelId { continue }
        if !result.contains(groupId) { result.append(groupId) }
    }
    return result
}

// Account-local, bounded list of recently received/opened cloud dialogs.
// Seed recent bodies on wake; channel polling shares the stock reference count.
private struct GoldgramDiscussionTarget: Codable {
    let peer: Int64
    let seen: Int64
}
private struct GoldgramDiscussionTargets: Codable {
    let items: [GoldgramDiscussionTarget]
}
private let goldgramDiscussionTargetsKey = ItemCacheEntryId(collectionId: -102, key: ValueBoxKey(length: 0))

func goldgramRememberDiscussion(transaction: Transaction, peerId: PeerId, explicitlyOpened: Bool = false) {
    guard goldgramNativeHistoryEnabled(), goldgramKind(peerId, transaction.getPeer(peerId)) != nil else { return }
    if let channel = transaction.getPeer(peerId) as? TelegramChannel, case .broadcast = channel.info,
       let cached = transaction.getPeerCachedData(peerId: peerId) as? CachedChannelData,
       case let .known(linked) = cached.linkedDiscussionPeerId, let linked,
       let group = transaction.getPeer(linked) as? TelegramChannel, case .group = group.info {
        goldgramRememberDiscussion(transaction: transaction, peerId: linked, explicitlyOpened: true)
    }
    let now = Int64(Date().timeIntervalSince1970)
    let old = transaction.retrieveItemCacheEntry(id: goldgramDiscussionTargetsKey)?.get(GoldgramDiscussionTargets.self)?.items ?? []
    // Avoid rewriting the watch list on every received comment/reaction.
    if let current = old.first(where: { $0.peer == peerId.toInt64() }), now - current.seen < 60 { return }
    var items = old.filter { $0.peer != peerId.toInt64() && now - $0.seen < 86400 }
    items.insert(GoldgramDiscussionTarget(peer: peerId.toInt64(), seen: now), at: 0)
    if let entry = CodableEntry(GoldgramDiscussionTargets(items: Array(items.prefix(8)))) {
        transaction.putItemCacheEntry(id: goldgramDiscussionTargetsKey, entry: entry)
    }
}

// Seed only the latest 100 accessible messages, once per active subscription.
// This neither marks history read nor joins a group, and downloads no media.
private func goldgramSeedDiscussion(account: Account, peerId: PeerId) -> Signal<Never, NoError> {
    return account.postbox.transaction { transaction -> (Peer, Api.InputPeer)? in
        guard goldgramNativeHistoryEnabled(), let peer = transaction.getPeer(peerId),
              goldgramKind(peerId, peer) != nil, let input = apiInputPeer(peer) else { return nil }
        return (peer, input)
    }
    |> mapToSignal { value -> Signal<Never, NoError> in
        guard let (peer, input) = value else { return .complete() }
        return account.network.request(Api.functions.messages.getHistory(peer: input, offsetId: 0, offsetDate: 0, addOffset: 0, limit: 100, maxId: 0, minId: 0, hash: 0))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.messages.Messages?, NoError> in .single(nil) }
        |> mapToSignal { response -> Signal<Never, NoError> in
            guard let response else { return .complete() }
            return account.postbox.transaction { transaction -> Void in
                guard goldgramNativeHistoryEnabled() else { return }
                let messages: [Api.Message]
                let chats: [Api.Chat]
                let users: [Api.User]
                switch response {
                case let .messages(data): messages = data.messages; chats = data.chats; users = data.users
                case let .messagesSlice(data): messages = data.messages; chats = data.chats; users = data.users
                case let .channelMessages(data): messages = data.messages; chats = data.chats; users = data.users
                case .messagesNotModified: return
                }
                updatePeers(transaction: transaction, accountPeerId: account.peerId,
                    peers: AccumulatedPeers(transaction: transaction, chats: chats, users: users))
                let stored = messages.compactMap { StoreMessage(apiMessage: $0, accountPeerId: account.peerId, peerIsForum: (peer as? TelegramChannel)?.isForumOrMonoForum ?? false) }
                let _ = transaction.addMessages(stored, location: .Random)
            }
            |> ignoreValues
        }
    }
}

private final class GoldgramDiscussionMonitor {
    private let account: Account
    private let refresh = MetaDisposable()
    private var subscriptions: [PeerId: Disposable] = [:]

    init(account: Account, queue: Queue) {
        self.account = account
        let tick: Signal<Void, NoError> = .single(())
        let clock = tick |> then(Signal<Void, NoError>.complete() |> delay(15.0, queue: queue)) |> restart
        self.refresh.set((clock
        |> mapToSignal { _ -> Signal<[PeerId], NoError> in
            return account.postbox.transaction { transaction -> [PeerId] in
                goldgramDrainPending(accountPeerId: account.peerId, transaction: transaction)
                guard goldgramNativeHistoryEnabled() else { return [] }
                let now = Int64(Date().timeIntervalSince1970)
                let items = transaction.retrieveItemCacheEntry(id: goldgramDiscussionTargetsKey)?.get(GoldgramDiscussionTargets.self)?.items ?? []
                // Keep user-selected linked discussions first (max 8), then
                // fill remaining slots with recently opened dialogs (max 10).
                // All subscriptions stop when the host stops executing.
                var wanted = goldgramPriorityPeers(transaction: transaction, accountPeerId: account.peerId)
                for item in items where now - item.seen < 86400 && wanted.count < 10 {
                    let id = PeerId(item.peer)
                    guard goldgramKind(id, transaction.getPeer(id)) != nil,
                          !wanted.contains(id) else { continue }
                    wanted.append(id)
                }
                return wanted
            }
        }
        |> deliverOn(queue)).start(next: { [weak self] ids in
            guard let self else { return }
            let wanted = Set(ids)
            for id in Array(self.subscriptions.keys) where !wanted.contains(id) {
                self.subscriptions.removeValue(forKey: id)?.dispose()
            }
            for id in ids where self.subscriptions[id] == nil {
                let disposable = DisposableSet()
                // Reuse the stock reference-counted poller: server timeout,
                // pts-gap handling and dedup are shared with an open chat.
                if id.namespace == Namespaces.Peer.CloudChannel {
                    disposable.add(account.viewTracker.polledChannel(peerId: id).start())
                }
                disposable.add(goldgramSeedDiscussion(account: account, peerId: id).start())
                self.subscriptions[id] = disposable
            }
        }))
    }
    func stop() {
        self.refresh.dispose()
        for disposable in self.subscriptions.values { disposable.dispose() }
        self.subscriptions.removeAll()
    }
}

// #107: an iOS-discretionary BGAppRefresh window, not a keep-alive.
// Use ONLY user-pinned verified linked discussions and the existing PTS
// difference replay. Correct original evidence must precede subsequent edits.
public func goldgramRefreshPriorityDiscussions(account: Account) -> Signal<Never, NoError> {
    return account.postbox.transaction { transaction -> [PeerId] in
        guard goldgramNativeHistoryEnabled(),
              goldgramCaptureEnabled(accountPeerId: account.peerId, transaction: transaction) else {
            return []
        }
        goldgramDrainPending(accountPeerId: account.peerId, transaction: transaction)
        return Array(goldgramPriorityPeers(transaction: transaction,
            accountPeerId: account.peerId).prefix(3))
    }
    |> mapToSignal { ids -> Signal<Never, NoError> in
        return ids.reduce(Signal<Never, NoError>.complete()) { previous, id in
            return previous |> then(standalonePollChannelOnce(
                accountPeerId: account.peerId, postbox: account.postbox,
                network: account.network, peerId: id,
                stateManager: account.stateManager
            ))
        }
    }
}

// The UI owns this subscription while the selected account is the active
// service master, including native background execution / push wake windows.
// Stop polling when iOS execution time ends or the account switches.
public func goldgramMonitorDiscussions(account: Account) -> Signal<Never, NoError> {
    return Signal { _ in
        let queue = Queue(name: "GoldgramDiscussionMonitor")
        let impl = QueueLocalObject(queue: queue, generate: { GoldgramDiscussionMonitor(account: account, queue: queue) })
        return ActionDisposable { impl.with { $0.stop() } }
    }
}
