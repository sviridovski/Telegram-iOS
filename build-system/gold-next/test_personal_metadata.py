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
    try GoldgramPersonalStore.write(data, to: url, account: 42)
    let loaded = try GoldgramPersonalStore.read(url, account: 42)
    precondition(loaded.bookmarks == data.bookmarks && loaded.contacts == data.contacts)
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
