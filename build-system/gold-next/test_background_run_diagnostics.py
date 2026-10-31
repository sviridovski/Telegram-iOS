#!/usr/bin/env python3
"""#108: OS background launch, scoped MTProto results and outcome provenance.

Checks production source boundaries. Full Swift compile + actual SQLite writer
tests remain required separately by the same GitHub Actions workflow.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
core = (root / "submodules/TelegramCore/Sources/State/GoldgramNativeHistory.swift").read_text()
state = (root / "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift").read_text()
app = (root / "submodules/TelegramUI/Sources/AppDelegate.swift").read_text()
ui = (root / "build-system/gold-next/GoldgramArchiveScreen.swift").read_text()

trace = core.split("public struct GoldgramBackgroundRefreshRun: Codable", 1)[1].split("// #97:", 1)[0]
assert "rows.suffix(8)" in trace, "BG test trace must remain bounded"
assert "PropertyListEncoder().encode" in trace, "BG diagnostic persistence required"
assert "lock.lock()" in trace and "defer { lock.unlock() }" in trace
assert 'rows[index].outcome == "running"' in trace, "late callbacks cannot change closed runs"
for field in ("targets", "requests", "completed", "difference", "empty", "tooLong",
              "unavailable", "returnedNew", "returnedEdits", "originalsQueued"):
    assert field in trace, field
for sensitive in ("message.text", "messageId", "senderId", "peerId", "mediaKeys"):
    assert sensitive not in trace, "BG records must not contain message identifiers or content"

bg = app.split("private func goldgramRunRefresh(", 1)[1].split(
    "private var clearNotificationsManager", 1)[0]
assert "GoldgramBackgroundRefreshTrace.begin(" in bg, "OS invocation must create run"
assert "excludingActiveToken: self.goldgramRefreshActiveToken" in bg, (
    "Current BG task must be excluded when reconciling old records"
)
# #125: protect against other stale structural tests still requiring the old
# exact no-argument invocation. Scan all existing Goldgram Python checks.
old_invocation = "GoldgramBackgroundRefreshTrace." + "begin()"
for check_file in (root / "build-system/gold-next").glob("*.py"):
    assert old_invocation not in check_file.read_text(), (
        f"Update stale BG begin assertion in {check_file.name}"
    )
assert '"ios_expiration"' in bg and '"goldgram_deadline"' in bg, "OS expiration != app deadline"
assert "GoldgramBackgroundRefreshTrace.finish(token, reason: reason)" in bg
assert "guard let self, !finished else { return }" in bg, "BG completion must run once"
assert 'reason = "no_targets"' in bg and 'reason = "incomplete_requests"' in bg
assert "goldgramRefreshPriorityDiscussions(" in bg and "diagnosticToken: token" in bg

func = core.split("public func goldgramRefreshPriorityDiscussions(", 1)[1].split(
    "// The UI owns this subscription", 1)[0]
assert "goldgramPrioritySelection(transaction:" in func, "Capture eligibility and pinned rejection reasons"
assert ".prefix(3)" in func
assert "GoldgramBackgroundRefreshTrace.targets(" in func
assert "GoldgramBackgroundRefreshTrace.request(" in func
assert "GoldgramBackgroundRefreshTrace.completedRequest(" in func
assert "standalonePollChannelOnce(" in func
assert "diagnosticToken: diagnosticToken" in func
assert "joinChannel(" not in func
assert "GoldgramBackgroundRefreshTrace.selection(" in func, "Pinned validation results must be recorded"
assert 'GoldgramBackgroundRefreshTrace.phase(diagnosticToken, "postbox_entered")' in func
assert '"storedPinned"' not in func, "Only serializable sanitized counts belong in diagnostics"


standalone = state.split("public func standalonePollChannelOnce(", 1)[1].split(
    "\nfunc keepPollingChannel(", 1)[0]
assert "diagnosticToken: String? = nil" in standalone
assert "diagnosticToken: diagnosticToken)" in standalone
poll = state.split("private func pollChannel(", 1)[1]
assert "diagnosticToken: String? = nil" in poll
for kind in ('"difference"', '"empty"', '"tooLong"', '"unavailable"'):
    assert "kind: " + kind in poll, "missing status " + kind
assert "new: newMessages.count, edits: edits" in poll
assert "GoldgramBackgroundRefreshTrace.originalQueued(diagnosticToken)" in poll
assert poll.index("GoldgramBackgroundRefreshTrace.originalQueued(diagnosticToken)") < poll.index(
    "updatedState.addMessages([message], location: .UpperHistoryBlock)"
), "original evidence must be queued before Postbox coalescing"
assert "func goldgramCaptureServerOriginal(" in core and "-> Bool" in core, (
    "Only accepted genuine-original queue writes are counted"
)
assert "GoldgramBackgroundRefreshRunsV1" in ui and "PropertyListDecoder()" in ui
assert "в очередь SQLite" in ui and "не подтверждение сохранения" in ui
print("Goldgram #108: per-launch refresh evidence and interruption reasons verified")
