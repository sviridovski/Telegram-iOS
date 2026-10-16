@main
struct NativeEventPolicyFixture {
    static func main() {
        func record(_ old: String?, _ text: String, date: Int32 = 10, hidden: Bool = false,
                    oldMedia: [String] = [], media: [String] = [], entities: Bool = false) -> Bool {
            return GoldgramEventPolicy.shouldArchiveEdit(previousText: old, currentText: text,
                previousMedia: oldMedia, currentMedia: media, entitiesChanged: entities, editDate: date, hidden: hidden)
        }
        precondition(!record("same", "same"), "reaction/view metadata isn't an edit")
        precondition(!record(nil, "headline", date: 0), "unknown original + no edit date isn't proof")
        precondition(!record(nil, "headline", hidden: true), "hidden update isn't visible editing")
        precondition(!record("old", "new", date: 0), "a partial/refetched payload alone isn't an edit")
        precondition(record("old", "new"))
        precondition(record(nil, "first known edited text"))
        precondition(record("same", "same", entities: true), "actual formatting change")
        precondition(record("", "", oldMedia: ["photo1"], media: ["photo2"]), "actual media replacement")
        precondition(record("B", "A"), "reverting is also a content edit")
        print("Goldgram #83: actual native event policy rejects metadata and accepts text/media/revert edits")
    }
}
