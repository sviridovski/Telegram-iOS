#!/usr/bin/env python3
"""Compile and run the actual Foundation-only personal metadata model."""
from pathlib import Path
import subprocess
import tempfile
native = (Path(__file__).resolve().parents[2] / "submodules/ChatListUI/Sources/GoldgramAuthorSearch.swift").read_text()
model = native.split("// BEGIN GOLDGRAM_PERSONAL_MODEL_V1\n", 1)[1].split("// END GOLDGRAM_PERSONAL_MODEL_V1", 1)[0]
checks = r'''
private func run() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("references.json")
    var data = try GoldgramPersonalStore.read(url, account: 42)
    precondition(data.bookmarks.isEmpty)
    let a = GoldgramPersonalBookmark(peerKind: 2, peerId: 123, messageId: 7, authorId: 9, title: "Тест",
        date: 100, archive: true, folder: "Работа", tags: ["тег"], note: "Личная заметка")
    precondition(data.put(a))
    var same = a; same.peerKind = 3; same.note = "Новая заметка"
    precondition(data.put(same) && data.bookmarks.count == 1)
    var different = a; different.peerKind = 1
    precondition(data.put(different) && data.bookmarks.count == 2)
    var invalid = a; invalid.peerId = 0
    precondition(!data.put(invalid))
    precondition(data.putContact(GoldgramPersonalContact(id: 9, title: "Пользователь", alias: "Имя", note: "Тест")))
    // Read legacy JSON without presets; append and replace a named set.
    let legacy = try JSONEncoder().encode(data)
    let old = try JSONDecoder().decode(GoldgramPersonalData.self, from: legacy)
    precondition(old.presets == nil)
    var preset = GoldgramSearchPreset(name: "Работа", text: "тест", source: 2, period: 0, event: 0,
        media: 0, oldest: true, from: 100, through: 200, authorId: 9, authorName: "Автор",
        peerKind: 2, peerId: 123, peerName: "Канал")
    precondition(data.putPreset(preset))
    preset.text = "новый"; precondition(data.putPreset(preset) && data.presets?.count == 1)
    preset.from = 300; precondition(!data.putPreset(preset))
    try GoldgramPersonalStore.write(data, to: url, account: 42)
    let loaded = try GoldgramPersonalStore.read(url, account: 42)
    precondition(loaded.bookmarks == data.bookmarks && loaded.contacts == data.contacts && loaded.presets == data.presets)
    do { _ = try GoldgramPersonalStore.read(url, account: 43); fatalError("cross account") } catch {}
    try Data("broken".utf8).write(to: url)
    do { _ = try GoldgramPersonalStore.read(url, account: 42); fatalError("corrupt accepted") } catch {}
    let broken = try Data(contentsOf: url)
    precondition(broken == Data("broken".utf8))
    print("Goldgram #257 personal metadata: atomic roundtrip, canonical dedup, account/corruption guards OK")
}
try run()
'''
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / "main.swift"
    source.write_text("import Foundation\n" + model + checks)
    binary = Path(tmp) / "test"
    subprocess.run(["swiftc", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

# Compile the actual layout normalization/persistence model, independent of UIKit.
layout_model = native.split("// BEGIN GOLDGRAM_LAYOUT_MODEL_V1\n", 1)[1].split("// END GOLDGRAM_LAYOUT_MODEL_V1", 1)[0]
layout_checks = r'''
private func runLayoutChecks() {
let suite = "GoldgramLayoutTest-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
var layout = GoldgramLayoutPreferences.load(defaults)
precondition(!layout.customDashboard && layout.visibleDashboard.count == 14 && layout.visibleMenu == [100])
var oldLayout = layout
oldLayout.dashboardOrder.removeAll { $0 == 33 }
oldLayout.normalize()
precondition(!oldLayout.customDashboard && oldLayout.dashboardOrder[3] == 33)
layout.dashboardOrder = [31, 31, 999, 29]
layout.dashboardHidden = [20, 999, 20]
layout.dashboardPinned = [31, 20, 999]
layout.menuOrder = [103, 100, 100, 888]
layout.menuHidden = [101, 102]
layout.save(defaults)
let loaded = GoldgramLayoutPreferences.load(defaults)
precondition(loaded.dashboardOrder.count == 14 && loaded.dashboardOrder.prefix(2).elementsEqual([31,29]))
precondition(loaded.dashboardHidden == [20] && loaded.dashboardPinned == [31])
precondition(!loaded.visibleDashboard.contains(20) && loaded.visibleMenu == [103,100])
precondition(loaded.customDashboard)
GoldgramLayoutPreferences().save(defaults)
precondition(!GoldgramLayoutPreferences.load(defaults).customDashboard)
defaults.set(Data("broken".utf8), forKey: GoldgramLayoutPreferences.key)
precondition(GoldgramLayoutPreferences.load(defaults).visibleDashboard.count == 14)
print("Goldgram #260 dashboard and menu preferences: defaults, ordering, hide/pin, roundtrip, corruption fallback OK")
}
runLayoutChecks()
'''
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / "main.swift"
    source.write_text("import Foundation\n" + layout_model + layout_checks)
    binary = Path(tmp) / "test"
    subprocess.run(["swiftc", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

media_model = native.split("// BEGIN GOLDGRAM_MEDIA_MODEL_V1\n", 1)[1].split("// END GOLDGRAM_MEDIA_MODEL_V1", 1)[0]
media_checks = r'''
precondition(GoldgramMediaCategory.allCases.count == 8)
precondition(GoldgramMediaRules.families(nil) == [0,1,2,3,4,5])
precondition(GoldgramMediaRules.families(.circle) == [3] && GoldgramMediaRules.families(.gif) == [5])
precondition(GoldgramMediaRules.acceptsSize(nil, minimum: 0))
precondition(!GoldgramMediaRules.acceptsSize(nil, minimum: 1))
precondition(GoldgramMediaRules.acceptsSize(10, minimum: 10))
precondition(GoldgramMediaRules.matches("ДОК", name: "документ.pdf", caption: ""))
precondition(GoldgramMediaRules.matches("тест", name: "a", caption: "Тест"))
precondition(!GoldgramMediaRules.matches("abc", name: "def", caption: ""))
precondition(GoldgramMediaRules.extensionFor("a.PDF", fallback: "bin") == "pdf")
precondition(GoldgramMediaRules.extensionFor("a.bad/unsafe", fallback: "bin") == "bin")
print("Goldgram #261 media category, size, matching and extension rules OK")
'''
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / "main.swift"
    source.write_text("import Foundation\n" + media_model + media_checks)
    binary = Path(tmp) / "test"
    subprocess.run(["swiftc", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

# Regression #263: the media browser must not clear on speculative UIKit
# disappearance (interactive sheet drag/pop can be cancelled).
# This source contract is not an on-device UIKit gesture test.
media_screen = native.split("private final class GoldgramMediaCenter:", 1)[1].split("// BEGIN GOLDGRAM_PERSONAL_MODEL_V1", 1)[0]
assert "override func viewWillDisappear" not in media_screen
assert "override func viewDidDisappear" not in media_screen
appearance = media_screen.split("override func viewDidAppear", 1)[1].split("private func rebuildCategories", 1)[0]
assert "guard accountOK else {" in appearance
assert "clear()" in appearance and "started = false" in appearance
assert "if !started { restart() }" in appearance
assert media_screen.count("clear()") == 3  # definition, account invalidation, explicit restart
deinit_line = next(line for line in media_screen.splitlines() if "deinit {" in line)
for task in ("queryTask", "dialogsTask", "previewTask", "downloadTask"):
    assert task + ".dispose()" in deinit_line
assert "handingOff = true" in media_screen and "GoldgramAuthorSearchBridge.nativeJump" in media_screen
print("Goldgram #263 media lifecycle contract: cancelled transitions preserve results and cursors; deinit disposal retained")
