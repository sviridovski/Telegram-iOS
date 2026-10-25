#!/usr/bin/env python3
"""#110: distinguish BG bootstrap failure from genuinely absent pinned peers.

Safe app-owned counters only; no messages, group IDs or session content.
The full Swift/Bazel compilation separately validates API and type linkage.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
core = (root / "submodules/TelegramCore/Sources/State/GoldgramNativeHistory.swift").read_text()
app = (root / "submodules/TelegramUI/Sources/AppDelegate.swift").read_text()
ui = (root / "build-system/gold-next/GoldgramArchiveScreen.swift").read_text()

model = core.split("public struct GoldgramBackgroundRefreshRun: Codable", 1)[1].split(
    "public enum GoldgramBackgroundRefreshTrace", 1)[0]
for field in ("phase", "phaseAt", "storedPinned", "rejectedPeer", "rejectedLink",
              "rejectedGroup", "rejectedAccess"):
    assert "public var " + field + ": " in model, field
    assert "public var " + field + ": Int?" in model or (
        "public var " + field + ": String?" in model or "public var " + field + ": Double?" in model
    ), "New Codable fields must remain Optional for older persisted traces"
assert "peerId" not in model and "messageId" not in model and "text:" not in model
trace = core.split("public enum GoldgramBackgroundRefreshTrace", 1)[1].split("// #97:", 1)[0]
assert 'GoldgramBackgroundRefreshRunsV1' in trace, "Retain backwards-readable storage key"
assert "rows.suffix(8)" in trace and 'outcome == "running"' in trace
assert "func phase(" in trace and "func selection(" in trace

peers = core.split("private struct GoldgramPrioritySelection", 1)[1].split(
    "// Account-local, bounded list", 1)[0]
for reason in ("rejectedPeer", "rejectedLink", "rejectedGroup", "rejectedAccess"):
    assert "selection." + reason + " += 1" in peers
assert "apiInputPeer(discussion) != nil" in peers
assert "linkedId == groupId" in peers
assert "return goldgramPrioritySelection(transaction:" in peers
refresh = core.split("public func goldgramRefreshPriorityDiscussions(", 1)[1].split(
    "// The UI owns this subscription", 1)[0]
assert '"await_postbox"' in refresh and '"postbox_entered"' in refresh
assert 'GoldgramBackgroundRefreshTrace.selection(diagnosticToken,' in refresh
assert 'GoldgramBackgroundRefreshTrace.targets(diagnosticToken,' in refresh
assert '.prefix(3)' in refresh and 'standalonePollChannelOnce(' in refresh

bg = app.split("private func goldgramRunRefresh(", 1)[1].split(
    "private var clearNotificationsManager", 1)[0]
assert 'GoldgramBackgroundRefreshTrace.begin()' in bg
assert '"await_context"' in bg and '"context_ready"' in bg
assert '"await_account"' in bg and '"account_ready"' in bg
assert '"postbox_unreached"' in bg, "Unknown target count != an empty pinned list"
assert 'sample?.storedPinned == nil' in bg and 'sample?.storedPinned == 0' in bg
assert '"targets_unavailable"' in bg
assert 'Date().timeIntervalSince(started) > 60.0' in bg
assert '"stale_reclaimed"' in bg
assert 'self.goldgramRefreshActiveToken == token' in bg, "Old completion must not cancel newer task"
assert 'self.goldgramRefreshFinish = complete' in bg
assert 'Thread.isMainThread' in bg, "Stale cleanup must be synchronous on main"
assert '"ios_expiration"' in bg and '"goldgram_deadline"' in bg

assert 'let storedPinned: Int?' in ui and 'let phase: String?' in ui
assert 'нет данных №110' in ui and 'до Postbox не дошли' in ui
assert 'stale_reclaimed' in ui and 'targets_unavailable' in ui

# #111: the wakeup manager must own this capability. Bypassing a single
# Postbox transaction with ignoreDisabled=True leaves MTProto inactive.
wakeup = (root / "submodules/TelegramUI/Sources/SharedWakeupManager.swift").read_text()
workflow = (root / ".github/workflows/build.yml").read_text()
lease = wakeup.split("func acquireGoldgramRefreshLease(token: String)", 1)[1].split(
    "public init(", 1)[0]
assert 'self.goldgramRefreshLeaseToken = token' in lease
assert 'self.goldgramRefreshLeaseToken = nil' in lease
assert 'self.checkTasks()' in lease
assert 'self.goldgramRefreshLeaseToken == token' in lease
assert 'ActionDisposable' in lease and 'Queue.mainQueue().isCurrent()' in lease
assert 'self.goldgramRefreshLeaseToken != nil || self.silenceAudioRenderer != nil' in wakeup
assert '(self.goldgramRefreshLeaseToken != nil && primary)' in wakeup
assert 'account.shouldExplicitelyKeepWorkerConnections.set' in wakeup
assert 'account.postbox.setCanBeginTransactions(true)' in wakeup
assert 'self.goldgramRefreshLease?.dispose()' in bg
assert 'self.goldgramRefreshLease = nil' in bg
assert 'applicationContext.wakeupManager.acquireGoldgramRefreshLease(token: token)' in bg
assert '"wakeup_lease_active"' in bg and 'менеджеру Telegram разрешена фоновая работа' in ui
assert 'ignoreDisabled: true' not in refresh, "No unsafe blanket Postbox bypass"
assert 'Trim Bazel cache to 6 GiB' in workflow and 'cap = 6 * (1024 ** 3)' in workflow
assert 'actions/cache/save@v4' in workflow and 'actions/cache/restore@v4' in workflow

print("Goldgram #110–111: background Postbox lease, stages and bounded 6 GiB Bazel cache OK")
