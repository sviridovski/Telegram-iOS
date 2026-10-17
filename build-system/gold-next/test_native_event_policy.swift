@main
struct NativeEventPolicyFixture {
    static func main() {
        func record(_ old: String?, _ text: String, date: Int32 = 10, hidden: Bool = false,
                    oldMedia: [String] = [], media: [String] = [], entities: Bool = false, since: Int32 = 0, previousDate: Int32 = 0) -> Bool {
            return GoldgramEventPolicy.shouldArchiveEdit(previousText: old, currentText: text,
                previousMedia: oldMedia, currentMedia: media, entitiesChanged: entities, editDate: date, hidden: hidden, captureSince: since, previousEditDate: previousDate)
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
        precondition(!record(nil, "old history", date: 9, since: 10), "scrolling old edited history must not log it")
        precondition(!record("old A", "old B", date: 9, since: 10), "a historical difference is not a new edit")
        precondition(record("old message", "edited now", date: 11, since: 10), "old sent date must not block a NEW edit")
        precondition(!record("same", "same", date: 11, since: 10), "reloading an already known edit is not another event")
        precondition(!record("newer", "stale reply", date: 11, since: 10, previousDate: 12), "older history responses cannot reverse the revision sequence")
        var previous = "A"
        var captured: [String] = []
        for text in ["B", "B", "C", "A", "A"] {
            if record(previous, text, date: 20, since: 10) { captured.append(text) }
            previous = text
        }
        precondition(captured == ["B", "C", "A"], "all distinct delivered edits, including a revert; no reload duplicates")
        let unknown = GoldgramEventPolicy.normalizeInlineHistory(baseline: "Ден: первая полученная правка", originalObserved: false, revisions: [])
        precondition(unknown.baseline.isEmpty && unknown.revisions == ["Ден: первая полученная правка"], "unknown-original edit still has one gray visible revision")
        let chain = GoldgramEventPolicy.normalizeInlineHistory(baseline: "Original", originalObserved: true, revisions: ["B", "C"])
        precondition(chain.baseline == "Original" && chain.revisions == ["B", "C"], "observed original and multiple edits preserved")
        let firstKnown = GoldgramEventPolicy.normalizeInlineHistory(baseline: "Already edited", originalObserved: false, revisions: ["next edit"])
        precondition(firstKnown.baseline == "Already edited" && firstKnown.revisions == ["next edit"])
        print("Goldgram #88: actual native event policy rejects metadata and accepts text/media/revert edits")
    }
}
