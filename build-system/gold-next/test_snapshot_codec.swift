import Foundation

@main
struct SnapshotCodecFixture {
    private struct LegacyUnsignedFlags: Encodable { let flags: UInt32 }

    static func main() {
        if CommandLine.arguments.contains("--legacy-unsigned") {
            // The #85 representation traps inside the REAL Postbox adapter.
            let encoder = PostboxEncoder()
            encoder.encode(LegacyUnsignedFlags(flags: 0), forKey: "_")
            return // The runner rejects success: it requires the legacy trap.
        }
        let masks: [UInt32] = [0, 1, 1 << 30, 1 << 31, UInt32.max]
        for mask in masks {
            for forwarded in [false, true] {
                let record = GoldgramSnapshot(peer: 1234567890123, namespace: 0, id: 42,
                    unique: forwarded ? 9876543210123 : nil, grouping: forwarded ? 8 : nil,
                    thread: forwarded ? 9 : nil, timestamp: 1792180000,
                    flags: Int32(bitPattern: mask), tags: Int32(bitPattern: mask),
                    globalTags: Int32(bitPattern: mask), localTags: Int32(bitPattern: mask),
                    author: forwarded ? 9876543210 : nil, authorName: forwarded ? "Ден" : nil, text: "Оригинал 🗑\nИзменение 1",
                    objects: Data([0, 1, 127, 128, 255]),
                    forwardAuthor: forwarded ? 1234 : nil, forwardSource: forwarded ? 5678 : nil,
                    forwardMessagePeer: forwarded ? 5678 : nil, forwardMessageNamespace: forwarded ? 0 : nil,
                    forwardMessageId: forwarded ? 321 : nil, forwardDate: forwarded ? 1792170000 : nil,
                    forwardSignature: forwarded ? "Автор" : nil, forwardPsa: forwarded ? "test" : nil,
                    forwardFlags: forwarded ? 1 : nil)
                // Same entry path as CodableEntry.init/get; no JSON replacement
                // for Postbox's binary encoder, no mocked serialization.
                let encoder = PostboxEncoder()
                encoder.encode(record, forKey: "_")
                let decoder = PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData()))
                guard let restored = decoder.decode(GoldgramSnapshot.self, forKey: "_") else {
                    fatalError("Snapshot binary decode failed")
                }
                let json = JSONEncoder(); json.outputFormatting = [.sortedKeys]
                let expected = try! json.encode(record)
                let actual = try! json.encode(restored)
                precondition(expected == actual, "Every stored field must round-trip")
                precondition(UInt32(bitPattern: restored.flags) == mask)
                precondition(UInt32(bitPattern: restored.tags) == mask)
                precondition(UInt32(bitPattern: restored.globalTags) == mask)
                precondition(UInt32(bitPattern: restored.localTags) == mask)
            }
        }
        print("Goldgram #86: real snapshot/Postbox round-trip passed, including zero/all/high flag bits and forwarded/media metadata")
    }
}
