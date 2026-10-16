import Foundation

@main
struct TestArchiveGrouping {
    static func main() {
        let post: [String: Any] = ["peerKind": 3, "peerId": 100, "channelId": 100,
            "channelName": "Бета", "peerName": "Бета", "messageCount": 2,
            "linkedPeerKind": 2, "linkedPeerId": 200]
        let comment: [String: Any] = ["peerKind": 2, "peerId": 200, "channelId": 100,
            "channelName": "Бета", "peerName": "Обсуждение Беты", "messageCount": 3,
            "linkedPeerKind": 3, "linkedPeerId": 100]
        let homonym: [String: Any] = ["peerKind": 3, "peerId": 300, "channelId": 300,
            "channelName": "Бета", "messageCount": 1]
        let alpha: [String: Any] = ["peerKind": 3, "peerId": 400, "channelId": 400,
            "channelName": "Альфа", "messageCount": 1]
        let unlinked: [String: Any] = ["peerKind": 2, "peerId": 500,
            "peerName": "Обычная группа", "messageCount": 9]
        // Include comments-first order and a later page's publication row.
        let rows = GoldgramArchiveGrouping.folders([comment, unlinked, homonym, alpha, post], category: 2)
        precondition(rows.count == 3, "Unlinked group hidden, homonymous channels separate")
        precondition(rows[0]["displayName"] as? String == "Альфа", "Alphabetic visible title order")
        let beta = rows.first { ($0["messageCount"] as? NSNumber)?.intValue == 5 }!
        let sources = beta["sources"] as! [[String: Any]]
        precondition(sources.count == 2, "Publication and discussion deduplicated across pages")
        precondition(Set(sources.map { "\(($0["peerKind"] as! NSNumber).intValue):\(($0["peerId"] as! NSNumber).int64Value)" }) == Set(["3:100", "2:200"]))
        let justComments = GoldgramArchiveGrouping.folders([comment], category: 2)
        precondition((justComments[0]["sources"] as! [[String: Any]]).count == 2,
            "Known linked channel included even if its event row is on a later page")
        let groups = GoldgramArchiveGrouping.folders([comment, unlinked], category: 1)
        precondition(groups.count == 2)
        precondition(groups.allSatisfy { ($0["sources"] as! [[String: Any]]).count == 1 },
            "Groups category preserves group-only scope")
        let unknown = GoldgramArchiveGrouping.folders([["peerKind": 3, "peerId": 900]], category: 2)
        precondition(unknown[0]["displayName"] as? String == "Канал #900")
        precondition(GoldgramArchiveGrouping.folders([], category: 2).isEmpty)
        var deletedPost = post; deletedPost["lastMessageAt"] = 300
        var deletedComment = comment; deletedComment["lastMessageAt"] = 400
        var deletedOther = unlinked; deletedOther["lastMessageAt"] = 500
        let deleted = GoldgramArchiveGrouping.folders([deletedPost, deletedComment, deletedOther], category: 3)
        precondition(deleted.count == 2)
        precondition(deleted[0]["displayName"] as? String == "Обычная группа", "Latest deletion first")
        precondition((deleted[1]["sources"] as! [[String: Any]]).count == 2)
        print("Goldgram #80: actual Swift grouping identity, linked sources, pagination merge, names/sort OK")
    }
}
