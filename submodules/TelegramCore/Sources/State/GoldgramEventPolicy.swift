// Shared by native replay and the standalone Swift regression fixture.
enum GoldgramEventPolicy {
    static func shouldArchiveEdit(previousText: String?, currentText: String,
        previousMedia: [String], currentMedia: [String], entitiesChanged: Bool,
        editDate: Int32, hidden: Bool, captureSince: Int32 = 0, previousEditDate: Int32 = 0) -> Bool {
        guard editDate > 0, editDate >= captureSince, editDate >= previousEditDate, !hidden else { return false }
        guard let previousText else { return true } // honestly unknown original
        return previousText != currentText || previousMedia != currentMedia || entitiesChanged
    }
}
