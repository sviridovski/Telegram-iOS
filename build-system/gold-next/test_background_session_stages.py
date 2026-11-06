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
assert 'GoldgramBackgroundRefreshTrace.begin(' in bg
assert 'excludingActiveToken: self.goldgramRefreshActiveToken' in bg
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
assert 'self.goldgramRefreshLeaseToken != nil || self.goldgramLocationLeaseAccountId != nil || self.silenceAudioRenderer != nil' in wakeup
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
    "snapshotOriginalsQueued", "id.peerId == polledPeer.id",
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
# #122: #121 exposes the next Swift compile error: the tooLong dialog tuple
# shadows a Telegram Peer with Api.Peer. Ensure both uses of the target
# group remain bound to the original, typed Telegram Peer.
assert "let polledPeer = peer" in too_long
assert "id.peerId == polledPeer.id" in too_long
assert "peer: updatedState.peers[id.peerId] ?? polledPeer" in too_long
assert "id.peerId == peer.id" not in too_long
assert "peer: updatedState.peers[id.peerId] ?? peer" not in too_long

# #121: Swift 6/Xcode 26.2 overload-resolution regression in #120's larger
# tooLong closure. Optional.init inferred a throwing Decodable initializer.
# Explicitly type the channel-difference map before the existing retryRequest.
assert ("|> map { (difference: Api.updates.ChannelDifference) -> Api.updates.ChannelDifference? in"
        in utils), "Keep the typed optional map needed by production Swift compiler"
assert "return (trackedRequest\n        |> map(Optional.init)" not in utils
print("Goldgram #120: tooLong same-peer original guard, bounded counters, old trace decode OK")


# #123: content-free bounded BG diagnostics: historical Codable compatibility,
# no late MTProto state attributed to an iOS BG task, and record freeze before
# lease cleanup. Tests are structural; production Swift compiler validates types.
for field, type_name in (("leaseReleasedAt", "Double"),
                         ("reconciledAt", "Double"),
                         ("lateEventsIgnored", "Int")):
    assert f"public var {field}: {type_name}?" in model
    assert f"self.{field} = nil" in model
    assert f"let {field}: {type_name}?" in ui
assert 'GoldgramBackgroundRefreshRunsV1' in trace
assert "func begin(excludingActiveToken: String? = nil)" in trace
assert 'rows[index].outcome = "completion_unobserved"' in trace
assert "rows[index].token != excludingActiveToken" in trace
assert "rows[index].reconciledAt = now" in trace
assert 'row.endedAt = Date().timeIntervalSince1970' not in trace
assert 'rows[index].endedAt = Date().timeIntervalSince1970' in trace
assert "Date().timeIntervalSince1970 - rows[index].startedAt > traceWindow" in trace
assert "rows[index].lateEventsIgnored = min(32," in trace
assert "private static let traceWindow: Double = 24.0" in trace
assert "public static func leaseReleased(_ token: String)" in trace
assert "rows[index].leaseReleasedAt = Date().timeIntervalSince1970" in trace

assert "excludingActiveToken: self.goldgramRefreshActiveToken" in bg
finish_block = bg.split("let complete: (String, Bool) -> Void", 1)[1].split(
    "self.goldgramRefreshFinish = complete", 1)[0]
assert finish_block.index("self.goldgramRefreshWork.set(nil)") < finish_block.index(
    "GoldgramBackgroundRefreshTrace.finish(token, reason: reason)") < finish_block.index(
    "self.goldgramRefreshLease?.dispose()"), "Snapshot must precede lease release"
assert "GoldgramBackgroundRefreshTrace.leaseReleased(token)" in finish_block
assert 'GoldgramBackgroundRefreshTrace.finish(token, reason: reason)' in finish_block
assert 'GoldgramBackgroundRefreshTrace.phase(token, "wakeup_lease_active")' in bg
assert 'DispatchQueue.main.asyncAfter(deadline: .now() + 24.0)' in bg
assert 'нет подтверждения завершения предыдущего запуска' in ui
assert 'Режим сервиса ДО освобождения:' in ui
assert 'Поздних событий отброшено №123:' in ui
assert 'ВНЕ окна 24с, ненадёжно' in ui
assert 'Фактическое окончание: не установлено' in ui
assert 'Завершение записано:' in ui
print("Goldgram #123: freeze-before-release, stale reconciliation, bounded trace, UI clarity OK")


# #126: diagnose the boundary between request signal, MTRequest service,
# raw MTProto connection and server acknowledgement. Do not imply socket send.
for field, type_name in (("transportFlags", "Int32"),
                         ("firstTransportConnectedAt", "Double"),
                         ("rpcServiceAddedAt", "Double"),
                         ("rpcAcknowledgedAt", "Double"),
                         ("rpcServiceRemovedAt", "Double")):
    assert f"public var {field}: {type_name}?" in model
    assert f"self.{field} = nil" in model
    assert f"let {field}: {type_name}?" in ui
assert "public static func transportFlags(" in trace
assert "public static func rpcTransport(" in trace
assert 'Date().timeIntervalSince1970 - rows[index].startedAt > traceWindow' in trace
assert 'rows.suffix(8)' in trace
assert 'account.network.mtprotoDiagnosticFlags.start(next:' in observer
assert 'GoldgramBackgroundRefreshTrace.transportFlags(diagnosticToken, flags: flags)' in observer
assert 'shouldKeepConnection.set' not in observer
request_method = net.split("public func request<T>(", 1)[1].split(
    "func updateNetworkSpeedLimitedEventNotifyInterval", 1)[0]
assert 'diagnosticTransportEvent: ((String) -> Void)? = nil' in request_method
assert 'request.acknowledgementReceived = {' in request_method
assert 'diagnosticTransportEvent("acknowledged")' in request_method
assert request_method.index('requestService.add(request)') < request_method.index(
    'diagnosticTransportEvent?("service_added")')
assert 'diagnosticTransportEvent?("removed")' in request_method
# #129: transport events are dispatched to the active scoped trace:
# regular BGAppRefresh OR the CoreLocation experiment, never a fake send.
assert 'diagnosticTransportEvent: transportEvent' in poll
assert 'GoldgramBackgroundRefreshTrace.rpcTransport(diagnosticToken, event: event)' in poll
assert 'GoldgramLocationLabTrace.transport(locationTraceToken, event: event)' in poll
assert 'transportEvent = nil' in poll
for label in ("Транспорт №126:", "MTProto Connected впервые:",
              "Запрос принят MTRequestMessageService:", "MTProto ACK запроса:"):
    assert label in ui
assert "не подтверждение отправки" in ui and "не подтверждение ответа API" in ui
assert 'DispatchQueue.main.asyncAfter(deadline: .now() + 24.0)' in app
assert 'self.network.goldgramRequestTransportRecovery(' not in observer
print("Goldgram #126: transport evidence scoped, optional, 24s, no reconnect or SQL changes")


# #127: separate OFF-by-default laboratory mode; no rewrite of existing
# Telegram update/PTS/replay or original-capture provenance.
for field in ("labHistoryStarted", "labHistoryCompleted"):
    assert f"public var {field}: Int?" in model
    assert f"self.{field} = nil" in model
    assert f"let {field}: Int?" in ui
assert 'public func goldgramFullCaptureLabEnabled(accountPeerId: PeerId) -> Bool' in core
assert 'GoldgramFullCaptureLabV1.' in core and 'GoldgramFullCaptureLabV1.' in ui
seed = core.split("private func goldgramSeedDiscussion(", 1)[1].split(
    "private final class GoldgramDiscussionMonitor", 1)[0]
assert 'labOnly: Bool = false' in seed
assert 'if labOnly {' in seed and 'goldgramCaptureServerOriginal(' in seed
assert 'id.peerId == peerId' in seed
assert 'let _ = transaction.addMessages(stored, location: .Random)' in seed
assert 'EditedMessageAttribute' in core
monitor = core.split("private final class GoldgramDiscussionMonitor", 1)[1].split("// #114:", 1)[0]
assert 'delay(10.0, queue: queue)' in monitor
assert 'GoldgramForegroundActiveV1' in monitor
assert 'self.labSeedWork.set(requests)' in monitor
assert 'self.labPulse.dispose()' in monitor and 'self.labSeedWork.dispose()' in monitor
refresh_lab = core.split("public func goldgramRefreshPriorityDiscussions(", 1)[1].split("// The UI owns", 1)[0]
assert 'Array(selected.peers.prefix(6)) : Array(selected.peers.prefix(3))' in refresh_lab
assert 'if goldgramFullCaptureLabEnabled(accountPeerId: account.peerId), !ids.isEmpty' in refresh_lab
assert 'combineLatest(differences + history) |> ignoreValues' in refresh_lab
assert 'ids.prefix(3).map' in refresh_lab
assert 'return ids.reduce(Signal<Never, NoError>.complete())' in refresh_lab
assert 'GoldgramBackgroundRefreshTrace.labHistory(diagnosticToken, finished: true)' in refresh_lab
assert 'labOnly: true' in refresh_lab
assert 'Включить Full Capture Lab №127' in ui and 'Выключить Full Capture Lab №127' in ui
assert 'Full Capture Lab №127: запросов свежей истории' in ui
assert 'DispatchQueue.main.asyncAfter(deadline: .now() + 24.0)' in app
assert 'requestSecureTransportReset()' not in refresh_lab
assert 'CLLocationManager' not in refresh_lab and 'AVAudioSession' not in refresh_lab
print("Goldgram #127: reversible lab, bounded foreground bursts, concurrent BG, safe original provenance OK")


# #128 consented location activity, network lease, actual BG-only work.
for phrase in ("import CoreLocation", "class GoldgramBackgroundLocationLab:",
               "CLLocationManagerDelegate", "startUpdatingLocation()",
               "stopUpdatingLocation()", "allowsBackgroundLocationUpdates = true",
               "allowsBackgroundLocationUpdates = false", "showsBackgroundLocationIndicator = true",
               "GoldgramLocationLabUntilV1", "didUpdateLocations locations: [CLLocation]",
               "GoldgramLocationLabChanged", "goldgramLocationLabPoll(account: account, traceToken: token)",
               "self.goldgramLocationWork.set(nil)",
               "Date().timeIntervalSince(self.goldgramLocationLastPoll) >= 20.0",
               "deadline: .now() + 18.0"):
    assert phrase in app, phrase
location_class = app.split("private final class GoldgramBackgroundLocationLab:",1)[1].split(
    "@objc(AppDelegate) class AppDelegate",1)[0]
assert ".coordinate" not in location_class
assert "locations[0]" not in location_class
poll_location = core.split("public func goldgramLocationLabPoll(account: Account, traceToken: String)",1)[1].split(
    "// The UI owns this subscription",1)[0]
for phrase in ("goldgramGeoRotatingTargets(transaction:", "standalonePollChannelOnce(",
               "labOnly: true", "combineLatest(polls + snapshots) |> ignoreValues"):
    assert phrase in poll_location, phrase
assert "Гео-эксперимент №128: до отключения" in ui
assert "Остановить гео-эксперимент №128" in ui
assert "Гео-эксперимент №128 (координаты не записываются)" in ui
assert 'DispatchQueue.main.asyncAfter(deadline: .now() + 24.0)' in app
print("Goldgram #128: explicit, bounded background CoreLocation and real capture path OK")


# #129 cross-process-free local telemetry; different execution sources,
# real API response and a read-only SQLite timestamp window.
sql = (root / "build-system/gold-next/GoldgramHistoryStore.swift").read_text()
location = core.split("public struct GoldgramLocationLabAttempt: Codable",1)[1].split(
    "// #115: bounded, opt-in foreground sync trace.",1)[0]
for marker in ("source: String", "appState: String", "finalReason: String?",
               "rpcStarted: Int", "rpcAcknowledged: Int", "apiDifference: Int",
               "newMessages: Int", "edits: Int", "originalsQueued: Int",
               "historyQueued: Int", "lateCallbacksIgnored: Int"):
    assert marker in location, marker
for forbidden in ("message.text", "messageId", "senderId", "peerId",
                  ".coordinate", "CLLocation", "authKey", "accessHash"):
    assert forbidden not in location, "location lab should not collect sensitive content"
assert '"GoldgramLocationLabAttemptsV1"' in core
assert "rows.suffix(24)" in location
assert "Date().timeIntervalSince1970 - rows[index].at > window" in location
assert "public static func begin(source: String, appState: String)" in location
assert "GoldgramLocationLabTrace.begin(source: source, appState: appState)" in app
assert 'goldgramLocationPoll(source: "sensor")' in app
assert 'goldgramLocationPoll(source: "minimized")' in app
for reason in ("not_background", "session_expired", "os_refresh_active",
               "previous_poll_busy", "throttled_20s", "no_account",
               "capture_disabled", "poll_chain_completed", "own_18s_limit"):
    assert reason in app, reason
assert "self.goldgramLocationActiveToken == token" in app
assert 'GoldgramLocationLabTrace.finish(token, reason: "foreground_return")' in app
assert "locationTraceToken: traceToken" in poll_location
assert "locationTraceToken: traceToken" in core
assert "locationTraceToken: String? = nil" in core
assert "GoldgramLocationLabTrace.historyResponse(locationTraceToken," in core
assert "GoldgramLocationLabTrace.historyQueued(locationTraceToken," in core
assert "GoldgramLocationLabReportRow: Decodable" in ui
assert "SQLite за окно гео-сессии №129" in ui
assert "Отдельный журнал фоновых попыток №129" in ui
assert "GoldgramLocationLabStartedAtV1" in ui
assert "GoldgramLocationLabWindowEndV1" in ui
assert "geoSince" in ui and "geoUntil" in ui
assert "geoSince" in sql and "geoUntil" in sql
assert "sqlite3_bind_int64(stmt, 2, until)" in sql
assert 'result["geoKnown"] = window["known"]' in sql
assert "first_seen_at >= ? AND m.first_seen_at < ?" in sql
assert "DELETE FROM messages" not in sql.split('if mode == "diagnostics" {', 1)[1].split(
    'var sql = mode == "totals"', 1)[0]
assert 'goldgramLocationLabPoll(account: account, traceToken: token)' in app
print("Goldgram #129: source-labelled geo attempts, bounded SQLite interval, prior capture intact OK")


# #131: provenance and first-observed-edit evidence; no fake original,
# no new SQLite database, no stale geo interval in a separate control test.
for q in ('evidenceSource: String = "native_unclassified"',
          'payload["evidenceAttempt"] = evidenceAttempt',
          '"evidenceSource": "notification_postbox"',
          'GoldgramLocationLabTrace.evidenceSource(for: $0)',
          'evidenceAttempt: locationTraceToken'):
    assert q in core, q
for q in ('evidenceSource: "live_update"',
          '"os_bg_refresh" : "channel_difference"',
          'evidenceAttempt: locationTraceToken'):
    assert q in utils, q
assert 'let geoInThisTest = geoStarted > 0 && geoEnd > geoStarted' in ui
assert 'geoStarted >= diagnosticSinceSeconds' in ui
assert 'geoInThisTest ? Int64(geoQuerySince * 1000.0) : 0' in ui
assert 'removeObject(forKey: "GoldgramLocationLabStartedAtV1")' in ui
assert 'removeObject(forKey: "GoldgramLocationLabWindowEndV1")' in ui
assert 'Доказательства записи оригиналов №131' in ui
assert 'Аудит COMMIT за это гео-окно №131' in ui
assert 'ПЕРВОЙ зарегистрированной редакции' in ui
assert 'beforeObservedEdit' in sql
assert 'edit_already_observed' in sql
assert 'original_capture_evidence' in sql
assert 'evidence(since: diagnosticSince, until: Int64.max)' in sql
assert 'evidence(since: geoSince, until: geoUntil)' in sql
assert 'PRAGMA user_version = 2' in sql
print('Goldgram #131: privacy-safe original evidence, edit timing and no stale geo window OK')


# #133: no background bypass; account-scoped audit at actual SQLite COMMIT,
# edited-record joins and count reconciliation for source-specific history.
for needle in ('historySkippedEdited: Int?', 'historySkippedEmpty: Int?',
               'historyWrongPeer: Int?', 'historyNotConverted: Int?',
               'historyWriterRejected: Int?', 'func historyFilters(',
               'skippedEdited += 1', 'skippedEmpty += 1',
               'wrongPeer += 1', 'writerRejected += 1',
               'messages.count - stored.count'):
    assert needle in core, needle
for needle in ('let token: String', '"attemptTokens": traceRows.map { $0.token }',
               'Доказательства записи оригиналов №131',
               'Жизненный цикл SQLite COMMIT №133',
               'Редакции + конкретные оригиналы №133',
               'SQLite для ЭТОЙ попытки №133',
               'historySkippedEdited', 'historyWriterRejected',
               'newCommitted', 'alreadyKnown', 'не подтверждено'):
    assert needle in ui, needle
for needle in ('ensureOriginalEvidenceColumns(on: db)', 'GoldgramForegroundActiveV1',
               'committed_at INTEGER', 'enqueue_state TEXT', 'commit_state TEXT',
               'CREATE TABLE IF NOT EXISTS original_capture_attempts',
               'INSERT INTO original_capture_attempts',
               'UPDATE SET' if False else 'ON CONFLICT(attempt_token) DO UPDATE SET',
               'let enqueueState = lifecycleState()',
               'commitState: lifecycleState()',
               'let commitsSQL = """', 'WHERE committed_at >= ? AND committed_at < ?',
               'let editedSQL = """', 'LEFT JOIN original_capture_evidence a USING',
               'FROM recent r', 'let attemptsSQL = """',
               'result["attemptOutcomes"] = attempts',
               'result["geoCommitStates"] = states',
               'result["geoEditedEvidence"] = joined'):
    assert needle in sql, needle
assert 'CREATE TABLE IF NOT EXISTS original_capture_attempts' in sql
assert 'GoldgramForegroundSyncTrace.lifecycle(active: false)' in app
assert app.count('GoldgramForegroundSyncTrace.lifecycle(active: true)') == 2
assert 'self.goldgramLocationActiveToken == token' in app
assert 'UPDATE messages SET original_observed=1' in sql
assert 'DELETE FROM original_capture_evidence' not in sql
assert 'ALTER TABLE original_capture_evidence ADD COLUMN' in sql
print('Goldgram #133: lifecycle commit, per-edit source, queued/duplicate/failed reconciliation OK')


# #135: more effective REAL background wake, no fake location / keepalive.
# One pinned verified peer plus a round-robin over already-seen accessible
# dialogs, same 18s abort and consent. No private chat in channelDifference.
geo_helper = core.split('private func goldgramGeoRotatingTargets(',1)[1].split(
    'public func goldgramLocationLabPoll(',1)[0]
for needle in ('goldgramPriorityPeers(transaction:', 'goldgramDiscussionTargetsKey',
               'now - item.seen < 86400', 'goldgramKind(id, peer) != nil',
               'apiInputPeer(peer) != nil', 'GoldgramGeoRotationV135.',
               'accountPeerId.id._internalGetInt64Value()', 'rotated.prefix(slots)',
               'min(slots, extras.count)'):
    assert needle in geo_helper, needle
assert 'let fixed = Array(eligible.prefix(1))' in geo_helper
assert 'let channelIds = ids.filter { $0.namespace == Namespaces.Peer.CloudChannel }' in poll_location
assert 'ids.prefix(4).map' in poll_location
assert 'channelIds.map' in poll_location
assert 'self.goldgramLocationActiveToken == token' in app
assert 'deadline: .now() + 18.0' in app
for forbidden in ('requestLocation(', 'CLLocationManager', 'coordinates', 'readCoordinate',
                  'while true', 'shouldKeepConnection.set'):
    assert forbidden not in geo_helper
# Diagnoses missing baselines without inventing unobserved original or
# server time; windowed real COMMIT buckets are provenance-only.
for needle in ('missingFirstSeenAtEdit', 'missingSeenEarlier',
               'missingSeenLater', 'beforeOtherSource', 'let geoBucketsSQL = """',
               'result["geoBuckets"] = buckets', 'GROUP BY 1 ORDER BY 1 LIMIT 6'):
    assert needle in sql, needle
for needle in ('ПОЧЕМУ оригинала нет', 'Впервые увидено',
               'Фактические COMMIT по пятиминуткам',
               'целей на эту попытку'):
    assert needle.lower() in ui.lower(), needle
assert 'let geoInThisTest = geoStarted > 0 && geoEnd > geoStarted' in ui
assert 'GoldgramLocationLabUntilV1' in app
print('Goldgram #135: rotating real limited geo capture and missing-original diagnostics OK')

#136: priority and durable fence, committed-only geo filtering, no invented original.
assert 'qos: .userInitiated' in sql
assert '@_cdecl("goldgram_has_original_v1")' in sql
assert 'try? GoldgramHistoryStore.originalIsKnown(' in sql
assert 'return known ? 1 : 0' in sql
assert 'goldgramHasOriginalCallback' in core
assert 'goldgramHasCommittedOriginal(accountPeerId: account.peerId,' in core
assert 'historySkippedKnown: Int?' in core
assert 'writerFlushConfirmed: Bool?' in core
assert 'known: skippedKnown' in core
assert core.index('goldgramHasCommittedOriginal(accountPeerId: account.peerId,') < core.index('if goldgramCaptureServerOriginal(', core.index('var skippedKnown = 0'))
assert 'goldgramFlushOriginalCapture()' in app
assert 'GoldgramLocationLabTrace.writerFlush(token,' in app
assert 'self.goldgramRefreshWork.set(nil)' in app and 'GoldgramBackgroundRefreshTrace.finish(token, reason: reason)' in app
assert 'already in SQLite' not in ui or 'уже в SQLite (без повторного writer)' in ui
assert 'historySkippedKnown: Int?' in ui and 'writerFlushConfirmed: Bool?' in ui
assert 'evidenceSource: "live_update"' in utils
assert 'deadline: .now() + 18.0' in app
assert 'GoldgramLocationLabUntilV1' in app
print('Goldgram #136: priority live durable writes + read-only committed filter + bounded wake fence OK')

#137: explicit persistent manual geo mode with a legacy-deadline fallback.
assert 'return until == -1.0 || until > Date().timeIntervalSince1970' in app
assert 'return until == -1.0 || until > Date().timeIntervalSince1970' in ui
assert 'defaults.set(locationActive ? 0.0 : -1.0,' in ui
assert '"Гео-эксперимент №128: до отключения"' in ui
assert 'geoRunning ? Date().timeIntervalSince1970' in ui
assert 'geoQuerySince = max(geoStarted, diagnosticSinceSeconds)' in ui
assert 'if geoRunning {' in ui and 'включена до ручного отключения' in ui
assert 'if goldgramLocationLabIsActive(UserDefaults.standard) {' in app
assert 'self.goldgramLocationLabChanged(Notification(name: Notification.Name("GoldgramLocationLabChanged")))' in app
assert 'deadline: .now() + 1800.0' not in app
assert 'now + 1800.0' not in ui
assert 'deadline: .now() + 18.0' in app
assert 'allowsBackgroundLocationUpdates = false' in app
assert 'stopUpdatingLocation()' in app
print('Goldgram #137: persistent manual geo experiment, bounded per-wake work and accurate live reporting OK')

#138: hide only edit-only rows missing a verified original, before pagination.
# Folder counts, message pages and visible totals must agree; deletion records
# with known content remain available. SQLite rows must never be removed.
import re
import sqlite3

def archive_sql_literal(name):
    m = re.search(r'private static let ' + name + r' = """\n(.*?)\n    """', sql, re.S)
    assert m is not None, name
    return m.group(1)

archive_dialogs = archive_sql_literal("dialogsSQL")
archive_messages = archive_sql_literal("messagesSQL")
visibility = "m.original_observed = 1"
assert archive_dialogs.count(visibility) >= 2
assert archive_messages.count(visibility) >= 2
assert "de.event_kind=2" in archive_dialogs and "de.event_kind=2" in archive_messages
assert "DELETE FROM messages" not in archive_dialogs + archive_messages
assert "UPDATE messages" not in archive_dialogs + archive_messages
assert 'if mode == "diagnostics" {' in sql

db = sqlite3.connect(":memory:")
db.executescript("""
CREATE TABLE dialogs (peer_kind INTEGER, peer_id INTEGER);
CREATE TABLE messages (
    peer_kind INTEGER, peer_id INTEGER, message_id INTEGER,
    original_text TEXT, original_observed INTEGER, capture_provenance INTEGER,
    sender_id INTEGER, sent_at INTEGER, last_seen_at INTEGER,
    is_deleted INTEGER, sender_kind INTEGER
);
CREATE TABLE revisions (
    peer_kind INTEGER, peer_id INTEGER, message_id INTEGER,
    version_index INTEGER, content TEXT
);
CREATE TABLE events (
    peer_kind INTEGER, peer_id INTEGER, message_id INTEGER,
    event_kind INTEGER, source TEXT, server_time INTEGER, observed_at INTEGER
);
""")
db.executemany("INSERT INTO dialogs VALUES (?,?)", [(2, 41), (2, 42)])
db.executemany("INSERT INTO messages VALUES (?,?,?,?,?,?,?,?,?,?,?)", [
    (2, 41, 1, None, 0, 0, None, 100, 100, 0, None),  # edited, no original: hide
    (2, 41, 2, "before", 1, 0, None, 200, 200, 0, None), # edited, original: show
    (2, 41, 3, None, 0, 0, None, 300, 300, 0, None), # deleted with known text: show
    (2, 41, 4, "[Содержимое не было получено]", 1, 0, None, 400, 400, 0, None),
    (2, 42, 5, None, 0, 0, None, 500, 500, 0, None), # peer with only missing original
    (2, 41, 6, "not edited", 1, 0, None, 600, 600, 0, None) # baseline only: hide
])
db.executemany("INSERT INTO revisions VALUES (?,?,?,?,?)", [
    (2, 41, 1, 0, "changed"), (2, 41, 2, 0, "changed"),
    (2, 41, 3, 0, "retained deletion text"),
    (2, 41, 4, 0, "changed"), (2, 42, 5, 0, "changed")
])
db.executemany("INSERT INTO events VALUES (?,?,?,?,?,?,?)", [
    (2, 41, 1, 1, "goldgram_native_live_v2", 0, 110),
    (2, 41, 2, 1, "goldgram_native_live_v2", 0, 210),
    (2, 41, 3, 2, "deleted", 0, 310),
    (2, 41, 4, 1, "goldgram_native_live_v2", 0, 410),
    (2, 42, 5, 1, "goldgram_native_live_v2", 0, 510)
])

folders = db.execute(archive_dialogs, (2, 3, 30, 0)).fetchall()
assert [(row[1], row[2]) for row in folders] == [(41, 2)], folders
rows = db.execute(archive_messages, (2, 41, 30, 0)).fetchall()
assert [row[2] for row in rows] == [3, 2], rows
assert db.execute(archive_messages, (2, 41, 1, 0)).fetchone()[2] == 3
assert db.execute(archive_messages, (2, 41, 1, 1)).fetchone()[2] == 2
assert db.execute(archive_messages, (2, 41, 1, 2)).fetchone() is None
assert db.execute(archive_messages, (2, 42, 30, 0)).fetchall() == []
# The Swift countsSQL uses the same WHERE as messagesSQL.
count_rows = archive_messages.split(
    "ORDER BY COALESCE(m.sent_at, m.last_seen_at) DESC", 1
)[0].replace("WHERE m.peer_kind = ? AND m.peer_id = ?",
            "WHERE m.peer_kind IN (0,1,2,3)")
counts_sql = ("SELECT COALESCE(SUM(edited),0), "
              "COALESCE(SUM(CASE WHEN is_deleted=1 OR delete_event=1 "
              "THEN 1 ELSE 0 END),0) FROM (" + count_rows + ");")
assert db.execute(counts_sql).fetchone() == (1, 1)
assert db.execute("SELECT COUNT(*) FROM messages").fetchone()[0] == 6
db.close()
print("Goldgram #138: hide missing originals in journal, preserve deletions, pagination and archive data OK")
