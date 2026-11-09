import Foundation
import Darwin
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit
import EncryptionProvider


// Goldgram #66: account-scoped incoming personal-chat archive.
// This *only* uses the authenticated AccountStateManager accountPeerId;
// the old MxLastKnownUserId cached by the tweak is not a valid owner key.
private typealias GoldgramOriginalCallback = @convention(c) (
    Int64, Int32, Int64, Int32, UnsafePointer<CChar>?, Int32
) -> Void

private let goldgramOriginalCallback: GoldgramOriginalCallback? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "goldgram_archive_original") else {
        return nil
    }
    return unsafeBitCast(symbol, to: GoldgramOriginalCallback.self)
}()

private typealias GoldgramOriginalCallbackV2 = @convention(c) (
    Int64, Int32, Int64, Int32, Int64, Int64, Int64,
    UnsafePointer<CChar>?, Int32
) -> Void

private let goldgramOriginalCallbackV2: GoldgramOriginalCallbackV2? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "goldgram_archive_original_v2") else {
        return nil
    }
    return unsafeBitCast(symbol, to: GoldgramOriginalCallbackV2.self)
}()

func goldgramArchivePersonalOriginal(
    accountPeerId: PeerId, message: StoreMessage, live: Bool
) {
    // Directly capture full live updateNewMessage payloads, including messages
    // sent from another logged-in client. The old bridge only handled incoming
    // messages and is intentionally not the owner while native capture is ON.
    if live && goldgramNativeHistoryEnabled(),
       case let .Id(id) = message.id, id.peerId.namespace == Namespaces.Peer.CloudUser {
        goldgramCaptureServerOriginal(accountPeerId: accountPeerId, message: message,
            peerKind: 0, evidenceSource: "live_update")
        return
    }
    guard !goldgramNativeHistoryEnabled(), UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled"),
          goldgramOriginalCallbackV2 != nil || goldgramOriginalCallback != nil,
          case let .Id(messageId) = message.id,
          messageId.peerId.namespace == Namespaces.Peer.CloudUser,
          message.flags.contains(.Incoming),
          !message.text.isEmpty else { return }
    let accountId = accountPeerId.id._internalGetInt64Value()
    let peerId = messageId.peerId.id._internalGetInt64Value()
    guard accountId > 0, peerId > 0, messageId.id > 0 else { return }
    // Telegram stores the true server sent time in seconds. SQLite uses ms.
    // Only user authors are asserted here; all other author kinds stay unknown.
    let sender: Int64
    if let authorId = message.authorId,
       authorId.namespace == Namespaces.Peer.CloudUser {
        sender = authorId.id._internalGetInt64Value()
    } else {
        sender = 0
    }
    let sentAt = message.timestamp > 0 ? Int64(message.timestamp) * 1000 : 0
    let threadId = message.threadId ?? 0

    message.text.withCString { pointer in
        if let writer = goldgramOriginalCallbackV2 {
            writer(accountId, 0, peerId, messageId.id, sender, sentAt,
                   threadId, pointer, live ? 1 : 0)
        } else if let writer = goldgramOriginalCallback {
            // Leave the original #66 ABI as a compatibility fallback.
            writer(accountId, 0, peerId, messageId.id, pointer, live ? 1 : 0)
        }
    }
}

// #68: resolve injected Mx lazily via the same stable C bridge as #67.
// No attempt to infer an account from the global Mx UserDefaults cache.
private typealias GoldgramEditCallback = @convention(c) (
    Int64, Int32, Int64, Int32, Int64, Int64, Int64, Int64,
    UnsafePointer<CChar>?
) -> Void

private let goldgramEditCallback: GoldgramEditCallback? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "goldgram_archive_edit_v1") else {
        return nil
    }
    return unsafeBitCast(symbol, to: GoldgramEditCallback.self)
}()

func goldgramArchivePrivateEdit(
    accountPeerId: PeerId, message: StoreMessage, serverEditAt: Int64
) {
    guard !goldgramNativeHistoryEnabled(), UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled"),
          let writer = goldgramEditCallback,
          case let .Id(messageId) = message.id,
          messageId.peerId.namespace == Namespaces.Peer.CloudUser,
          message.flags.contains(.Incoming),
          !message.text.isEmpty else { return }

    let accountId = accountPeerId.id._internalGetInt64Value()
    let peerId = messageId.peerId.id._internalGetInt64Value()
    guard accountId > 0, peerId > 0, messageId.id > 0 else { return }

    let sender: Int64
    if let author = message.authorId,
       author.namespace == Namespaces.Peer.CloudUser {
        sender = author.id._internalGetInt64Value()
    } else {
        sender = 0
    }
    let sentAt = message.timestamp > 0 ? Int64(message.timestamp) * 1000 : 0
    let threadId = message.threadId ?? 0
    message.text.withCString { pointer in
        writer(accountId, 0, peerId, messageId.id, sender,
               sentAt, threadId, serverEditAt, pointer)
    }
}


// Goldgram #75: live public text capture. CloudChannel namespace contains
// both broadcast channels and groups; only TelegramChannel.info resolves kind.
private typealias GoldgramPublicOriginalCallback = @convention(c) (
    Int64, Int32, Int64, Int32, Int64, Int64, Int64, UnsafePointer<CChar>?
) -> Void
private let goldgramPublicOriginalCallback: GoldgramPublicOriginalCallback? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "goldgram_archive_public_original_v1") else {
        return nil
    }
    return unsafeBitCast(symbol, to: GoldgramPublicOriginalCallback.self)
}()

func goldgramVerifiedPublicKind(peerId: PeerId, peer: Peer?) -> Int32? {
    if peerId.namespace == Namespaces.Peer.CloudGroup {
        return peer is TelegramGroup ? 1 : nil
    }
    if peerId.namespace == Namespaces.Peer.CloudChannel,
       let channel = peer as? TelegramChannel {
        switch channel.info {
        case .group: return 2
        case .broadcast: return 3
        }
    }
    return nil
}

func goldgramArchivePublicOriginal(
    accountPeerId: PeerId, message: StoreMessage, peerKind: Int32
) {
    // Called only for accepted live public new-message updates, after peer kind
    // verification. Save the true original before deferred Postbox application.
    if goldgramNativeHistoryEnabled() {
        goldgramCaptureServerOriginal(accountPeerId: accountPeerId, message: message,
            peerKind: peerKind, evidenceSource: "live_update")
        return
    }
    guard !goldgramNativeHistoryEnabled(), UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled"),
          let writer = goldgramPublicOriginalCallback,
          peerKind >= 1, peerKind <= 3,
          case let .Id(messageId) = message.id,
          messageId.id > 0, !message.text.isEmpty else { return }
    let accountId = accountPeerId.id._internalGetInt64Value()
    let peerId = messageId.peerId.id._internalGetInt64Value()
    guard accountId > 0, peerId > 0 else { return }
    let senderId: Int64
    if let author = message.authorId,
       author.namespace == Namespaces.Peer.CloudUser {
        senderId = author.id._internalGetInt64Value()
    } else {
        senderId = 0
    }
    let sentAt = message.timestamp > 0 ? Int64(message.timestamp) * 1000 : 0
    let threadId = message.threadId ?? 0
    message.text.withCString { pointer in
        writer(accountId, peerKind, peerId, messageId.id,
               senderId, sentAt, threadId, pointer)
    }
}


// #77: edits from validated Telegram group/channel update events only.
private typealias GoldgramPublicEditCallback = @convention(c) (
    Int64, Int32, Int64, Int32, Int64, Int64, Int64, Int64,
    UnsafePointer<CChar>?
) -> Void
private let goldgramPublicEditCallback: GoldgramPublicEditCallback? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "goldgram_archive_public_edit_v1") else {
        return nil
    }
    return unsafeBitCast(symbol, to: GoldgramPublicEditCallback.self)
}()

func goldgramArchivePublicEdit(
    accountPeerId: PeerId, message: StoreMessage,
    peerKind: Int32, editedAt: Int64
) {
    guard !goldgramNativeHistoryEnabled(), UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled"),
          let writer = goldgramPublicEditCallback,
          peerKind >= 1, peerKind <= 3,
          case let .Id(messageId) = message.id,
          messageId.id > 0, !message.text.isEmpty else { return }
    let accountId = accountPeerId.id._internalGetInt64Value()
    let peerId = messageId.peerId.id._internalGetInt64Value()
    guard accountId > 0, peerId > 0 else { return }
    let senderId: Int64
    if let author = message.authorId,
       author.namespace == Namespaces.Peer.CloudUser {
        senderId = author.id._internalGetInt64Value()
    } else {
        senderId = 0
    }
    let sentAt = message.timestamp > 0 ? Int64(message.timestamp) * 1000 : 0
    let threadId = message.threadId ?? 0
    message.text.withCString { pointer in
        writer(accountId, peerKind, peerId, messageId.id,
               senderId, sentAt, threadId, editedAt, pointer)
    }
}
