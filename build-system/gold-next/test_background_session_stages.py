#!/usr/bin/env python3
"""#114: trace BG master/connection gates before RPC without changing retry policy.

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
# #113 fields are optional: PropertyListDecoder must keep reading #108-112 rows.
for field, type_name in (("networkStatus", "String"), ("networkTransitions", "Int"),
                         ("firstOnlineAt", "Double"), ("rpcAttempts", "Int"),
                         ("rpcErrors", "Int"), ("lastRpcError", "String"),
                         ("rpcResponseAt", "Double"), ("rpcFinal", "Bool"),
                         ("rpcPts", "Int32"), ("rpcTimeout", "Int32")):
    assert f"public var {field}: {type_name}?" in model
    assert f"self.{field} = nil" in model
for operation in ("networkStatus", "rpcAttempt", "rpcError", "rpcResponse"):
    assert f"func {operation}(" in trace
assert '"rpc_enqueued"' in trace and '"rpc_error"' in trace and '"rpc_response"' in trace

# #114: account/MTProto readiness must be observed from account_ready,
# before a nested Postbox query or RPC, and disposed on completion/expiry.
for field, type_name in (("leaseActivatedAt", "Double"), ("serviceMasterMode", "String"), ("serviceMasterAt", "Double"), ("serviceMasterTransitions", "Int"), ("postboxMaster", "Bool"), ("postboxMasterAt", "Double"), ("postboxMasterTransitions", "Int"), ("networkAllowed", "Bool"), ("networkAllowedAt", "Double"), ("networkAllowedTransitions", "Int"), ("firstConnectingAt", "Double"), ("rpcEnqueuedAt", "Double"), ("rpcBudgetRemaining", "Double")):
    assert f"public var {field}: {type_name}?" in model
    assert f"self.{field} = nil" in model
for operation in ("leaseActivated", "serviceMaster", "postboxMaster", "networkPermission"):
    assert f"func {operation}(" in trace
assert 'row.rpcBudgetRemaining = max(0, 24.0 - (now - row.startedAt))' in trace
assert 'status == "connecting" && row.firstConnectingAt == nil' in trace
observer = core.split("public func goldgramObserveBackgroundConnectionReadiness(", 1)[1].split(
    "// #107:", 1)[0]
for gate in ("account.shouldBeServiceTaskMaster.get()", "account.postbox.isMasterClient()",
             "account.network.shouldKeepConnection.get()", "account.network.connectionStatus"):
    assert gate in observer, gate
assert 'let observations = DisposableSet()' in observer and 'return observations' in observer
assert 'shouldKeepConnection.set' not in observer and 'becomeMasterClient' not in observer
assert 'GoldgramBackgroundRefreshTrace.networkStatus(diagnosticToken,' in observer
account = (root / "submodules/TelegramCore/Sources/Account/Account.swift").read_text()
assert "combineLatest(self.shouldBeServiceTaskMaster.get(), postbox.isMasterClient())" in account
assert "self.network.shouldKeepConnection.set(shouldBeMaster)" in account
assert "shouldKeepConnection.set" not in observer, "Diagnostic must not override transport permissions"
assert "goldgramRefreshPriorityDiscussions(" in app, "Keep existing bounded discussion poll"
assert 'DispatchQueue.main.asyncAfter(deadline: .now() + 24.0)' in app, "Do not extend background lifetime"

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
assert "account.network.connectionStatus.start" not in refresh, "Only one token-scoped observer before Postbox"
assert "goldgramObserveBackgroundConnectionReadiness(" in app
assert "readinessDisposable.dispose()" in app, "Observers must stop on BG completion or cancellation"
assert "GoldgramBackgroundRefreshTrace.leaseActivated(token)" in app
assert "let postboxMaster: Bool?" in ui and "let networkAllowed: Bool?" in ui
assert "Шлюзы сети №114" in ui and "до лимита приложения" in ui

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
for field in ("networkStatus", "firstOnlineAt", "rpcAttempts", "rpcErrors",
              "lastRpcError", "rpcResponseAt", "rpcFinal", "rpcPts", "rpcTimeout"):
    assert f"let {field}: " in ui
assert 'RPC-подписок:' in ui and '"inner_postbox_entered"' in ui
utils = (root / "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift").read_text()
standalone = utils.split("public func standalonePollChannelOnce(", 1)[1].split(
    "func keepPollingChannel(", 1)[0]
assert '"inner_postbox_entered"' in standalone and '"replay_started"' in standalone
assert '"resolve_messages"' in standalone and '"resolve_peer_infos"' in standalone
poll = utils.split("private func pollChannel(", 1)[1].split("func ", 1)[0]
assert "GoldgramBackgroundRefreshTrace.rpcAttempt(diagnosticToken)" in poll
assert "GoldgramBackgroundRefreshTrace.rpcResponse(diagnosticToken," in poll
assert "GoldgramBackgroundRefreshTrace.rpcError(diagnosticToken," in poll
assert "return request.start(next:" in poll, "Count actual Network.request subscriptions"
assert "|> retryRequest" in poll, "Keep stock Telegram retry for this diagnostic atom"

# #111: the wakeup manager must own this capability. Bypassing a single
# Postbox transaction with ignoreDisabled=True leaves MTProto inactive.
wakeup = (root / "submodules/TelegramUI/Sources/SharedWakeupManager.swift").read_text()
workflow = (root / ".github/workflows/build.yml").read_text()
lease = wakeup.split("func acquireGoldgramRefreshLease(token: String, accountId: AccountRecordId)", 1)[1].split(
    "public init(", 1)[0]
assert 'self.goldgramRefreshLeaseToken = token' in lease
assert 'self.goldgramRefreshLeaseAccountId = accountId' in lease
assert 'self.goldgramRefreshLeaseToken = nil' in lease
assert 'self.goldgramRefreshLeaseAccountId = nil' in lease
assert 'self.checkTasks()' in lease
assert 'self.goldgramRefreshLeaseToken == token' in lease
assert 'ActionDisposable' in lease and 'Queue.mainQueue().isCurrent()' in lease
assert 'self.goldgramRefreshLeaseToken != nil || self.silenceAudioRenderer != nil' in wakeup
assert '(self.goldgramRefreshLeaseToken != nil && self.goldgramRefreshLeaseAccountId == account.id)' in wakeup
assert '(self.goldgramRefreshLeaseToken != nil && primary)' not in wakeup, "BG lease must not depend on a stale primary snapshot"
assert 'account.shouldExplicitelyKeepWorkerConnections.set' in wakeup
assert 'account.postbox.setCanBeginTransactions(true)' in wakeup
assert 'self.goldgramRefreshLease?.dispose()' in bg
assert 'self.goldgramRefreshLease = nil' in bg
assert 'applicationContext.wakeupManager.acquireGoldgramRefreshLease(' in bg
assert 'token: token, accountId: account.id)' in bg, "Lease must follow the selected BG poll account"
assert bg.index('guard let account = primary?.account') < bg.index('wakeupManager.acquireGoldgramRefreshLease(')
assert 'activeAccountContexts\n            |> take(1)\n            |> deliverOnMainQueue' in bg
assert '"wakeup_lease_active"' in bg and 'менеджеру Telegram разрешена фоновая работа' in ui
assert 'ignoreDisabled: true' not in refresh, "No unsafe blanket Postbox bypass"
assert 'Trim Bazel cache to 6 GiB' in workflow and 'cap = 6 * (1024 ** 3)' in workflow
assert 'actions/cache/save@v4' in workflow and 'actions/cache/restore@v4' in workflow

print("Goldgram #114: bounded BG gate readiness trace, existing RPC/replay, lease and cache OK")

# #115: foreground status labels must expose their TWO actual sources:
# raw MTProto flags and AccountStateManager.isUpdating. The network and
# updates.getDifference behavior must remain unaltered.
net = (root / "submodules/TelegramCore/Sources/Network/Network.swift").read_text()
manager = (root / "submodules/TelegramCore/Sources/State/AccountStateManager.swift").read_text()
foreground = core.split("// #115: bounded, opt-in foreground sync trace.", 1)[1].split(
    "// #97:", 1)[0]
for field in ("at", "stage", "rawNetwork", "stateManagerUpdating", "mtprotoFlags"):
    assert "public let " + field in foreground, field
assert '"GoldgramDiagnosticEnabledV1"' in foreground
assert '"GoldgramForegroundActiveV1"' in foreground
assert "updated.suffix(48)" in foreground, "Bound foreground trace storage"
assert 'last.stage == stage' in foreground, "Deduplicate repeated identical status"
assert 'guard defaults.bool(forKey: enabledKey)' in foreground
assert 'defaults.bool(forKey: foregroundKey)' in foreground
for forbidden in ("message.text", "accessHash", "authKey", "serializedMessage"):
    assert forbidden not in foreground, forbidden
assert 'mtprotoDiagnosticFlags.set(Int32(info.flags.rawValue))' in net
assert 'public var mtprotoDiagnosticFlags: Signal<Int32, NoError>' in net
assert '.updating(proxyAddress: info.proxyAddress)' in net and 'info.flags.intersection([.UpdatingConnectionContext, .PerformingServiceTasks])' in net, "Keep real MTProto status"
assert 'self._connectionStatus = _connectionStatus' in net
assert 'self._mtprotoDiagnosticFlags = _mtprotoDiagnosticFlags' in net
assert 'combineLatest(queue: networkStateQueue, self.stateManager.isUpdating, network.connectionStatus, network.mtprotoDiagnosticFlags)' in account
assert 'GoldgramForegroundSyncTrace.state(accountPeerId: diagnosticAccountPeerId,' in account
assert 'if isUpdating {' in account and 'return .updating(proxy: proxyState)' in account
assert 'GoldgramForegroundSyncTrace.lifecycle(active: false)' in app
assert app.count('GoldgramForegroundSyncTrace.lifecycle(active: true)') == 2, "Observe will-enter-foreground before MTProto changes"
for point in ("pollDifference_begin", "getDifference_rpc_subscribed", "getDifference_reply_",
              "getDifference_error_code_", "pollDifference_replay_result",
              "state_manager_updating_on", "state_manager_updating_off"):
    assert point in manager, point
assert 'let request = Signal<Api.updates.Difference, MTRpcError>' in manager
assert '|> retryRequest' in manager, "Do not alter stock retry policy"
assert 'GoldgramForegroundSyncTrace.poll(accountPeerId:' in manager
assert 'GoldgramForegroundSyncRow' in ui and 'Синхронизация №115/118:' in ui
assert 'GoldgramForegroundLastActivatedV1' in ui
assert 'Self.foregroundTracePrefix + String(account)' in ui
assert 'if (flags & 4) != 0' in ui and 'if (flags & 8) != 0' in ui
assert 'Сохрани' not in foreground, "Only UI should describe the test"
print("Goldgram #115: foreground MTProto/state/retry trace guarded, bounded, UI and stock updates intact")



# #117: a bounded, account-owned foreground watchdog is the only recovery
# controller. It must not alter Telegram's update manager, session keys,
# master lease or background expiration contract.
account = (root / "submodules/TelegramCore/Sources/Account/Account.swift").read_text()
net = (root / "submodules/TelegramCore/Sources/Network/Network.swift").read_text()
foreground = core.split("// #115: bounded, opt-in foreground sync trace.", 1)[1].split(
    "// #97:", 1)[0]
watchdog = account.split("private final class GoldgramForegroundConnectionRecovery", 1)[1].split(
    "public class Account {", 1)[0]
assert "GoldgramForegroundSyncTrace.foregroundActive" in account
assert "goldgramConnectionRecoveryDisposable.set(" in account
assert "goldgramConnectionRecoveryDisposable.dispose()" in account
assert "if !supplementary {" in account
assert 'ValuePromise<Bool>(false, ignoreRepeated: true)' in foreground
assert "foregroundSignal.set(active)" in foreground
assert "self.active, self.master, !self.managerUpdating" in watchdog
assert 'UserDefaults.standard.bool(forKey: "GoldgramForegroundActiveV1")' in watchdog
assert '(self.flags & 4) != 0' in watchdog
assert '(self.flags & 1) != 0' in watchdog
assert "self.schedule(after: 20.0)" in watchdog
assert "60.0 - elapsed" in watchdog and "150.0 - elapsed" in watchdog
assert "self.hardResetTimes.count < 2" in watchdog
assert "now - 900.0" in watchdog
assert "recovery_online_after_reset" in watchdog
assert "recovery_still_stalled_after_two_resets" in watchdog
assert "recovery_long_stall_retry" in watchdog
assert 'self.network.goldgramRequestTransportRecovery(resetTransport: false)' in watchdog
assert 'self.network.goldgramRequestTransportRecovery(resetTransport: true)' in watchdog
assert "self.mtProto.requestSecureTransportReset()" in net
assert "self.mtProto.requestTransportTransaction()" in net
for forbidden in ("resetSessionInfo", ".pause()", ".resume()", "shouldKeepConnection.set",
                  "requestApiInitialization", "ignoreDisabled: true"):
    assert forbidden not in watchdog, forbidden
print("Goldgram #117: foreground-only recovery, MTProto public reset, cooldown and cancellation OK")


# #118: verify the status heading is separately sampled, its age is visible,
# and safe UI repair cannot reset transport or rewrite the account mapper.
chatlist = (root / "submodules/ChatListUI/Sources/ChatListController.swift").read_text()
ui_snapshot = core.split("public struct GoldgramForegroundUISnapshot: Codable", 1)[1].split(
    "// #97:", 1)[0]
foreground_ui = chatlist.split("// #118: observe the authoritative Account", 1)[1].split(
    "private(set) var title: String", 1)[0]
assert 'GoldgramForegroundUISnapshotV1.' in ui_snapshot
for field in ("rawNetwork", "accountNetwork", "stateManagerUpdating", "mtprotoFlags",
              "titleInputNetwork", "titleActivity", "titleUpdating", "at"):
    assert "public let " + field + ":" in ui_snapshot, field
assert 'defaults.bool(forKey: "GoldgramDiagnosticEnabledV1")' in ui_snapshot
assert 'defaults.bool(forKey: "GoldgramForegroundActiveV1")' in ui_snapshot
assert 'GoldgramForegroundUISample: Decodable' in ui
assert 'Срез UI №118:' in ui and 'УСТАРЕЛ' in ui and 'age <= 25' in ui
assert 'Self.foregroundUISamplePrefix + String(account)' in ui
for gate in ('inputs.raw == "online"', 'accountName == "online"',
             '!inputs.updating', 'isUpdatingTitle',
             'now - self.goldgramLastHeaderRepairAt >= 120.0',
             'self.goldgramStableOnlineSince', 'self.goldgramRefreshOnlineTitle?'):
    assert gate in foreground_ui, gate
assert 'GoldgramForegroundSyncTrace.uiSample(' in foreground_ui
assert 'GoldgramForegroundSyncTrace.foregroundActive' in foreground_ui
assert 'self.goldgramStatusDisposable?.dispose()' in chatlist
assert 'self.goldgramStatusTimer?.invalidate()' in chatlist
assert 'self.goldgramWatchForegroundStatus()' in chatlist
assert 'self.goldgramTitleInput = networkState' in chatlist
assert 'ui_header_refresh_healthy_online' in foreground_ui
for forbidden in ('goldgramRequestTransportRecovery', 'requestSecureTransportReset',
                  'resetSessionInfo', '.pause()', '.resume()'):
    assert forbidden not in foreground_ui, forbidden
print("Goldgram #118: independent live UI sampling, 30s online-only title repair, 120s cooldown OK")


# #120: tooLong is a snapshot, not a replay of every earlier revision.
# Only a verified same-peer, unedited StoreMessage may enter the EXISTING
# baseline-only writer; already-edited snapshots must never become originals.
utils = (root / "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift").read_text()
too_long = utils.split("case let .channelDifferenceTooLong(channelDifferenceTooLongData):", 1)[1].split(
    "private func verifyTransaction(", 1)[0]
for expected in (
    "snapshotWithEditMarker", "snapshotWithoutEditMarker",
    "snapshotOriginalsQueued", "id.peerId == peer.id",
    "message.attributes.contains(where: { $0 is EditedMessageAttribute })",
    "goldgramVerifiedPublicKind(", "goldgramNativeHistoryEnabled()",
    "goldgramCaptureServerOriginal(", "GoldgramBackgroundRefreshTrace.tooLongSnapshot(",
    "messages: messages.count", "updatedState.addMessages([message], location: location)"
):
    assert expected in too_long, expected
assert too_long.index("goldgramCaptureServerOriginal(") < too_long.index(
    "updatedState.addMessages([message], location: location)"), "Capture before Postbox replay"
assert "snapshotWithEditMarker += 1" in too_long.split("else {", 1)[0] or (
    "snapshotWithEditMarker += 1" in too_long and "snapshotWithoutEditMarker += 1" in too_long
)
for field in ("tooLongSnapshotMessages", "tooLongWithEditMarker",
              "tooLongWithoutEditMarker", "tooLongOriginalsQueued"):
    assert f"public var {field}: Int?" in model, field
    assert f"self.{field} = nil" in model, field
    assert f"let {field}: Int?" in ui, field
assert "public static func tooLongSnapshot(" in trace
assert "row.originalsQueued += originalsQueued" in trace
assert "Снимок tooLong №120:" in ui and "уже изменённые снимки не считаем оригиналами" in ui
assert 'GoldgramBackgroundRefreshRunsV1' in trace
assert "return (trackedRequest" in utils and "|> retryRequest" in utils
# #121: Swift 6/Xcode 26.2 overload-resolution regression in #120's larger
# tooLong closure. Optional.init inferred a throwing Decodable initializer.
# Explicitly type the channel-difference map before the existing retryRequest.
assert ("|> map { (difference: Api.updates.ChannelDifference) -> Api.updates.ChannelDifference? in"
        in utils), "Keep the typed optional map needed by production Swift compiler"
assert "return (trackedRequest\n        |> map(Optional.init)" not in utils
print("Goldgram #120: tooLong same-peer original guard, bounded counters, old trace decode OK")
