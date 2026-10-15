import Foundation

// Pure presentation model shared by the UI and executable fixture tests.
enum GoldgramArchiveGrouping {
    static func fallbackName(_ row: [String: Any]) -> String {
        let kind = (row["peerKind"] as? NSNumber)?.int32Value ?? -1
        let id = (row["peerId"] as? NSNumber)?.int64Value ?? 0
        return "\(kind == 3 ? "Канал" : kind == 0 ? "Собеседник" : "Группа") #\(id)"
    }

    // Group by canonical peer identity, not by title: equal channel names are
    // distinct folders. Merge sources across pages and sort by visible name.
    static func folders(_ items: [[String: Any]], category: Int) -> [[String: Any]] {
        var groups: [String: [String: Any]] = [:]
        for entry in items {
            let kind = (entry["peerKind"] as? NSNumber)?.int32Value ?? -1
            let id = (entry["peerId"] as? NSNumber)?.int64Value ?? 0
            let channelId = (entry["channelId"] as? NSNumber)?.int64Value ?? 0
            // Unlinked supergroups still appear in Groups, never as channels.
            if category == 2 && kind != 3 && channelId <= 0 { continue }
            let key = channelId > 0 ? "channel:\(channelId)" : "peer:\(kind):\(id)"
            var group = groups[key] ?? [
                "displayName": entry["channelName"] as? String ?? entry["peerName"] as? String ?? fallbackName(entry),
                "sources": [[String: Any]](), "messageCount": NSNumber(value: 0)
            ]
            var members = group["sources"] as? [[String: Any]] ?? []
            func addSource(_ sourceKind: Int32, _ sourceId: Int64) {
                guard sourceId > 0, !members.contains(where: {
                    ($0["peerKind"] as? NSNumber)?.int32Value == sourceKind &&
                    ($0["peerId"] as? NSNumber)?.int64Value == sourceId
                }) else { return }
                members.append(["peerKind": NSNumber(value: sourceKind), "peerId": NSNumber(value: sourceId)])
            }
            addSource(kind, id)
            if category == 2,
               let linkedKind = (entry["linkedPeerKind"] as? NSNumber)?.int32Value,
               let linkedId = (entry["linkedPeerId"] as? NSNumber)?.int64Value {
                addSource(linkedKind, linkedId)
            }
            group["sources"] = members
            group["messageCount"] = NSNumber(value: ((group["messageCount"] as? NSNumber)?.intValue ?? 0)
                + ((entry["messageCount"] as? NSNumber)?.intValue ?? 0))
            groups[key] = group
        }
        return groups.keys.sorted { a, b in
            let lhs = groups[a]?["displayName"] as? String ?? a
            let rhs = groups[b]?["displayName"] as? String ?? b
            let order = lhs.localizedCaseInsensitiveCompare(rhs)
            return order == .orderedSame ? a < b : order == .orderedAscending
        }.compactMap { groups[$0] }
    }

}
