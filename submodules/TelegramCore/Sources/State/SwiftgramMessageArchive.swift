import Foundation
import Postbox

/// Local, text-only snapshots taken before a server edit or deletion is applied.
/// Deletion updates do not identify the person who requested the deletion.
public final class SwiftgramMessageArchive {
    public enum Kind: String, Codable {
        case deleted
        case edited
    }

    public struct Entry: Codable {
        public let kind: Kind
        public let peerNamespace: Int32
        public let peerId: Int64
        public let messageNamespace: Int32
        public let messageId: Int32
        public let threadId: Int64?
        public let chatTitle: String
        public let authorTitle: String
        public let originalTimestamp: Int32
        public let eventTimestamp: TimeInterval
        public let previousText: String
        public let currentText: String?
    }

    public static let shared = SwiftgramMessageArchive()
    private let queue = DispatchQueue(label: "org.swiftgram.message-archive", qos: .utility)
    private var entriesByAccount: [Int64: [Entry]] = [:]
    private var latestEditedTextByAccount: [Int64: [String: String]] = [:]
    private let limit = 5000

    private init() {}

    private func fileURL(accountId: Int64) -> URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let archiveDirectory = directory.appendingPathComponent("SwiftgramMessageArchive", isDirectory: true)
        try? FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        return archiveDirectory.appendingPathComponent("\(accountId).json")
    }

    private func entries(accountId: Int64) -> [Entry] {
        if let entries = self.entriesByAccount[accountId] {
            return entries
        }
        let loaded = self.fileURL(accountId: accountId)
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        self.entriesByAccount[accountId] = loaded
        var latest: [String: String] = [:]
        for entry in loaded where entry.kind == .edited {
            latest["\(entry.peerNamespace):\(entry.peerId):\(entry.messageNamespace):\(entry.messageId)"] = entry.previousText
        }
        self.latestEditedTextByAccount[accountId] = latest
        return loaded
    }

    public func snapshot(accountId: PeerId, message: Message, chatTitle: String, kind: Kind, currentText: String? = nil) {
        guard message.id.namespace == Namespaces.Message.Cloud else {
            return
        }
        let text = message.text
        guard !text.isEmpty, kind == .deleted || text != currentText else {
            return
        }
        let entry = Entry(
            kind: kind,
            peerNamespace: message.id.peerId.namespace,
            peerId: message.id.peerId.id._internalGetInt64Value(),
            messageNamespace: message.id.namespace,
            messageId: message.id.id,
            threadId: message.threadId,
            chatTitle: chatTitle,
            authorTitle: message.author?.debugDisplayTitle ?? "Неизвестный автор",
            originalTimestamp: message.timestamp,
            eventTimestamp: Date().timeIntervalSince1970,
            previousText: text,
            currentText: currentText
        )
        let account = accountId.id._internalGetInt64Value()
        self.queue.async {
            var stored = self.entries(accountId: account)
            stored.append(entry)
            if stored.count > self.limit {
                stored.removeFirst(stored.count - self.limit)
            }
            self.entriesByAccount[account] = stored
            if kind == .edited {
                self.latestEditedTextByAccount[account, default: [:]]["\(entry.peerNamespace):\(entry.peerId):\(entry.messageNamespace):\(entry.messageId)"] = entry.previousText
            }
            if let url = self.fileURL(accountId: account), let data = try? JSONEncoder().encode(stored) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    public func list(accountId: PeerId, kind: Kind) -> [Entry] {
        let account = accountId.id._internalGetInt64Value()
        return self.queue.sync {
            Array(self.entries(accountId: account).filter { $0.kind == kind }.reversed())
        }
    }

    public func previousText(accountId: PeerId, messageId: MessageId) -> String? {
        let account = accountId.id._internalGetInt64Value()
        return self.queue.sync {
            _ = self.entries(accountId: account)
            let key = "\(messageId.peerId.namespace):\(messageId.peerId.id._internalGetInt64Value()):\(messageId.namespace):\(messageId.id)"
            return self.latestEditedTextByAccount[account]?[key]
        }
    }
}
