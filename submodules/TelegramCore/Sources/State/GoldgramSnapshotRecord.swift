import Foundation

// Postbox Codable does NOT support UInt32: its default keyed overload enters
// the unsupported single-value encoder and traps, even for a zero flag value.
// Preserve every flag bit with Int32(bitPattern:) on write and UInt32(bitPattern:)
// on read. Keep this wire record Foundation-only for the real-codec CI fixture.
struct GoldgramSnapshot: Codable {
    let peer: Int64
    let namespace: Int32
    let id: Int32
    let unique: Int64?
    let grouping: Int64?
    let thread: Int64?
    let timestamp: Int32
    let flags: Int32
    let tags: Int32
    let globalTags: Int32
    let localTags: Int32
    let author: Int64?
    let text: String
    let objects: Data
    let forwardAuthor: Int64?
    let forwardSource: Int64?
    let forwardMessagePeer: Int64?
    let forwardMessageNamespace: Int32?
    let forwardMessageId: Int32?
    let forwardDate: Int32?
    let forwardSignature: String?
    let forwardPsa: String?
    let forwardFlags: Int32?

}
