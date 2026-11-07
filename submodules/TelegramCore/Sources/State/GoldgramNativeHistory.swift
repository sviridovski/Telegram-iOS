import Foundation
import Darwin
import Postbox
import SwiftSignalKit
import TelegramApi

// #108: bounded diagnostic evidence for system-granted refresh runs.
// No message text, sender, peer IDs or Telegram session contents are stored.
// One record per OS launch, up to 8 runs; counters may include retries.
public struct GoldgramBackgroundRefreshRun: Codable {
    public let token: String
    public let startedAt: Double
    public var endedAt: Double?
    public var accountId: Int64?
    public var outcome: String
    public var targets: Int
    public var requests: Int
    public var completed: Int
    public var difference: Int
    public var empty: Int
    public var tooLong: Int
    public var unavailable: Int
    public var returnedNew: Int
    public var returnedEdits: Int
    public var originalsQueued: Int
    // #120: typed tooLong snapshot evidence, optional for every old stored run.
    // Counters only. A missing edit marker is not independent proof of provenance.
    public var tooLongSnapshotMessages: Int?
    public var tooLongWithEditMarker: Int?
    public var tooLongWithoutEditMarker: Int?
    public var tooLongOriginalsQueued: Int?
    // Optional to decode #108/#109 persisted runs without dropping history.
    public var phase: String?
    public var phaseAt: Double?
    public var storedPinned: Int?
    public var rejectedPeer: Int?
    public var rejectedLink: Int?
    public var rejectedGroup: Int?
    public var rejectedAccess: Int?
    // #113: Optional, content-free per-request telemetry (old rows decode unchanged).
    public var networkStatus: String?
    public var networkTransitions: Int?
    public var firstOnlineAt: Double?
    public var rpcAttempts: Int?
    public var rpcErrors: Int?
    public var lastRpcError: String?
    public var rpcResponseAt: Double?
    public var rpcFinal: Bool?
    public var rpcPts: Int32?
    public var rpcTimeout: Int32?
    // #114: Read-only timestamps and states of the effective BG network gates.
    // All fields are Optional so earlier sessions continue to decode.
    public var leaseActivatedAt: Double?
    public var serviceMasterMode: String?
    public var serviceMasterAt: Double?
    public var serviceMasterTransitions: Int?
    public var postboxMaster: Bool?
    public var postboxMasterAt: Double?
    public var postboxMasterTransitions: Int?
    public var networkAllowed: Bool?
    public var networkAllowedAt: Double?
    public var networkAllowedTransitions: Int?
    public var firstConnectingAt: Double?
    public var rpcEnqueuedAt: Double?
    public var rpcBudgetRemaining: Double?
    // #123: content-free lifecycle evidence. Optional for historic records.
    // recorded completion/reconciliation is NOT CPU time granted by iOS.
    public var leaseReleasedAt: Double?
    public var reconciledAt: Double?
    public var lateEventsIgnored: Int?
    // #127 optional experimental snapshot counters, not confirmed originals.
    public var labHistoryStarted: Int?
    public var labHistoryCompleted: Int?
    // #126: read-only MTProto transport and request-service evidence.
    // No packet transmission is inferred from requestService.add().
    public var transportFlags: Int32?
    public var firstTransportConnectedAt: Double?
    public var rpcServiceAddedAt: Double?
    public var rpcAcknowledgedAt: Double?
    public var rpcServiceRemovedAt: Double?

    public init(token: String) {
        self.token = token
        self.startedAt = Date().timeIntervalSince1970
        self.endedAt = nil
        self.accountId = nil
        self.outcome = "running"
        self.targets = 0
        self.requests = 0
        self.completed = 0
        self.difference = 0
        self.empty = 0
        self.tooLong = 0
        self.unavailable = 0
        self.returnedNew = 0
        self.returnedEdits = 0
        self.originalsQueued = 0
        self.tooLongSnapshotMessages = nil
        self.tooLongWithEditMarker = nil
        self.tooLongWithoutEditMarker = nil
        self.tooLongOriginalsQueued = nil
        self.phase = "task_invoked"
        self.phaseAt = self.startedAt
        self.storedPinned = nil
        self.rejectedPeer = nil
        self.rejectedLink = nil
        self.rejectedGroup = nil
        self.rejectedAccess = nil
        self.networkStatus = nil
        self.networkTransitions = nil
        self.firstOnlineAt = nil
        self.rpcAttempts = nil
        self.rpcErrors = nil
        self.lastRpcError = nil
        self.rpcResponseAt = nil
        self.rpcFinal = nil
        self.rpcPts = nil
        self.rpcTimeout = nil
        self.leaseActivatedAt = nil
        self.serviceMasterMode = nil
        self.serviceMasterAt = nil
        self.serviceMasterTransitions = nil
        self.postboxMaster = nil
        self.postboxMasterAt = nil
        self.postboxMasterTransitions = nil
        self.networkAllowed = nil
        self.networkAllowedAt = nil
        self.networkAllowedTransitions = nil
        self.firstConnectingAt = nil
        self.rpcEnqueuedAt = nil
        self.rpcBudgetRemaining = nil
        self.leaseReleasedAt = nil
        self.reconciledAt = nil
        self.lateEventsIgnored = nil
        self.labHistoryStarted = nil
        self.labHistoryCompleted = nil
        self.transportFlags = nil
        self.firstTransportConnectedAt = nil
        self.rpcServiceAddedAt = nil
        self.rpcAcknowledgedAt = nil
        self.rpcServiceRemovedAt = nil
    }
}

public enum GoldgramBackgroundRefreshTrace {
    private static let lock = NSLock()
    private static let storage = "GoldgramBackgroundRefreshRunsV1"
    // The app schedules its own 24s completion timer. A callback delivered
    // after this wall-clock budget does not establish continued BG execution.
    private static let traceWindow: Double = 24.0

    private static func read() -> [GoldgramBackgroundRefreshRun] {
        guard let data = UserDefaults.standard.data(forKey: storage),
              let rows = try? PropertyListDecoder().decode([GoldgramBackgroundRefreshRun].self, from: data) else {
            return []
        }
        return rows
    }

    private static func write(_ rows: [GoldgramBackgroundRefreshRun]) {
        if let data = try? PropertyListEncoder().encode(Array(rows.suffix(8))) {
            UserDefaults.standard.set(data, forKey: storage)
        }
    }

    public static func begin(excludingActiveToken: String? = nil) -> String {
        let token = UUID().uuidString
        lock.lock()
        defer { lock.unlock() }
        var rows = read()
        let now = Date().timeIntervalSince1970
        // On the next system launch, reconcile entries left "running" by
        // iOS suspension/termination. Do not fabricate an actual end time.
        // Never close the one task still owned by this AppDelegate instance.
        for index in rows.indices {
            if rows[index].outcome == "running",
               rows[index].token != excludingActiveToken,
               now - rows[index].startedAt > 60.0 {
                rows[index].outcome = "completion_unobserved"
                rows[index].reconciledAt = now
            }
        }
        rows.append(GoldgramBackgroundRefreshRun(token: token))
        write(rows)
        return token
    }

    private static func change(_ token: String, _ body: (inout GoldgramBackgroundRefreshRun) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var rows = read()
        guard let index = rows.firstIndex(where: { $0.token == token }),
              rows[index].outcome == "running" else { return }
        // A suspended process may deliver pending callbacks many minutes
        // later. Preserve the within-window evidence rather than recording
        // those callbacks as BG MTProto activity.
        if Date().timeIntervalSince1970 - rows[index].startedAt > traceWindow {
            rows[index].lateEventsIgnored = min(32, (rows[index].lateEventsIgnored ?? 0) + 1)
            write(rows)
            return
        }
        body(&rows[index])
        write(rows)
    }

    public static func phase(_ token: String, _ phase: String, accountId: Int64? = nil) {
        change(token) { row in
            row.phase = phase
            row.phaseAt = Date().timeIntervalSince1970
            if let accountId { row.accountId = accountId }
        }
    }

    public static func selection(_ token: String, stored: Int,
        rejectedPeer: Int, rejectedLink: Int, rejectedGroup: Int, rejectedAccess: Int) {
        change(token) { row in
            row.storedPinned = stored
            row.rejectedPeer = rejectedPeer
            row.rejectedLink = rejectedLink
            row.rejectedGroup = rejectedGroup
            row.rejectedAccess = rejectedAccess
            row.phase = "postbox_checked"
            row.phaseAt = Date().timeIntervalSince1970
        }
    }

    public static func targets(_ token: String, accountId: Int64, count: Int) {
        change(token) { row in
            row.accountId = accountId
            row.targets = count
        }
    }

    // This records the manager's lease acquisition call, not MTProto readiness.
    public static func leaseActivated(_ token: String) {
        change(token) { row in
            if row.leaseActivatedAt == nil {
                row.leaseActivatedAt = Date().timeIntervalSince1970
            }
        }
    }

    public static func serviceMaster(_ token: String, mode: String) {
        change(token) { row in
            guard row.serviceMasterMode != mode else { return }
            row.serviceMasterMode = mode
            row.serviceMasterTransitions = (row.serviceMasterTransitions ?? 0) + 1
            if (mode == "always" || mode == "now") && row.serviceMasterAt == nil {
                row.serviceMasterAt = Date().timeIntervalSince1970
            }
        }
    }

    public static func postboxMaster(_ token: String, value: Bool) {
        change(token) { row in
            guard row.postboxMaster != value else { return }
            row.postboxMaster = value
            row.postboxMasterTransitions = (row.postboxMasterTransitions ?? 0) + 1
            if value && row.postboxMasterAt == nil {
                row.postboxMasterAt = Date().timeIntervalSince1970
            }
        }
    }

    public static func networkPermission(_ token: String, value: Bool) {
        change(token) { row in
            guard row.networkAllowed != value else { return }
            row.networkAllowed = value
            row.networkAllowedTransitions = (row.networkAllowedTransitions ?? 0) + 1
            if value && row.networkAllowedAt == nil {
                row.networkAllowedAt = Date().timeIntervalSince1970
            }
        }
    }

    public static func request(_ token: String) {
        change(token) { row in
            row.requests += 1
            row.phase = "telegram_requested"
            row.phaseAt = Date().timeIntervalSince1970
        }
    }

    public static func networkStatus(_ token: String, status: String) {
        change(token) { row in
            guard row.networkStatus != status else { return }
            row.networkStatus = status
            row.networkTransitions = (row.networkTransitions ?? 0) + 1
            if status == "connecting" && row.firstConnectingAt == nil {
                row.firstConnectingAt = Date().timeIntervalSince1970
            }
            if status == "online" && row.firstOnlineAt == nil {
                row.firstOnlineAt = Date().timeIntervalSince1970
            }
        }
    }

    // Raw MTProto flags: bit 2 means connected. Neither this bit nor
    // request-service submission alone proves a channel RPC was sent.
    public static func transportFlags(_ token: String, flags: Int32) {
        change(token) { row in
            row.transportFlags = flags
            if (flags & 2) != 0 && row.firstTransportConnectedAt == nil {
                row.firstTransportConnectedAt = Date().timeIntervalSince1970
            }
        }
    }

    // These callbacks are scoped to the one diagnostic getChannelDifference.
    // Server ACK indicates MTProto acknowledgement, not a parsed API answer.
    public static func rpcTransport(_ token: String, event: String) {
        change(token) { row in
            let now = Date().timeIntervalSince1970
            switch event {
            case "service_added":
                if row.rpcServiceAddedAt == nil { row.rpcServiceAddedAt = now }
            case "acknowledged":
                if row.rpcAcknowledgedAt == nil { row.rpcAcknowledgedAt = now }
            case "removed":
                if row.rpcServiceRemovedAt == nil { row.rpcServiceRemovedAt = now }
            default: break
            }
        }
    }

    public static func labHistory(_ token: String, finished: Bool) {
        change(token) { row in
            if finished {
                row.labHistoryCompleted = (row.labHistoryCompleted ?? 0) + 1
            } else {
                row.labHistoryStarted = (row.labHistoryStarted ?? 0) + 1
            }
        }
    }

    // Count subscriptions to Network.request, not packets sent over the wire.
    public static func rpcAttempt(_ token: String) {
        change(token) { row in
            row.rpcAttempts = (row.rpcAttempts ?? 0) + 1
            let now = Date().timeIntervalSince1970
            row.rpcEnqueuedAt = now
            // The app's own 24s timer, NOT a guarantee of iOS execution time.
            row.rpcBudgetRemaining = max(0, 24.0 - (now - row.startedAt))
            row.phase = "rpc_enqueued"
            row.phaseAt = Date().timeIntervalSince1970
        }
    }

    public static func rpcError(_ token: String, category: String) {
        change(token) { row in
            row.rpcErrors = (row.rpcErrors ?? 0) + 1
            row.lastRpcError = category
            row.phase = "rpc_error"
            row.phaseAt = Date().timeIntervalSince1970
        }
    }

    public static func rpcResponse(_ token: String, final: Bool?, pts: Int32?, timeout: Int32?) {
        change(token) { row in
            row.rpcResponseAt = Date().timeIntervalSince1970
            row.rpcFinal = final
            row.rpcPts = pts
            row.rpcTimeout = timeout
            row.phase = "rpc_response"
            row.phaseAt = row.rpcResponseAt
        }
    }

    public static func completedRequest(_ token: String) {
        change(token) { row in
            row.completed += 1
            row.phase = "replay_completed"
            row.phaseAt = Date().timeIntervalSince1970
        }
    }

    public static func response(_ token: String, kind: String, new: Int = 0, edits: Int = 0) {
        change(token) { row in
            switch kind {
            case "difference": row.difference += 1
            case "empty": row.empty += 1
            case "tooLong": row.tooLong += 1
            default: row.unavailable += 1
            }
            row.returnedNew += new
            row.returnedEdits += edits
            row.phase = "api_answered"
            row.phaseAt = Date().timeIntervalSince1970
        }
    }

    // #120: count snapshot contents and accepted baseline-only writes together.
    // A full tooLong snapshot is NOT a stream of unedited newMessages.
    public static func tooLongSnapshot(_ token: String, messages: Int,
                                       withEditMarker: Int, withoutEditMarker: Int,
                                       originalsQueued: Int) {
        change(token) { row in
            row.tooLongSnapshotMessages = (row.tooLongSnapshotMessages ?? 0) + messages
            row.tooLongWithEditMarker = (row.tooLongWithEditMarker ?? 0) + withEditMarker
            row.tooLongWithoutEditMarker = (row.tooLongWithoutEditMarker ?? 0) + withoutEditMarker
            row.tooLongOriginalsQueued = (row.tooLongOriginalsQueued ?? 0) + originalsQueued
            row.originalsQueued += originalsQueued
        }
    }

    public static func originalQueued(_ token: String) {
        change(token) { $0.originalsQueued += 1 }
    }

    public static func finish(_ token: String, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        var rows = read()
        guard let index = rows.firstIndex(where: { $0.token == token }),
              rows[index].outcome == "running" else { return }
        // Completion may be observed long after iOS suspended us; this is
        // only the callback recording time, not the real BG execution span.
        rows[index].endedAt = Date().timeIntervalSince1970
        rows[index].outcome = reason
        write(rows)
    }

    public static func leaseReleased(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        var rows = read()
        guard let index = rows.firstIndex(where: { $0.token == token }),
              rows[index].endedAt != nil,
              rows[index].leaseReleasedAt == nil else { return }
        rows[index].leaseReleasedAt = Date().timeIntervalSince1970
        write(rows)
    }

    public static func find(_ token: String) -> GoldgramBackgroundRefreshRun? {
        lock.lock()
        defer { lock.unlock() }
        return read().first(where: { $0.token == token })
    }

    public static func recent(forAccountId accountId: Int64) -> [GoldgramBackgroundRefreshRun] {
        lock.lock()
        defer { lock.unlock() }
        return Array(read().filter { $0.accountId == nil || $0.accountId == accountId }.suffix(4).reversed())
    }
}

// #129: proof-oriented telemetry ONLY for a user-initiated geo-lab session.
// Does not contain coordinates, peers, message bodies, authors, or credentials.
// Counts of writer acceptance are NOT proof of a durable SQLite flush.
public struct GoldgramLocationLabAttempt: Codable {
    public let token: String
    public let at: Double
    public let source: String
    public let appState: String
    public var decision: String
    public var stage: String
    public var finalReason: String?
    public var endedAt: Double?
    public var accountReady: Bool
    public var targets: Int
    public var rpcStarted: Int
    public var rpcCompleted: Int
    public var rpcServiceAdded: Int
    public var rpcAcknowledged: Int
    public var apiDifference: Int
    public var apiEmpty: Int
    public var apiTooLong: Int
    public var apiUnavailable: Int
    public var apiErrors: Int
    public var newMessages: Int
    public var edits: Int
    public var originalsQueued: Int
    public var historyStarted: Int
    public var historyResponses: Int
    public var historyMessages: Int
    public var historyFailed: Int
    public var historyQueued: Int
    // Optional for reading old #129/#132 property-list rows safely.
    public var historySkippedEdited: Int?
    public var historySkippedEmpty: Int?
    public var historyWrongPeer: Int?
    public var historyNotConverted: Int?
    public var historyWriterRejected: Int?
    public var historySkippedKnown: Int?
    public var writerFlushConfirmed: Bool?
    public var lateCallbacksIgnored: Int

    public init(token: String, source: String, appState: String) {
        self.token = token
        self.at = Date().timeIntervalSince1970
        self.source = source
        self.appState = appState
        self.decision = "pending"
        self.stage = "callback"
        self.finalReason = nil
        self.endedAt = nil
        self.accountReady = false
        self.targets = 0
        self.rpcStarted = 0
        self.rpcCompleted = 0
        self.rpcServiceAdded = 0
        self.rpcAcknowledged = 0
        self.apiDifference = 0
        self.apiEmpty = 0
        self.apiTooLong = 0
        self.apiUnavailable = 0
        self.apiErrors = 0
        self.newMessages = 0
        self.edits = 0
        self.originalsQueued = 0
        self.historyStarted = 0
        self.historyResponses = 0
        self.historyMessages = 0
        self.historyFailed = 0
        self.historyQueued = 0
        self.historySkippedEdited = 0
        self.historySkippedEmpty = 0
        self.historyWrongPeer = 0
        self.historyNotConverted = 0
        self.historyWriterRejected = 0
        self.historySkippedKnown = 0
        self.writerFlushConfirmed = nil
        self.lateCallbacksIgnored = 0
    }
}

public enum GoldgramLocationLabTrace {
    private static let lock = NSLock()
    private static let storage = "GoldgramLocationLabAttemptsV1"
    // Never credit callbacks delayed beyond our independent 18-second batch.
    private static let window: Double = 18.0

    private static func read() -> [GoldgramLocationLabAttempt] {
        guard let data = UserDefaults.standard.data(forKey: storage),
              let rows = try? PropertyListDecoder().decode([GoldgramLocationLabAttempt].self, from: data) else {
            return []
        }
        return rows
    }
    private static func write(_ rows: [GoldgramLocationLabAttempt]) {
        if let data = try? PropertyListEncoder().encode(Array(rows.suffix(24))) {
            UserDefaults.standard.set(data, forKey: storage)
        }
    }
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: storage)
    }
    public static func recent() -> [GoldgramLocationLabAttempt] {
        lock.lock()
        defer { lock.unlock() }
        return Array(read().suffix(12).reversed())
    }
    public static func begin(source: String, appState: String) -> String {
        let token = UUID().uuidString
        lock.lock()
        defer { lock.unlock() }
        var rows = read()
        rows.append(GoldgramLocationLabAttempt(token: token, source: source, appState: appState))
        write(rows)
        return token
    }
    // #131 source is derived from the actual accepted geo-lab attempt,
    // not inferred from a nearby timestamp or the iOS blue location icon.
    public static func evidenceSource(for token: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let row = read().first(where: { $0.token == token }) else { return "geo_unclassified" }
        switch row.source {
        case "sensor": return "geo_sensor"
        case "minimized": return "geo_minimized"
        default: return "geo_unclassified"
        }
    }
    private static func change(_ token: String, _ update: (inout GoldgramLocationLabAttempt) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var rows = read()
        guard let index = rows.firstIndex(where: { $0.token == token }),
              rows[index].finalReason == nil else { return }
        if Date().timeIntervalSince1970 - rows[index].at > window {
            rows[index].lateCallbacksIgnored = min(32, rows[index].lateCallbacksIgnored + 1)
            write(rows)
            return
        }
        update(&rows[index])
        write(rows)
    }
    public static func stage(_ token: String, _ value: String) {
        change(token) { $0.stage = value }
    }
    public static func accepted(_ token: String) {
        change(token) {
            $0.decision = "accepted"
            $0.stage = "await_context"
        }
    }
    public static func account(_ token: String) {
        change(token) {
            $0.accountReady = true
            $0.stage = "account_ready"
        }
    }
    public static func targets(_ token: String, count: Int) {
        change(token) {
            $0.targets = count
            $0.stage = "targets_checked"
        }
    }
    public static func rpcStart(_ token: String) {
        change(token) {
            $0.rpcStarted += 1
            $0.stage = "rpc_subscribed"
        }
    }
    public static func rpcComplete(_ token: String) {
        change(token) { $0.rpcCompleted += 1 }
    }
    public static func transport(_ token: String, event: String) {
        change(token) { row in
            switch event {
            case "service_added": row.rpcServiceAdded += 1
            case "acknowledged": row.rpcAcknowledged += 1
            default: break
            }
        }
    }
    public static func api(_ token: String, kind: String, new: Int = 0, edits: Int = 0) {
        change(token) { row in
            switch kind {
            case "difference": row.apiDifference += 1
            case "empty": row.apiEmpty += 1
            case "tooLong": row.apiTooLong += 1
            case "unavailable": row.apiUnavailable += 1
            case "error": row.apiErrors += 1
            default: break
            }
            row.newMessages += new
            row.edits += edits
            row.stage = "api_" + kind
        }
    }
    public static func originalQueued(_ token: String) {
        change(token) { $0.originalsQueued += 1 }
    }
    public static func historyStarted(_ token: String) {
        change(token) { $0.historyStarted += 1 }
    }
    public static func historyResponse(_ token: String, messages: Int) {
        change(token) {
            $0.historyResponses += 1
            $0.historyMessages += messages
        }
    }
    public static func historyFailed(_ token: String) {
        change(token) { $0.historyFailed += 1 }
    }
    public static func historyQueued(_ token: String, count: Int) {
        change(token) { $0.historyQueued += count }
    }
    // #133: only quantitative filter reasons; no message or peer IDs.
    public static func historyFilters(_ token: String, edited: Int, empty: Int,
                                      wrongPeer: Int, unconverted: Int, rejected: Int, known: Int) {
        change(token) { row in
            row.historySkippedEdited = (row.historySkippedEdited ?? 0) + edited
            row.historySkippedEmpty = (row.historySkippedEmpty ?? 0) + empty
            row.historyWrongPeer = (row.historyWrongPeer ?? 0) + wrongPeer
            row.historyNotConverted = (row.historyNotConverted ?? 0) + unconverted
            row.historyWriterRejected = (row.historyWriterRejected ?? 0) + rejected
            row.historySkippedKnown = (row.historySkippedKnown ?? 0) + known
        }
    }
    public static func writerFlush(_ token: String, confirmed: Bool) {
        change(token) { $0.writerFlushConfirmed = confirmed }
    }
    public static func finish(_ token: String, reason: String) {
        change(token) {
            $0.finalReason = reason
            $0.endedAt = Date().timeIntervalSince1970
            $0.stage = reason
            if $0.decision == "pending" { $0.decision = "skipped" }
        }
    }
}

// #115: bounded, opt-in foreground sync trace. It is diagnostic only:
// no message data, peer IDs, auth/session material or transport control.
public struct GoldgramForegroundSyncEvent: Codable {
    public let at: Double
    public let stage: String
    public let rawNetwork: String?
    public let stateManagerUpdating: Bool?
    public let mtprotoFlags: Int32?
}

public enum GoldgramForegroundSyncTrace {
    private static let lock = NSLock()
    private static let keyPrefix = "GoldgramForegroundSyncEventsV1."
    private static let enabledKey = "GoldgramDiagnosticEnabledV1"
    private static let foregroundKey = "GoldgramForegroundActiveV1"
    private static let foregroundSignal = ValuePromise<Bool>(false, ignoreRepeated: true)
    public static var foregroundActive: Signal<Bool, NoError> {
        return foregroundSignal.get()
    }
    public static let lastActivatedKey = "GoldgramForegroundLastActivatedV1"
    public static let lastDeactivatedKey = "GoldgramForegroundLastDeactivatedV1"

    public static func lifecycle(active: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(active, forKey: foregroundKey)
        foregroundSignal.set(active)
        if defaults.bool(forKey: enabledKey) {
            defaults.set(Date().timeIntervalSince1970,
                         forKey: active ? lastActivatedKey : lastDeactivatedKey)
        }
    }

    private static func append(accountPeerId: PeerId, stage: String,
                               rawNetwork: String? = nil,
                               updating: Bool? = nil, flags: Int32? = nil) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: enabledKey),
              defaults.bool(forKey: foregroundKey) else { return }
        let key = keyPrefix + String(accountPeerId.id._internalGetInt64Value())
        lock.lock()
        defer { lock.unlock() }
        let rows: [GoldgramForegroundSyncEvent]
        if let data = defaults.data(forKey: key),
           let decoded = try? PropertyListDecoder().decode([GoldgramForegroundSyncEvent].self, from: data) {
            rows = decoded
        } else {
            rows = []
        }
        if stage == "state", let last = rows.last,
           last.stage == stage, last.rawNetwork == rawNetwork,
           last.stateManagerUpdating == updating, last.mtprotoFlags == flags {
            return
        }
        var updated = rows
        updated.append(GoldgramForegroundSyncEvent(
            at: Date().timeIntervalSince1970, stage: stage,
            rawNetwork: rawNetwork, stateManagerUpdating: updating, mtprotoFlags: flags))
        if let data = try? PropertyListEncoder().encode(Array(updated.suffix(48))) {
            defaults.set(data, forKey: key)
        }
    }

    public static func state(accountPeerId: PeerId, rawNetwork: String,
                             updating: Bool, mtprotoFlags: Int32) {
        append(accountPeerId: accountPeerId, stage: "state", rawNetwork: rawNetwork,
               updating: updating, flags: mtprotoFlags)
    }

    public static func poll(accountPeerId: PeerId, stage: String) {
        append(accountPeerId: accountPeerId, stage: stage)
    }
}

// #118: newest independently sampled foreground state from the actual chat-list
// owner. Unlike the last transition, this has a sampling time and can reveal
// a stale visible title while transport and the account are already online.
// No message, chat, account ID, proxy endpoint, token or session content.
public struct GoldgramForegroundUISnapshot: Codable {
    public let at: Double
    public let rawNetwork: String
    public let accountNetwork: String
    public let stateManagerUpdating: Bool
    public let mtprotoFlags: Int32
    public let titleInputNetwork: String
    public let titleActivity: Bool
    public let titleUpdating: Bool
}

public extension GoldgramForegroundSyncTrace {
    static func uiSample(accountPeerId: PeerId, rawNetwork: String,
                         accountNetwork: String, updating: Bool, flags: Int32,
                         titleInputNetwork: String, titleActivity: Bool,
                         titleUpdating: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "GoldgramDiagnosticEnabledV1"),
              defaults.bool(forKey: "GoldgramForegroundActiveV1") else { return }
        let key = "GoldgramForegroundUISnapshotV1." + String(accountPeerId.id._internalGetInt64Value())
        let snapshot = GoldgramForegroundUISnapshot(
            at: Date().timeIntervalSince1970, rawNetwork: rawNetwork,
            accountNetwork: accountNetwork, stateManagerUpdating: updating,
            mtprotoFlags: flags, titleInputNetwork: titleInputNetwork,
            titleActivity: titleActivity, titleUpdating: titleUpdating)
        if let data = try? PropertyListEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        }
    }
}

// #97: opt-in, account-scoped stage counts. No message contents, IDs,
// peer names or message hashes are recorded. Disabled outside explicit test.
private enum GoldgramCaptureDiagnostics {
    static let queue = DispatchQueue(label: "goldgram.capture.diagnostics", qos: .utility)
    private static let lock = NSLock()
    private static var pending: [String: [String: Int]] = [:]

    static func count(account: PeerId, stage: String) {
        guard UserDefaults.standard.bool(forKey: "GoldgramDiagnosticEnabledV1") else { return }
        let key = "GoldgramDiagnosticCountsV1.\(account.id._internalGetInt64Value())"
        lock.lock()
        let schedule = pending.isEmpty
        pending[key, default: [:]][stage, default: 0] += 1
        lock.unlock()
        if schedule {
            queue.async { flushCounts() }
        }
    }

    private static func flushCounts() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        lock.unlock()
        let defaults = UserDefaults.standard
        for (key, increments) in batch {
            var values = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
            for (stage, increment) in increments {
                values[stage] = min(1_000_000, (values[stage] ?? 0) + increment)
            }
            defaults.set(values, forKey: key)
        }
    }
}
func goldgramDiagnosticRecord(accountPeerId: PeerId, stage: String) {
    GoldgramCaptureDiagnostics.count(account: accountPeerId, stage: stage)
}

// #101. Temporary account- and discussion-scoped diagnostic metadata.
// Only routing identifiers and stage labels; no chat text or sender information.
func goldgramTraceMessage(accountPeerId: PeerId, id: MessageId, stage: String) {
    let defaults = UserDefaults.standard
    let account = accountPeerId.id._internalGetInt64Value()
    guard defaults.bool(forKey: "GoldgramDiagnosticTraceActiveV2.\(account)") else { return }
    let prefix: String
    switch id.peerId.namespace {
    case Namespaces.Peer.CloudUser: prefix = "u"
    case Namespaces.Peer.CloudGroup: prefix = "g"
    case Namespaces.Peer.CloudChannel: prefix = "c"
    default: return
    }
    let peer = "\(prefix):\(id.peerId.id._internalGetInt64Value())"
    guard (defaults.stringArray(forKey: "GoldgramDiagnosticTraceScopeV2.\(account)") ?? []).contains(peer) else { return }
    let key = "\(peer):\(id.id)"
    let storage = "GoldgramDiagnosticTraceRowsV2.\(account)"
    GoldgramCaptureDiagnostics.queue.async {
        var rows = defaults.array(forKey: storage) as? [[String: Any]] ?? []
        if let index = rows.firstIndex(where: { ($0["key"] as? String) == key }) {
            var row = rows.remove(at: index)
            var stages = row["stages"] as? [String] ?? []
            if !stages.contains(stage) { stages.append(stage) }
            row["stages"] = stages
            rows.append(row)
        } else {
            rows.append(["key": key, "stages": [stage]])
            if rows.count > 256 { rows.removeFirst(rows.count - 256) }
        }
        defaults.set(rows, forKey: storage)
    }
}

@inline(never)
@_cdecl("goldgram_native_history_host_v1")
public func goldgramNativeHistoryHostV1() -> Int32 { return 1 }

// Persisted in Postbox's existing local-tags column; no registration/decoder.
// Stock TelegramCore currently reserves only bits 0 and 1.
public let goldgramDeletedMessageTag = LocalMessageTags(rawValue: 1 << 30)
private typealias GoldgramEventWriter = @convention(c) (UnsafePointer<CChar>?) -> Int32
private func goldgramNativeWriter() -> GoldgramEventWriter? {
    guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "goldgram_capture_event_v1") else { return nil }
    return unsafeBitCast(symbol, to: GoldgramEventWriter.self)
}

public func goldgramNativeHistoryEnabled() -> Bool {
    return goldgramNativeHistoryHostV1() == 1 && goldgramNativeWriter() != nil && UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled")
}

// The notification service has its own defaults and does not load Mx. Share
// explicit account-local consent through Postbox, never infer it from a push.
private struct GoldgramCaptureSettings: Codable, Equatable {
    let account: Int64
    let enabled: Bool
    let since: Int32
}
private struct GoldgramPendingEvent: Codable { let data: Data; let kind: Int32 }
private struct GoldgramPendingEvents: Codable { let items: [GoldgramPendingEvent] }
private let goldgramSettingsKey = ItemCacheEntryId(collectionId: -103, key: ValueBoxKey(length: 0))
private let goldgramPendingKey = ItemCacheEntryId(collectionId: -104, key: ValueBoxKey(length: 0))

func goldgramCaptureEnabled(accountPeerId: PeerId, transaction: Transaction) -> Bool {
    let old = transaction.retrieveItemCacheEntry(id: goldgramSettingsKey)?.get(GoldgramCaptureSettings.self)
    if goldgramNativeWriter() != nil {
        let value = GoldgramCaptureSettings(account: accountPeerId.toInt64(), enabled: goldgramNativeHistoryEnabled(), since: goldgramCaptureSince(accountPeerId))
        if value != old, let entry = CodableEntry(value) { transaction.putItemCacheEntry(id: goldgramSettingsKey, entry: entry) }
        return value.enabled
    }
    return old?.account == accountPeerId.toInt64() && old?.enabled == true
}

// Push bodies are presentation text. Keep them apart from confirmed originals.
public struct GoldgramPushPreview: Codable {
    public let peer: Int64
    public let message: Int32
    public let at: Double
    public let body: String
}
private struct GoldgramPushPreviews: Codable {
    let rows: [GoldgramPushPreview]
}
private let goldgramPreviewKey = ItemCacheEntryId(collectionId: -107, key: ValueBoxKey(length: 0))

public func goldgramPushPreviews(_ transaction: Transaction) -> [GoldgramPushPreview] {
    return transaction.retrieveItemCacheEntry(id: goldgramPreviewKey)?.get(GoldgramPushPreviews.self)?.rows ?? []
}

public func goldgramSavePushPreview(_ transaction: Transaction, account: PeerId, id: MessageId, body: String, at: Double) {
    guard id.namespace == Namespaces.Message.Cloud, id.id > 0,
          [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(id.peerId.namespace),
          !body.isEmpty, body.utf8.count <= 4096,
          goldgramCaptureEnabled(accountPeerId: account, transaction: transaction) else { return }
    var rows = goldgramPushPreviews(transaction)
    let peer = id.peerId.toInt64()
    guard !rows.contains(where: { $0.peer == peer && $0.message == id.id }) else { return }
    rows.append(GoldgramPushPreview(peer: peer, message: id.id, at: at, body: body))
    if let entry = CodableEntry(GoldgramPushPreviews(rows: Array(rows.suffix(64)))) {
        transaction.putItemCacheEntry(id: goldgramPreviewKey, entry: entry)
    }
}

public func goldgramClearPushPreviews(_ transaction: Transaction) {
    transaction.removeItemCacheEntry(id: goldgramPreviewKey)
}

private func goldgramDrainPending(accountPeerId: PeerId, transaction: Transaction) {
    guard goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction), goldgramNativeWriter() != nil,
          let pending = transaction.retrieveItemCacheEntry(id: goldgramPendingKey)?.get(GoldgramPendingEvents.self) else { return }
    var remaining: [GoldgramPendingEvent] = []
    for item in pending.items {
        guard let payload = (try? JSONSerialization.jsonObject(with: item.data)) as? [String: Any],
              (payload["accountId"] as? NSNumber)?.int64Value == accountPeerId.id._internalGetInt64Value() else { continue }
        if !goldgramWrite(payload) { remaining.append(item) }
    }
    // Flush accepted events before discarding the durable extension handoff.
    typealias Flush = @convention(c) () -> Int32
    guard let handle = dlopen(nil, RTLD_NOW) else { return }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "goldgram_flush_capture_v1"), unsafeBitCast(symbol, to: Flush.self)() == 1 else { return }
    if remaining.isEmpty { transaction.removeItemCacheEntry(id: goldgramPendingKey) }
    else if let entry = CodableEntry(GoldgramPendingEvents(items: remaining)) { transaction.putItemCacheEntry(id: goldgramPendingKey, entry: entry) }
}

// #136: use a fast, account-scoped committed-baseline check only in the
// opt-in geo history snapshot path. Never skip on error or absent native ABI.
private typealias GoldgramHasOriginalCallback = @convention(c) (Int64, Int32, Int64, Int32) -> Int32
private let goldgramHasOriginalCallback: GoldgramHasOriginalCallback? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "goldgram_has_original_v1") else { return nil }
    return unsafeBitCast(symbol, to: GoldgramHasOriginalCallback.self)
}()

private func goldgramHasCommittedOriginal(accountPeerId: PeerId, kind: Int32, id: MessageId) -> Bool {
    guard let check = goldgramHasOriginalCallback else { return false }
    return check(accountPeerId.id._internalGetInt64Value(), kind,
                 id.peerId.id._internalGetInt64Value(), id.id) == 1
}

// A native flush is a serial-queue fence, not an assertion about any
// particular original. Invoke only in a finite, genuinely OS-awake window.
private typealias GoldgramFlushCallback = @convention(c) () -> Int32
private let goldgramFlushCallback: GoldgramFlushCallback? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "goldgram_flush_capture_v1") else { return nil }
    return unsafeBitCast(symbol, to: GoldgramFlushCallback.self)
}()

public func goldgramFlushOriginalCapture() -> Bool {
    guard goldgramNativeHistoryEnabled(), let flush = goldgramFlushCallback else { return false }
    return flush() == 1
}

// A flush waits for the archive's serial writer queue. Keep this fence off
// the main thread so an OS expiry can cancel the task without waiting for I/O.
// One serial worker also bounds concurrent waits across refresh/geo attempts.
private let goldgramOriginalFlushQueue = Queue(name: "GoldgramOriginalFlush", qos: .utility)

public func goldgramFlushOriginalCaptureAsync() -> Signal<Bool, NoError> {
    return Signal<Bool, NoError> { subscriber in
        subscriber.putNext(goldgramFlushOriginalCapture())
        subscriber.putCompletion()
        return EmptyDisposable
    }
    |> runOn(goldgramOriginalFlushQueue)
}

private func goldgramSavedOriginal(accountPeerId: PeerId, kind: Int32, id: MessageId) -> String? {
    goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: "sqlOriginalLookupAttempt")
    typealias Read = @convention(c) (Int64, Int32, Int64, Int32) -> UnsafeMutablePointer<CChar>?
    guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "goldgram_read_original_v1"),
          let text = unsafeBitCast(symbol, to: Read.self)(accountPeerId.id._internalGetInt64Value(), kind, id.peerId.id._internalGetInt64Value(), id.id) else { return nil }
    defer { free(text) }
    guard let data = String(cString: text).data(using: .utf8),
          let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let result = value["text"] as? String
    if result != nil {
        goldgramDiagnosticRecord(accountPeerId: accountPeerId, stage: "sqliteLookupHit")
        goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: "sqlOriginalLookupHit")
    }
    return result
}

private func goldgramKind(_ id: PeerId, _ peer: Peer?) -> Int32? {
    switch id.namespace {
    case Namespaces.Peer.CloudUser: return 0
    case Namespaces.Peer.CloudGroup: return 1
    case Namespaces.Peer.CloudChannel:
        guard let peer = peer as? TelegramChannel else { return nil }
        switch peer.info { case .group: return 2; case .broadcast: return 3 }
    default: return nil
    }
}

private func goldgramMediaKeys(_ media: [Media]) -> [String] {
    // Web-page refreshes, views and reactions are not user content edits.
    return media.compactMap { value in
        if value is TelegramMediaWebpage || value is TelegramMediaAction { return nil }
        guard let id = value.id else { return nil }
        return "\(id.namespace):\(id.id)"
    }
}

private func goldgramArchiveText(_ text: String, _ media: [Media]) -> String {
    if !text.isEmpty { return text }
    if let image = media.first(where: { $0 is TelegramMediaImage }) as? TelegramMediaImage {
        if let representation = image.representations.last {
            return "[Фото \(representation.dimensions.width)×\(representation.dimensions.height)]"
        }
        return "[Фото]"
    }
    if let file = media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile {
        return file.isVideo ? "[Видео]" : file.isVoice ? "[Голосовое сообщение]" : "[Файл]"
    }
    return media.isEmpty ? "[Без текста]" : "[Медиа / без текста]"
}

@discardableResult
private func goldgramWrite(_ payload: [String: Any], transaction: Transaction? = nil) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), data.count <= 300000,
          let json = String(data: data, encoding: .utf8) else { return false }
    if let writer = goldgramNativeWriter() { return json.withCString { writer($0) == 1 } }
    guard let transaction, payload["text"] as? String != "[Содержимое не было получено]" else { return false }
    var items = transaction.retrieveItemCacheEntry(id: goldgramPendingKey)?.get(GoldgramPendingEvents.self)?.items ?? []
    items.append(GoldgramPendingEvent(data: data, kind: (payload["eventKind"] as? NSNumber)?.int32Value ?? 0))
    var bytes = items.reduce(0) { $0 + $1.data.count }
    while items.count > 512 || bytes > 4 * 1024 * 1024 {
        let index = items.firstIndex(where: { $0.kind == 0 }) ?? 0
        bytes -= items[index].data.count; items.remove(at: index)
    }
    guard let entry = CodableEntry(GoldgramPendingEvents(items: items)) else { return false }
    transaction.putItemCacheEntry(id: goldgramPendingKey, entry: entry)
    return true
}

// First activation of the corrected logger, per authenticated account. Old
// edit dates loaded by scrolling cannot become new archive events.
private func goldgramCaptureSince(_ account: PeerId, transaction: Transaction? = nil) -> Int32 {
    if goldgramNativeWriter() == nil, let transaction,
       let settings = transaction.retrieveItemCacheEntry(id: goldgramSettingsKey)?.get(GoldgramCaptureSettings.self), settings.account == account.toInt64() { return settings.since }
    let key = "GoldgramNativeHistorySinceV2.\(account.id._internalGetInt64Value())"
    let value = UserDefaults.standard.integer(forKey: key)
    if value > 0 { return Int32(clamping: value) }
    let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
    UserDefaults.standard.set(Int(now), forKey: key)
    return now
}

// A real new-message update may be replaced by a newer edit before Postbox
// gets to archive its first snapshot. Record positively received unedited
// server content immediately, independently of that transaction/replay path.
// A delayed original repairs the baseline only, never the latest revision.
@discardableResult
func goldgramCaptureServerOriginal(
    accountPeerId: PeerId, message: StoreMessage, peerKind: Int32,
    evidenceSource: String = "native_unclassified", evidenceAttempt: String? = nil
) -> Bool {
    guard goldgramNativeHistoryEnabled(), (0...3).contains(peerKind),
          case let .Id(id) = message.id, id.namespace == Namespaces.Message.Cloud, id.id > 0,
          !message.attributes.contains(where: { $0 is EditedMessageAttribute }),
          !message.text.isEmpty || !message.media.isEmpty else { return false }
    goldgramDiagnosticRecord(accountPeerId: accountPeerId, stage: "serverEligible")
    goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: "originalEligible")
    let sender = message.authorId
    let original = goldgramArchiveText(message.text, message.media)
    var payload: [String: Any] = [
        "accountId": accountPeerId.id._internalGetInt64Value(), "peerKind": peerKind,
        "peerId": id.peerId.id._internalGetInt64Value(), "messageId": id.id, "eventKind": 0,
        "text": original, "originalText": original, "originalObserved": true,
        "baselineOnly": true,
        "senderId": sender?.id._internalGetInt64Value() ?? 0,
        "senderKind": sender.flatMap { goldgramKind($0, nil) } ?? -1,
        "sentAt": Int64(message.timestamp) * 1000, "threadId": message.threadId ?? 0,
        "mediaKeys": goldgramMediaKeys(message.media),
        "evidenceSource": evidenceSource
    ]
    if let evidenceAttempt { payload["evidenceAttempt"] = evidenceAttempt }
    if goldgramWrite(payload) {
        goldgramDiagnosticRecord(accountPeerId: accountPeerId, stage: "writerAccepted")
        goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: "originalQueued")
        return true
    }
    return false
}

// #103: cross-process notification diagnostics, scoped to a selected folder.
// The Postbox entry is shared by the app and its notification extension. Only
// routing IDs and fixed stages are stored; no message/preview content.
private struct GoldgramNotificationTraceEntry: Codable {
    let peer: Int64
    let message: Int32
    var stages: [String]
}
private struct GoldgramNotificationTrace: Codable {
    let account: Int64
    let peers: [Int64]
    let startedAt: Int64
    var entries: [GoldgramNotificationTraceEntry]
}
private let goldgramNotificationTraceKey = ItemCacheEntryId(collectionId: -105, key: ValueBoxKey(length: 0))

public func goldgramSetNotificationTrace(transaction: Transaction, accountPeerId: PeerId, peers: [PeerId]) {
    if peers.isEmpty {
        transaction.removeItemCacheEntry(id: goldgramNotificationTraceKey)
        return
    }
    guard goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction) else { return }
    let trace = GoldgramNotificationTrace(
        account: accountPeerId.toInt64(), peers: Array(Set(peers.map { $0.toInt64() })).prefix(16).map { $0 },
        startedAt: Int64(Date().timeIntervalSince1970), entries: []
    )
    if let value = CodableEntry(trace) {
        transaction.putItemCacheEntry(id: goldgramNotificationTraceKey, entry: value)
    }
}
public func goldgramNoteNotificationTrace(transaction: Transaction, accountPeerId: PeerId, id: MessageId, stage: String) {
    guard case let .some(trace) = transaction.retrieveItemCacheEntry(id: goldgramNotificationTraceKey)?.get(GoldgramNotificationTrace.self),
          trace.account == accountPeerId.toInt64(),
          Int64(Date().timeIntervalSince1970) - trace.startedAt < 86400,
          trace.peers.contains(id.peerId.toInt64()), id.id > 0 else { return }
    var updated = trace
    if let index = updated.entries.firstIndex(where: { $0.peer == id.peerId.toInt64() && $0.message == id.id }) {
        var entry = updated.entries.remove(at: index)
        if !entry.stages.contains(stage) { entry.stages.append(stage) }
        updated.entries.append(entry)
    } else {
        updated.entries.append(GoldgramNotificationTraceEntry(peer: id.peerId.toInt64(), message: id.id, stages: [stage]))
        if updated.entries.count > 192 { updated.entries.removeFirst(updated.entries.count - 192) }
    }
    if let value = CodableEntry(updated) {
        transaction.putItemCacheEntry(id: goldgramNotificationTraceKey, entry: value)
    }
}
public func goldgramNotificationTraceStages(transaction: Transaction, accountPeerId: PeerId, id: MessageId) -> [String] {
    guard let trace = transaction.retrieveItemCacheEntry(id: goldgramNotificationTraceKey)?.get(GoldgramNotificationTrace.self),
          trace.account == accountPeerId.toInt64(),
          trace.peers.contains(id.peerId.toInt64()) else { return [] }
    return trace.entries.first(where: { $0.peer == id.peerId.toInt64() && $0.message == id.id })?.stages ?? []
}

// A notification service extension may run when iOS has suspended the app.
// Only a complete, actually materialized, unedited Postbox message is evidence.
// Never archive an APNs preview or infer an original from the first edit.
// The extension has no app-host C writer, so it uses the existing bounded
// account-scoped Postbox handoff (-104), drained by the app on next execution.
public func goldgramCaptureNotificationOriginal(
    accountPeerId: PeerId, transaction: Transaction, message: Message
) {
    guard goldgramNativeWriter() == nil,
          goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction) else {
        goldgramNoteNotificationTrace(transaction: transaction, accountPeerId: accountPeerId,
            id: message.id, stage: "extensionCaptureDisabled")
        return
    }
    guard message.id.namespace == Namespaces.Message.Cloud, message.id.id > 0,
          !message.containsSecretMedia,
          !message.attributes.contains(where: { $0 is EditedMessageAttribute }),
          !message.text.isEmpty || !message.media.isEmpty,
          let kind = goldgramKind(message.id.peerId, transaction.getPeer(message.id.peerId))
    else {
        goldgramNoteNotificationTrace(transaction: transaction, accountPeerId: accountPeerId,
            id: message.id, stage: "extensionOriginalIneligible")
        return
    }
    goldgramNoteNotificationTrace(transaction: transaction, accountPeerId: accountPeerId,
        id: message.id, stage: "extensionOriginalEligible")
    let original = goldgramArchiveText(message.text, message.media)
    let author = message.author?.id
    let payload: [String: Any] = [
        "accountId": accountPeerId.id._internalGetInt64Value(),
        "peerKind": kind, "peerId": message.id.peerId.id._internalGetInt64Value(),
        "messageId": message.id.id, "eventKind": 0,
        "text": original, "originalText": original,
        "originalObserved": true, "baselineOnly": true,
        "senderId": author?.id._internalGetInt64Value() ?? 0,
        "senderKind": author.flatMap { goldgramKind($0, transaction.getPeer($0)) } ?? -1,
        "sentAt": Int64(message.timestamp) * 1000,
        "threadId": message.threadId ?? 0,
        "mediaKeys": goldgramMediaKeys(message.media),
        "evidenceSource": "notification_postbox"
    ]
    let accepted = goldgramWrite(payload, transaction: transaction)
    goldgramNoteNotificationTrace(transaction: transaction, accountPeerId: accountPeerId,
        id: message.id, stage: accepted ? "extensionOriginalQueued" : "extensionQueueRejected")
}

// Returns local history metadata to persist together with the server version.
private func goldgramCaptureMutation(accountPeerId: PeerId, transaction: Transaction,
    message: StoreMessage, previous: StoreMessage?) -> GoldgramMessageHistoryAttribute? {
    var history = previous?.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) as? GoldgramMessageHistoryAttribute
    guard case let .Id(id) = message.id,
          let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)) else { return history }
    if let saved = history, !saved.originalObserved,
       let original = goldgramSavedOriginal(accountPeerId: accountPeerId, kind: kind, id: id) {
        history = GoldgramMessageHistoryAttribute(baseline: original, originalObserved: true, entities: [], revisions: saved.revisions, editDates: saved.editDates)
    }
    let edited = message.attributes.compactMap { $0 as? EditedMessageAttribute }.first
    let entities = (message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    let oldEntities = (previous?.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    let verified = GoldgramEventPolicy.shouldArchiveEdit(previousText: previous?.text, currentText: message.text,
        previousMedia: previous.map { goldgramMediaKeys($0.media) } ?? [], currentMedia: goldgramMediaKeys(message.media),
        entitiesChanged: oldEntities != entities, editDate: edited?.date ?? 0, hidden: edited?.isHidden ?? true,
        captureSince: goldgramCaptureSince(accountPeerId, transaction: transaction),
        previousEditDate: (previous?.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date ?? 0)
    guard verified else { return history }
    // A replay of an identical version is not another revision; there is no
    // observation-only backfill from arbitrary historical messages anymore.
    let sender = message.authorId ?? previous?.authorId
    var payload: [String: Any] = [
        "accountId": accountPeerId.id._internalGetInt64Value(), "peerKind": kind,
        "peerId": id.peerId.id._internalGetInt64Value(), "messageId": id.id, "eventKind": 1,
        "text": goldgramArchiveText(message.text, message.media), "changed": true,
        "visibleEdit": true, "editedAt": Int64(edited?.date ?? 0) * 1000,
        "senderId": sender?.id._internalGetInt64Value() ?? 0,
        "senderKind": sender.flatMap { goldgramKind($0, transaction.getPeer($0)) } ?? -1,
        "sentAt": Int64(message.timestamp) * 1000, "threadId": message.threadId ?? 0,
        "mediaKeys": goldgramMediaKeys(message.media), "retained": false
    ]
    if let previous {
        payload["beforeText"] = goldgramArchiveText(previous.text, previous.media)
        payload["beforeMediaKeys"] = goldgramMediaKeys(previous.media)
        payload["originalObserved"] = !previous.attributes.contains(where: { $0 is EditedMessageAttribute })
    }
    if let history, history.originalObserved {
        payload["originalObserved"] = true
        payload["originalText"] = history.baseline
    }
    guard goldgramWrite(payload, transaction: transaction) else { return history }
    // An unavailable original is never invented. Start inline history with the
    // earliest actually received version, labelled honestly by the renderer.
    let previousIsOriginal = previous.map { !$0.attributes.contains(where: { $0 is EditedMessageAttribute }) } ?? false
    let recovered = (history?.originalObserved == true || previousIsOriginal) ? nil : goldgramSavedOriginal(accountPeerId: accountPeerId, kind: kind, id: id)
    let baseline = history?.originalObserved == true ? history!.baseline : recovered ?? history?.baseline ?? previous?.text ?? ""
    let original = history?.originalObserved == true || previousIsOriginal || recovered != nil
    var revisions = history?.revisions ?? []
    var dates = history?.editDates ?? []
    if previous != nil || history == nil {
        revisions.append(goldgramArchiveText(message.text, message.media))
        dates.append(edited?.date ?? 0)
    }
    goldgramDiagnosticRecord(accountPeerId: accountPeerId, stage: original ? "inlineKnown" : "inlineUnknown")
    goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: original ? "inlineKnown" : "inlineMissing")
    return GoldgramMessageHistoryAttribute(baseline: baseline, originalObserved: original,
        entities: recovered == nil ? (history?.entities ?? (previous == nil ? entities : oldEntities)) : [], revisions: revisions, editDates: dates)
}

private func goldgramStoredMessage(_ message: Message, localTags: LocalMessageTags) -> StoreMessage {
    let forward = message.forwardInfo.map {
        StoreMessageForwardInfo(authorId: $0.author?.id, sourceId: $0.source?.id, sourceMessageId: $0.sourceMessageId,
            date: $0.date, authorSignature: $0.authorSignature, psaType: $0.psaType, flags: $0.flags)
    }
    return StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId,
        groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp,
        flags: StoreMessageFlags(message.flags), tags: message.tags, globalTags: message.globalTags,
        localTags: localTags, forwardInfo: forward, authorId: message.author?.id, text: message.text,
        attributes: message.attributes.filter { !($0 is AutoremoveTimeoutMessageAttribute) && !($0 is AutoclearTimeoutMessageAttribute) },
        media: message.media)
}

// A delayed original is still evidence, even after a newer version won the
// live-row race. Save its baseline separately from the current message body.
private func goldgramAcceptLateOriginal(accountPeerId: PeerId, transaction: Transaction,
    id: MessageId, incoming: StoreMessage, current: StoreMessage) -> StoreMessage {
    guard !incoming.attributes.contains(where: { $0 is EditedMessageAttribute }),
          current.attributes.contains(where: { $0 is EditedMessageAttribute }),
          goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction),
          let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)) else { return current }
    let history = current.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) as? GoldgramMessageHistoryAttribute
    if history?.originalObserved == true { return current }
    let sender = incoming.authorId ?? current.authorId
    let payload: [String: Any] = [
        "accountId": accountPeerId.id._internalGetInt64Value(), "peerKind": kind,
        "peerId": id.peerId.id._internalGetInt64Value(), "messageId": id.id, "eventKind": 0,
        "text": goldgramArchiveText(current.text, current.media),
        "originalText": goldgramArchiveText(incoming.text, incoming.media), "originalObserved": true,
        "baselineOnly": true, "senderId": sender?.id._internalGetInt64Value() ?? 0,
        "senderKind": sender.flatMap { goldgramKind($0, transaction.getPeer($0)) } ?? -1,
        "sentAt": Int64(incoming.timestamp) * 1000, "threadId": current.threadId ?? 0
    ]
    guard goldgramWrite(payload, transaction: transaction) else { return current }
    var repaired = current
    if let history {
        let entities = (incoming.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
        let fixed = GoldgramMessageHistoryAttribute(baseline: incoming.text, originalObserved: true,
            entities: entities, revisions: history.revisions, editDates: history.editDates)
        repaired = current.withUpdatedAttributes(current.attributes.filter { !($0 is GoldgramMessageHistoryAttribute) } + [fixed])
    }
    goldgramSaveSnapshot(transaction: transaction, message: repaired)
    return repaired
}

// Keep tombstones intact when a later history/reaction fetch repeats an item.
func goldgramPrepareIncoming(accountPeerId: PeerId, transaction: Transaction, message: StoreMessage) -> StoreMessage {
    guard case let .Id(id) = message.id, id.namespace == Namespaces.Message.Cloud, id.id > 0 else { return message }
    let edited = message.attributes.contains(where: { $0 is EditedMessageAttribute })
    goldgramDiagnosticRecord(accountPeerId: accountPeerId, stage: edited ? "postboxEdited" : "postboxUnedited")
    goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: edited ? "postboxEdited" : "postboxUnedited")
    let stored = transaction.getMessage(id).map { goldgramStoredMessage($0, localTags: $0.localTags) }
    // Existing retained content must not be erased by a duplicate payload,
    // even after the user turns off capture of NEW events.
    if message.localTags.contains(goldgramDeletedMessageTag) {
        return message.withUpdatedAttributes(message.attributes.filter {
            !($0 is AutoremoveTimeoutMessageAttribute) && !($0 is AutoclearTimeoutMessageAttribute)
        })
    }
    if let stored, stored.localTags.contains(goldgramDeletedMessageTag) {
        return goldgramAcceptLateOriginal(accountPeerId: accountPeerId, transaction: transaction, id: id, incoming: message, current: stored)
    }
    guard goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction) else { return message }
    goldgramDiagnosticRecord(accountPeerId: accountPeerId, stage: "postboxCaptureEnabled")
    goldgramTraceMessage(accountPeerId: accountPeerId, id: id, stage: "postboxCaptureEnabled")
    let snapshot = goldgramSnapshot(transaction: transaction, id: id)
    if let snapshot, snapshot.localTags.contains(goldgramDeletedMessageTag) {
        return goldgramAcceptLateOriginal(accountPeerId: accountPeerId, transaction: transaction, id: id, incoming: message, current: snapshot)
    }
    // The independent snapshot is the last captured version. A native path
    // may already have replaced the live row; comparing only that row would
    // lose the original again. This also orders repeated IDs in one batch.
    var previous = snapshot ?? stored
    let snapshotDate = (snapshot?.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date ?? 0
    let incomingDate = (message.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date ?? 0
    if let snapshot, snapshotDate > incomingDate {
        return goldgramAcceptLateOriginal(accountPeerId: accountPeerId, transaction: transaction, id: id, incoming: message, current: snapshot)
    }
    // Other native fetch paths may have replaced the row without our local
    // attribute. Carry the independently saved history through that refresh.
    if let current = previous, !current.attributes.contains(where: { $0 is GoldgramMessageHistoryAttribute }),
       let history = snapshot?.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) {
        previous = current.withUpdatedAttributes(current.attributes + [history])
    }
    let history = goldgramCaptureMutation(accountPeerId: accountPeerId, transaction: transaction, message: message, previous: previous)
    var attributes = message.attributes.filter { !($0 is GoldgramMessageHistoryAttribute) }
    if let history { attributes.append(history) }
    var prepared = message.withUpdatedAttributes(attributes)
    if prepared.authorId == nil, let sender = previous?.authorId {
        prepared = StoreMessage(id: prepared.id, customStableId: prepared.customStableId,
            globallyUniqueId: prepared.globallyUniqueId, groupingKey: prepared.groupingKey, threadId: prepared.threadId,
            timestamp: prepared.timestamp, flags: prepared.flags, tags: prepared.tags, globalTags: prepared.globalTags,
            localTags: prepared.localTags, forwardInfo: prepared.forwardInfo, authorId: sender, text: prepared.text,
            attributes: prepared.attributes, media: prepared.media)
    }
    goldgramRememberDiscussion(transaction: transaction, peerId: id.peerId)
    if goldgramSaveSnapshot(transaction: transaction, message: prepared),
       let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)) {
        // Observation has no edit/delete event. Keep received content in SQLite
        // too, so losing a ring snapshot cannot turn a known body into a receipt.
        let sender = prepared.authorId
        let _ = goldgramWrite([
            "accountId": accountPeerId.id._internalGetInt64Value(), "peerKind": kind,
            "peerId": id.peerId.id._internalGetInt64Value(), "messageId": id.id, "eventKind": 0,
            "text": goldgramArchiveText(prepared.text, prepared.media),
            "originalObserved": !prepared.attributes.contains(where: { $0 is EditedMessageAttribute }),
            "senderId": sender?.id._internalGetInt64Value() ?? 0,
            "senderKind": sender.flatMap { goldgramKind($0, transaction.getPeer($0)) } ?? -1,
            "sentAt": Int64(prepared.timestamp) * 1000, "threadId": prepared.threadId ?? 0,
            "editedAt": Int64(incomingDate) * 1000
        ], transaction: transaction)
    }
    return prepared
}

// Archive navigation can reinsert a full previously received snapshot. It
// never manufactures content from an ID or fetches a deleted server message.
private func goldgramHydrateOriginal(transaction: Transaction, id: MessageId, accountPeerId: PeerId?) {
    guard let accountPeerId, let message = transaction.getMessage(id),
          let history = message.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) as? GoldgramMessageHistoryAttribute,
          !history.originalObserved, let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)),
          let original = goldgramSavedOriginal(accountPeerId: accountPeerId, kind: kind, id: id) else { return }
    transaction.updateMessage(id, preprocess: false, update: { current in
        let fixed = GoldgramMessageHistoryAttribute(baseline: original, originalObserved: true, entities: [], revisions: history.revisions, editDates: history.editDates)
        return .update(goldgramStoredMessage(current, localTags: current.localTags).withUpdatedAttributes(current.attributes.filter { !($0 is GoldgramMessageHistoryAttribute) } + [fixed]))
    })
    if let updated = transaction.getMessage(id) { goldgramSaveSnapshot(transaction: transaction, message: goldgramStoredMessage(updated, localTags: updated.localTags)) }
}

public func goldgramRestoreSnapshot(transaction: Transaction, id: MessageId, deleted: Bool = false, accountPeerId: PeerId? = nil) -> Message? {
    goldgramHydrateOriginal(transaction: transaction, id: id, accountPeerId: accountPeerId)
    if let message = transaction.getMessage(id) {
        if !message.attributes.contains(where: { $0 is GoldgramMessageHistoryAttribute }),
           let snapshot = goldgramSnapshot(transaction: transaction, id: id), snapshot.text == message.text,
           let history = snapshot.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) {
            transaction.updateMessage(id, preprocess: false, update: { current in
                let hydrated = goldgramStoredMessage(current, localTags: current.localTags)
                    .withUpdatedAttributes(current.attributes + [history])
                return .update(hydrated)
            })
        }
        if deleted || message.localTags.contains(goldgramDeletedMessageTag) {
            transaction.updateMessage(id, preprocess: false, update: { current in
                var tags = current.localTags; tags.insert(goldgramDeletedMessageTag)
                return .update(goldgramStoredMessage(current, localTags: tags))
            })
            transaction.clearTimestampBasedAttribute(id: id, tag: 0)
            transaction.clearTimestampBasedAttribute(id: id, tag: 1)
        }
        return transaction.getMessage(id)
    }
    guard let snapshot = goldgramSnapshot(transaction: transaction, id: id) else { return nil }
    var restored = snapshot
    if deleted || snapshot.localTags.contains(goldgramDeletedMessageTag) {
        var tags = snapshot.localTags; tags.insert(goldgramDeletedMessageTag)
        restored = snapshot.withUpdatedLocalTags(tags).withUpdatedAttributes(snapshot.attributes.filter {
            !($0 is AutoremoveTimeoutMessageAttribute) && !($0 is AutoclearTimeoutMessageAttribute)
        })
    }
    let _ = transaction.addMessages([restored], location: .Random, preprocess: false)
    goldgramHydrateOriginal(transaction: transaction, id: id, accountPeerId: accountPeerId)
    if restored.localTags.contains(goldgramDeletedMessageTag) {
        transaction.clearTimestampBasedAttribute(id: id, tag: 0)
        transaction.clearTimestampBasedAttribute(id: id, tag: 1)
    }
    return transaction.getMessage(id)
}

// A retained row is local history, not a server-owned row to expire again.
// This must work with capture OFF too; Clear Logs explicitly deletes these rows.
func goldgramPreserveRetained(transaction: Transaction, id: MessageId) -> Bool {
    guard id.namespace == Namespaces.Message.Cloud,
          let message = transaction.getMessage(id),
          message.localTags.contains(goldgramDeletedMessageTag) else { return false }
    if message.attributes.contains(where: { $0 is AutoremoveTimeoutMessageAttribute || $0 is AutoclearTimeoutMessageAttribute }) {
        transaction.updateMessage(id, preprocess: false, update: { current in
            return .update(goldgramStoredMessage(current, localTags: current.localTags))
        })
    }
    transaction.clearTimestampBasedAttribute(id: id, tag: 0)
    transaction.clearTimestampBasedAttribute(id: id, tag: 1)
    return true
}

// Preserve a full native message (including media references) at its real ID.
// Returns false for unknown/secret/local messages, which follow stock deletion.
public func goldgramRetainDeletion(accountPeerId: PeerId, transaction: Transaction, mediaBox: MediaBox, id: MessageId) -> Bool {
    if goldgramPreserveRetained(transaction: transaction, id: id) { return true }
    guard goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction), id.namespace == Namespaces.Message.Cloud, id.id > 0,
          let kind = goldgramKind(id.peerId, transaction.getPeer(id.peerId)) else { return false }
    goldgramRememberDiscussion(transaction: transaction, peerId: id.peerId, explicitlyOpened: true)
    let message = goldgramRestoreSnapshot(transaction: transaction, id: id, accountPeerId: accountPeerId)
    let sender = message?.author?.id ?? goldgramSnapshotAuthor(transaction: transaction, id: id)?.id
    var payload: [String: Any] = [
        "accountId": accountPeerId.id._internalGetInt64Value(), "peerKind": kind,
        "peerId": id.peerId.id._internalGetInt64Value(), "messageId": id.id, "eventKind": 2,
        "text": message.map { goldgramArchiveText($0.text, $0.media) } ?? "[Содержимое не было получено]",
        "senderId": sender?.id._internalGetInt64Value() ?? 0,
        "senderKind": sender.flatMap { goldgramKind($0, transaction.getPeer($0)) } ?? -1,
        "sentAt": Int64(message?.timestamp ?? 0) * 1000, "threadId": message?.threadId ?? 0,
        "retained": message != nil,
        "originalObserved": message.map { !$0.attributes.contains(where: { $0 is EditedMessageAttribute }) } ?? false
    ]
    if let history = message?.attributes.first(where: { $0 is GoldgramMessageHistoryAttribute }) as? GoldgramMessageHistoryAttribute, history.originalObserved {
        payload["originalObserved"] = true
        payload["originalText"] = history.baseline
    }
    guard goldgramWrite(payload, transaction: transaction), let message else { return false }
    if !message.localTags.contains(goldgramDeletedMessageTag) {
        transaction.updateMessage(id, preprocess: false, update: { current in
            var tags = current.localTags; tags.insert(goldgramDeletedMessageTag)
            return .update(goldgramStoredMessage(current, localTags: tags))
        })
    }
    transaction.clearTimestampBasedAttribute(id: id, tag: 0)
    transaction.clearTimestampBasedAttribute(id: id, tag: 1)
    if let retained = transaction.getMessage(id) {
        goldgramSaveSnapshot(transaction: transaction, message: goldgramStoredMessage(retained, localTags: retained.localTags))
    }
    goldgramBackupMedia(accountId: accountPeerId.id._internalGetInt64Value(), mediaBox: mediaBox, media: message.media)
    return true
}

func goldgramUnresolvedDeletions(accountPeerId: PeerId, ids: [Int32]) {
    guard goldgramNativeHistoryEnabled() else { return }
    for id in ids where id > 0 {
        goldgramWrite(["accountId": accountPeerId.id._internalGetInt64Value(), "eventKind": 2,
            "peerKind": -1, "peerId": 0, "messageId": id])
    }
}

private let goldgramMediaQueue = DispatchQueue(label: "goldgram.retained.media", qos: .utility)
private func goldgramMediaDirectory(_ accountId: Int64) -> URL {
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Goldgram/Accounts/\(accountId)/retained-media", isDirectory: true)
}
private func goldgramMediaName(_ id: MediaResourceId) -> String {
    return Data(id.stringRepresentation.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
}
private func goldgramResourceIds(_ media: [Media]) -> [MediaResourceId] {
    var ids: [MediaResourceId] = []
    for value in media {
        addMessageMediaResourceIdsToRemove(media: value, resourceIds: &ids)
        if let page = value as? TelegramMediaWebpage, case let .Loaded(content) = page.content {
            if let image = content.image { addMessageMediaResourceIdsToRemove(media: image, resourceIds: &ids) }
            if let file = content.file { addMessageMediaResourceIdsToRemove(media: file, resourceIds: &ids) }
        }
    }
    return Array(Set(ids))
}
private func goldgramBackupMedia(accountId: Int64, mediaBox: MediaBox, media: [Media]) {
    let ids = goldgramResourceIds(media)
    let pins = ids.map { mediaBox.keepResource(id: $0).start() }
    goldgramMediaQueue.async {
        defer { pins.forEach { $0.dispose() } }
        let folder = goldgramMediaDirectory(accountId)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var url = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            for id in ids {
                let destination = folder.appendingPathComponent(goldgramMediaName(id))
                guard !FileManager.default.fileExists(atPath: destination.path),
                      let source = mediaBox.completedResourcePath(id: id) else { continue }
                // Hard links preserve downloaded bytes when the media cache is
                // unlinked, without duplicating large files. Copy is fallback.
                do { try FileManager.default.linkItem(atPath: source, toPath: destination.path) }
                catch { try? FileManager.default.copyItem(atPath: source, toPath: destination.path) }
            }
        } catch { /* Retained native message still works for cached resources. */ }
    }
}

public func goldgramRestoreRetainedMedia(accountId: Int64, mediaBox: MediaBox, media: [Media], completion: @escaping () -> Void) {
    let ids = goldgramResourceIds(media)
    goldgramMediaQueue.async {
        for id in ids where mediaBox.completedResourcePath(id: id) == nil {
            let path = goldgramMediaDirectory(accountId).appendingPathComponent(goldgramMediaName(id))
            if let data = try? Data(contentsOf: path, options: .mappedIfSafe) {
                mediaBox.storeResourceData(id, data: data, synchronous: true)
            }
        }
        DispatchQueue.main.async(execute: completion)
    }
}

public func goldgramClearRetainedMedia(accountId: Int64, completion: @escaping () -> Void) {
    goldgramMediaQueue.async {
        try? FileManager.default.removeItem(at: goldgramMediaDirectory(accountId))
        DispatchQueue.main.async(execute: completion)
    }
}

// #127 opt-in laboratory mode: account-scoped, OFF by default. No GPS or
// unsupported background entitlements, no change to ordinary MTProto policy.
public func goldgramFullCaptureLabEnabled(accountPeerId: PeerId) -> Bool {
    return goldgramNativeHistoryEnabled() && UserDefaults.standard.bool(
        forKey: "GoldgramFullCaptureLabV1.\(accountPeerId.id._internalGetInt64Value())")
}

// #104: opt-in, account-local priority groups for linked channel discussions.
// This does not join groups, request notifications or keep iOS alive.
private struct GoldgramPriorityDiscussion: Codable {
    let channel: Int64
    let discussion: Int64
}
private struct GoldgramPriorityDiscussions: Codable {
    let account: Int64
    let items: [GoldgramPriorityDiscussion]
}
private let goldgramPriorityDiscussionsKey = ItemCacheEntryId(collectionId: -106, key: ValueBoxKey(length: 0))

// Accept only an actual broadcast channel and its validated linked group.
// An archive folder title or a nearby message never proves a relationship.
public func goldgramSetPriorityDiscussion(transaction: Transaction, accountPeerId: PeerId,
    channelPeerId: PeerId, enabled: Bool) -> (status: String, count: Int) {
    guard goldgramCaptureEnabled(accountPeerId: accountPeerId, transaction: transaction),
          let channel = transaction.getPeer(channelPeerId) as? TelegramChannel,
          case .broadcast = channel.info else { return ("unavailable", 0) }
    let old = transaction.retrieveItemCacheEntry(id: goldgramPriorityDiscussionsKey)?
        .get(GoldgramPriorityDiscussions.self)
    var items = old?.account == accountPeerId.toInt64() ? old!.items : []
    items.removeAll(where: { $0.channel == channelPeerId.toInt64() })
    if enabled {
        guard let cached = transaction.getPeerCachedData(peerId: channelPeerId) as? CachedChannelData,
              case let .known(linkedId) = cached.linkedDiscussionPeerId,
              let linkedId,
              let discussion = transaction.getPeer(linkedId) as? TelegramChannel,
              case .group = discussion.info,
              apiInputPeer(discussion) != nil else {
            return ("linked_group_unavailable", old?.items.count ?? 0)
        }
        // A known reverse mapping must be consistent.
        if let opposite = transaction.getPeerCachedData(peerId: linkedId) as? CachedChannelData,
           case let .known(backId) = opposite.linkedDiscussionPeerId,
           backId != channelPeerId {
            return ("linked_group_unavailable", old?.items.count ?? 0)
        }
        guard items.count < 8 else { return ("limit_reached", items.count) }
        items.append(GoldgramPriorityDiscussion(
            channel: channelPeerId.toInt64(), discussion: linkedId.toInt64()))
    }
    let value = GoldgramPriorityDiscussions(account: accountPeerId.toInt64(), items: items)
    guard let entry = CodableEntry(value) else { return ("unavailable", items.count) }
    transaction.putItemCacheEntry(id: goldgramPriorityDiscussionsKey, entry: entry)
    return (enabled ? "enabled" : "disabled", items.count)
}

// #110: distinguish a missing watch list from pinned channels whose cached
// linked peers cannot currently be validated. Never infer group access.
private struct GoldgramPrioritySelection {
    var peers: [PeerId] = []
    var stored = 0
    var rejectedPeer = 0
    var rejectedLink = 0
    var rejectedGroup = 0
    var rejectedAccess = 0
}

private func goldgramPrioritySelection(transaction: Transaction, accountPeerId: PeerId) -> GoldgramPrioritySelection {
    var selection = GoldgramPrioritySelection()
    guard let stored = transaction.retrieveItemCacheEntry(id: goldgramPriorityDiscussionsKey)?
        .get(GoldgramPriorityDiscussions.self),
        stored.account == accountPeerId.toInt64() else { return selection }
    selection.stored = stored.items.count
    for entry in stored.items.prefix(8) {
        let channelId = PeerId(entry.channel)
        let groupId = PeerId(entry.discussion)
        guard let channel = transaction.getPeer(channelId) as? TelegramChannel,
              case .broadcast = channel.info else {
            selection.rejectedPeer += 1
            continue
        }
        guard let cached = transaction.getPeerCachedData(peerId: channelId) as? CachedChannelData,
              case let .known(linkedId) = cached.linkedDiscussionPeerId,
              linkedId == groupId else {
            selection.rejectedLink += 1
            continue
        }
        guard let discussion = transaction.getPeer(groupId) as? TelegramChannel,
              case .group = discussion.info else {
            selection.rejectedGroup += 1
            continue
        }
        guard apiInputPeer(discussion) != nil else {
            selection.rejectedAccess += 1
            continue
        }
        if let opposite = transaction.getPeerCachedData(peerId: groupId) as? CachedChannelData,
           case let .known(backId) = opposite.linkedDiscussionPeerId,
           backId != channelId {
            selection.rejectedLink += 1
            continue
        }
        if !selection.peers.contains(groupId) { selection.peers.append(groupId) }
    }
    return selection
}

private func goldgramPriorityPeers(transaction: Transaction, accountPeerId: PeerId) -> [PeerId] {
    return goldgramPrioritySelection(transaction: transaction, accountPeerId: accountPeerId).peers
}

// Account-local, bounded list of recently received/opened cloud dialogs.
// Seed recent bodies on wake; channel polling shares the stock reference count.
private struct GoldgramDiscussionTarget: Codable {
    let peer: Int64
    let seen: Int64
}
private struct GoldgramDiscussionTargets: Codable {
    let items: [GoldgramDiscussionTarget]
}
private let goldgramDiscussionTargetsKey = ItemCacheEntryId(collectionId: -102, key: ValueBoxKey(length: 0))

func goldgramRememberDiscussion(transaction: Transaction, peerId: PeerId, explicitlyOpened: Bool = false) {
    guard goldgramNativeHistoryEnabled(), goldgramKind(peerId, transaction.getPeer(peerId)) != nil else { return }
    if let channel = transaction.getPeer(peerId) as? TelegramChannel, case .broadcast = channel.info,
       let cached = transaction.getPeerCachedData(peerId: peerId) as? CachedChannelData,
       case let .known(linked) = cached.linkedDiscussionPeerId, let linked,
       let group = transaction.getPeer(linked) as? TelegramChannel, case .group = group.info {
        goldgramRememberDiscussion(transaction: transaction, peerId: linked, explicitlyOpened: true)
    }
    let now = Int64(Date().timeIntervalSince1970)
    let old = transaction.retrieveItemCacheEntry(id: goldgramDiscussionTargetsKey)?.get(GoldgramDiscussionTargets.self)?.items ?? []
    // Avoid rewriting the watch list on every received comment/reaction.
    if let current = old.first(where: { $0.peer == peerId.toInt64() }), now - current.seen < 60 { return }
    var items = old.filter { $0.peer != peerId.toInt64() && now - $0.seen < 86400 }
    items.insert(GoldgramDiscussionTarget(peer: peerId.toInt64(), seen: now), at: 0)
    if let entry = CodableEntry(GoldgramDiscussionTargets(items: Array(items.prefix(8)))) {
        transaction.putItemCacheEntry(id: goldgramDiscussionTargetsKey, entry: entry)
    }
}

// Seed only the latest 100 accessible messages, once per active subscription.
// This neither marks history read nor joins a group, and downloads no media.
private func goldgramSeedDiscussion(account: Account, peerId: PeerId, labOnly: Bool = false, locationTraceToken: String? = nil) -> Signal<Never, NoError> {
    return account.postbox.transaction { transaction -> (Peer, Api.InputPeer)? in
        guard goldgramNativeHistoryEnabled(), let peer = transaction.getPeer(peerId),
              goldgramKind(peerId, peer) != nil, let input = apiInputPeer(peer) else { return nil }
        return (peer, input)
    }
    |> mapToSignal { value -> Signal<Never, NoError> in
        guard let (peer, input) = value else { return .complete() }
        if let locationTraceToken { GoldgramLocationLabTrace.historyStarted(locationTraceToken) }
        return account.network.request(Api.functions.messages.getHistory(peer: input, offsetId: 0, offsetDate: 0, addOffset: 0, limit: 100, maxId: 0, minId: 0, hash: 0))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.messages.Messages?, NoError> in
            if let locationTraceToken { GoldgramLocationLabTrace.historyFailed(locationTraceToken) }
            return .single(nil)
        }
        |> mapToSignal { response -> Signal<Never, NoError> in
            guard let response else { return .complete() }
            return account.postbox.transaction { transaction -> Void in
                guard goldgramNativeHistoryEnabled() else { return }
                let messages: [Api.Message]
                let chats: [Api.Chat]
                let users: [Api.User]
                switch response {
                case let .messages(data): messages = data.messages; chats = data.chats; users = data.users
                case let .messagesSlice(data): messages = data.messages; chats = data.chats; users = data.users
                case let .channelMessages(data): messages = data.messages; chats = data.chats; users = data.users
                case .messagesNotModified: return
                }
                if let locationTraceToken {
                    GoldgramLocationLabTrace.historyResponse(locationTraceToken, messages: messages.count)
                }
                updatePeers(transaction: transaction, accountPeerId: account.peerId,
                    peers: AccumulatedPeers(transaction: transaction, chats: chats, users: users))
                let stored = messages.compactMap { StoreMessage(apiMessage: $0, accountPeerId: account.peerId, peerIsForum: (peer as? TelegramChannel)?.isForumOrMonoForum ?? false) }
                if labOnly {
                    // Never overwrite a newer Postbox revision with a snapshot.
                    // Only positively received unedited bodies are baseline-only
                    // native writes. Edited snapshots are rejected by the writer.
                    guard let kind = goldgramKind(peerId, peer) else { return }
                    var accepted = 0
                    var skippedEdited = 0
                    var skippedEmpty = 0
                    var wrongPeer = 0
                    var writerRejected = 0
                    var skippedKnown = 0
                    for message in stored {
                        guard case let .Id(id) = message.id, id.peerId == peerId else {
                            wrongPeer += 1
                            continue
                        }
                        if message.attributes.contains(where: { $0 is EditedMessageAttribute }) {
                            skippedEdited += 1
                            continue
                        }
                        if message.text.isEmpty && message.media.isEmpty {
                            skippedEmpty += 1
                            continue
                        }
                        // Never replay already committed baselines through the
                        // async writer. A failed/unknown lookup falls through
                        // to the existing idempotent INSERT OR IGNORE path.
                        if goldgramHasCommittedOriginal(accountPeerId: account.peerId,
                            kind: kind, id: id) {
                            skippedKnown += 1
                            continue
                        }
                        if goldgramCaptureServerOriginal(
                            accountPeerId: account.peerId, message: message, peerKind: kind,
                            evidenceSource: locationTraceToken.map {
                                GoldgramLocationLabTrace.evidenceSource(for: $0)
                            } ?? "history_snapshot",
                            evidenceAttempt: locationTraceToken) {
                            accepted += 1
                        } else {
                            writerRejected += 1
                        }
                    }
                    if let locationTraceToken {
                        GoldgramLocationLabTrace.historyQueued(locationTraceToken, count: accepted)
                        GoldgramLocationLabTrace.historyFilters(locationTraceToken,
                            edited: skippedEdited, empty: skippedEmpty,
                            wrongPeer: wrongPeer,
                            unconverted: max(0, messages.count - stored.count),
                            rejected: writerRejected, known: skippedKnown)
                    }
                } else {
                    let _ = transaction.addMessages(stored, location: .Random)
                }
            }
            |> ignoreValues
        }
    }
}

private final class GoldgramDiscussionMonitor {
    private let account: Account
    private let refresh = MetaDisposable()
    private let labPulse = MetaDisposable()
    private let labSeedWork = MetaDisposable()
    private var subscriptions: [PeerId: Disposable] = [:]

    init(account: Account, queue: Queue) {
        self.account = account
        let tick: Signal<Void, NoError> = .single(())
        let clock = tick |> then(Signal<Void, NoError>.complete() |> delay(15.0, queue: queue)) |> restart
        self.refresh.set((clock
        |> mapToSignal { _ -> Signal<[PeerId], NoError> in
            return account.postbox.transaction { transaction -> [PeerId] in
                goldgramDrainPending(accountPeerId: account.peerId, transaction: transaction)
                guard goldgramNativeHistoryEnabled() else { return [] }
                let now = Int64(Date().timeIntervalSince1970)
                let items = transaction.retrieveItemCacheEntry(id: goldgramDiscussionTargetsKey)?.get(GoldgramDiscussionTargets.self)?.items ?? []
                // Keep user-selected linked discussions first (max 8), then
                // fill remaining slots with recently opened dialogs (max 10).
                // All subscriptions stop when the host stops executing.
                var wanted = goldgramPriorityPeers(transaction: transaction, accountPeerId: account.peerId)
                for item in items where now - item.seen < 86400 && wanted.count < 10 {
                    let id = PeerId(item.peer)
                    guard goldgramKind(id, transaction.getPeer(id)) != nil,
                          !wanted.contains(id) else { continue }
                    wanted.append(id)
                }
                return wanted
            }
        }
        |> deliverOn(queue)).start(next: { [weak self] ids in
            guard let self else { return }
            let wanted = Set(ids)
            for id in Array(self.subscriptions.keys) where !wanted.contains(id) {
                self.subscriptions.removeValue(forKey: id)?.dispose()
            }
            for id in ids where self.subscriptions[id] == nil {
                let disposable = DisposableSet()
                // Reuse the stock reference-counted poller: server timeout,
                // pts-gap handling and dedup are shared with an open chat.
                if id.namespace == Namespaces.Peer.CloudChannel {
                    disposable.add(account.viewTracker.polledChannel(peerId: id).start())
                }
                disposable.add(goldgramSeedDiscussion(account: account, peerId: id).start())
                self.subscriptions[id] = disposable
            }
        }))
        // #127 LAB: aggressively request genuine current unedited bodies for
        // up to 3 verified pinned discussions while Swiftgram is foreground.
        // No new request is kept when the client is backgrounded.
        let labClock: Signal<Void, NoError> = .single(())
        |> then(Signal<Void, NoError>.complete() |> delay(10.0, queue: queue))
        |> restart
        self.labPulse.set((labClock
        |> mapToSignal { _ -> Signal<[PeerId], NoError> in
            guard goldgramFullCaptureLabEnabled(accountPeerId: account.peerId),
                  UserDefaults.standard.bool(forKey: "GoldgramForegroundActiveV1") else {
                return .single([])
            }
            return account.postbox.transaction { transaction -> [PeerId] in
                return Array(goldgramPriorityPeers(transaction: transaction,
                    accountPeerId: account.peerId).prefix(3))
            }
        }
        |> deliverOn(queue)).start(next: { [weak self] ids in
            guard let self else { return }
            if ids.isEmpty {
                self.labSeedWork.set(nil)
                return
            }
            let requests = DisposableSet()
            for id in ids {
                requests.add(goldgramSeedDiscussion(account: account, peerId: id, labOnly: true).start())
            }
            // Never allow accumulating outstanding laboratory requests.
            self.labSeedWork.set(requests)
        }))
    }
    func stop() {
        self.refresh.dispose()
        self.labPulse.dispose()
        self.labSeedWork.dispose()
        for disposable in self.subscriptions.values { disposable.dispose() }
        self.subscriptions.removeAll()
    }
}

// #114: Observe existing service-master/network gates ONLY for an actual
// OS BGAppRefresh account. Neither signal is modified by this observer.
public func goldgramObserveBackgroundConnectionReadiness(
    account: Account, diagnosticToken: String
) -> Disposable {
    let observations = DisposableSet()
    observations.add(account.shouldBeServiceTaskMaster.get().start(next: { mode in
        let label: String
        switch mode {
        case .never: label = "never"
        case .now: label = "now"
        case .always: label = "always"
        }
        GoldgramBackgroundRefreshTrace.serviceMaster(diagnosticToken, mode: label)
    }))
    observations.add(account.postbox.isMasterClient().start(next: { isMaster in
        GoldgramBackgroundRefreshTrace.postboxMaster(diagnosticToken, value: isMaster)
    }))
    observations.add(account.network.shouldKeepConnection.get().start(next: { enabled in
        GoldgramBackgroundRefreshTrace.networkPermission(diagnosticToken, value: enabled)
    }))
    observations.add(account.network.mtprotoDiagnosticFlags.start(next: { flags in
        GoldgramBackgroundRefreshTrace.transportFlags(diagnosticToken, flags: flags)
    }))
    observations.add(account.network.connectionStatus.start(next: { status in
        let label: String
        switch status {
        case .waitingForNetwork: label = "waiting"
        case .connecting: label = "connecting"
        case .updating: label = "updating"
        case .online: label = "online"
        }
        GoldgramBackgroundRefreshTrace.networkStatus(diagnosticToken, status: label)
    }))
    return observations
}

public func goldgramMinimizedSnapshot(account: Account) -> Signal<Never, NoError> {
    return account.postbox.transaction { transaction -> PeerId? in
        guard goldgramNativeHistoryEnabled() else { return nil }
        return goldgramPriorityPeers(transaction: transaction, accountPeerId: account.peerId).last
    } |> mapToSignal { id -> Signal<Never, NoError> in
        guard let id else { return .complete() }
        return goldgramSeedDiscussion(account: account, peerId: id, labOnly: true)
    }
}

// #107: an iOS-discretionary BGAppRefresh window, not a keep-alive.
// Use ONLY user-pinned verified linked discussions and the existing PTS
// difference replay. Correct original evidence must precede subsequent edits.
public func goldgramRefreshPriorityDiscussions(
    account: Account, diagnosticToken: String
) -> Signal<Never, NoError> {
    GoldgramBackgroundRefreshTrace.phase(diagnosticToken, "await_postbox",
        accountId: account.peerId.id._internalGetInt64Value())
    return account.postbox.transaction { transaction -> [PeerId] in
        GoldgramBackgroundRefreshTrace.phase(diagnosticToken, "postbox_entered")
        guard goldgramNativeHistoryEnabled(),
              goldgramCaptureEnabled(accountPeerId: account.peerId, transaction: transaction) else {
            GoldgramBackgroundRefreshTrace.phase(diagnosticToken, "capture_disabled")
            GoldgramBackgroundRefreshTrace.targets(diagnosticToken,
                accountId: account.peerId.id._internalGetInt64Value(), count: 0)
            return []
        }
        goldgramDrainPending(accountPeerId: account.peerId, transaction: transaction)
        let selected = goldgramPrioritySelection(transaction: transaction,
            accountPeerId: account.peerId)
        let ordered = Array(selected.peers.reversed())
        let ids = goldgramFullCaptureLabEnabled(accountPeerId: account.peerId)
            ? Array(ordered.prefix(6)) : Array(ordered.prefix(3))
        GoldgramBackgroundRefreshTrace.targets(diagnosticToken,
            accountId: account.peerId.id._internalGetInt64Value(), count: ids.count)
        GoldgramBackgroundRefreshTrace.selection(diagnosticToken,
            stored: selected.stored,
            rejectedPeer: selected.rejectedPeer,
            rejectedLink: selected.rejectedLink,
            rejectedGroup: selected.rejectedGroup,
            rejectedAccess: selected.rejectedAccess)
        return ids
    }
    |> mapToSignal { ids -> Signal<Never, NoError> in
        // #127 LAB: run pinned discussions in parallel so a stalled request
        // cannot starve other targets during the scarce OS execution window.
        if goldgramFullCaptureLabEnabled(accountPeerId: account.peerId), !ids.isEmpty {
            let differences: [Signal<Bool, NoError>] = ids.map { id in
                return Signal { subscriber in
                    GoldgramBackgroundRefreshTrace.request(diagnosticToken)
                    let disposable = standalonePollChannelOnce(
                        accountPeerId: account.peerId, postbox: account.postbox,
                        network: account.network, peerId: id,
                        stateManager: account.stateManager,
                        diagnosticToken: diagnosticToken
                    ).start(completed: {
                        GoldgramBackgroundRefreshTrace.completedRequest(diagnosticToken)
                        subscriber.putNext(true)
                        subscriber.putCompletion()
                    })
                    return ActionDisposable { disposable.dispose() }
                }
            }
            let history: [Signal<Bool, NoError>] = ids.prefix(3).map { id in
                return Signal { subscriber in
                    GoldgramBackgroundRefreshTrace.labHistory(diagnosticToken, finished: false)
                    let disposable = goldgramSeedDiscussion(
                        account: account, peerId: id, labOnly: true).start(completed: {
                            GoldgramBackgroundRefreshTrace.labHistory(diagnosticToken, finished: true)
                            subscriber.putNext(true)
                            subscriber.putCompletion()
                        })
                    return ActionDisposable { disposable.dispose() }
                }
            }
            return combineLatest(differences + history) |> ignoreValues
        }
        // Original non-experimental sequential behavior unchanged.
        let differences = ids.reduce(Signal<Never, NoError>.complete()) { previous, id in
            let polled: Signal<Never, NoError> = Signal { subscriber in
                GoldgramBackgroundRefreshTrace.request(diagnosticToken)
                let disposable = standalonePollChannelOnce(
                    accountPeerId: account.peerId, postbox: account.postbox,
                    network: account.network, peerId: id,
                    stateManager: account.stateManager,
                    diagnosticToken: diagnosticToken
                ).start(completed: {
                    GoldgramBackgroundRefreshTrace.completedRequest(diagnosticToken)
                    subscriber.putCompletion()
                })
                return ActionDisposable {
                    disposable.dispose()
                }
            }
            return previous |> then(polled)
        }
        guard let first = ids.first else { return .complete() }
        let history = goldgramSeedDiscussion(account: account, peerId: first, labOnly: true)
        return combineLatest((differences |> map { _ -> Bool in true }) |> then(.single(true)), (history |> map { _ -> Bool in true }) |> then(.single(true))) |> ignoreValues
    }
}

// #135: the old geo probe always sampled the same two pinned histories.
// Reuse already-known recent peers and validated linked discussions. Keep one
// user-pinned discussion first; rotate other eligible dialogs between actual
// iOS-granted location wakes. No new joins, subscriptions or background timers.
// One sensor wake: at most four 100-message history reads and four channel
// difference requests, with the existing 18-second cancellation in AppDelegate.
private func goldgramGeoRotatingTargets(transaction: Transaction, accountPeerId: PeerId) -> [PeerId] {
    let now = Int64(Date().timeIntervalSince1970)
    var eligible = goldgramPriorityPeers(transaction: transaction, accountPeerId: accountPeerId)
    let recent = transaction.retrieveItemCacheEntry(id: goldgramDiscussionTargetsKey)?
        .get(GoldgramDiscussionTargets.self)?.items ?? []
    for item in recent where item.seen <= now && now - item.seen < 86400 {
        let id = PeerId(item.peer)
        guard !eligible.contains(id), let peer = transaction.getPeer(id),
              goldgramKind(id, peer) != nil, apiInputPeer(peer) != nil else { continue }
        eligible.append(id)
    }
    guard !eligible.isEmpty else { return [] }
    let fixed = Array(eligible.prefix(1))
    let extras = Array(eligible.dropFirst())
    guard !extras.isEmpty else { return fixed }
    let key = "GoldgramGeoRotationV135.\(accountPeerId.id._internalGetInt64Value())"
    let defaults = UserDefaults.standard
    let position = (defaults.integer(forKey: key) % extras.count + extras.count) % extras.count
    let rotated = (0..<extras.count).map { extras[(position + $0) % extras.count] }
    let slots = 4 - fixed.count
    let selected = fixed + Array(rotated.prefix(slots))
    // Advances by the number of actual rotating slots, even if only one
    // attempt is run. A subsequent wake visits previously skipped peers.
    defaults.set((position + min(slots, extras.count)) % extras.count, forKey: key)
    return selected
}

// #128/#135: genuine iOS-awake geo lab only, now up to 4 mixed known dialogs.
// Never treat a current edited snapshot as a missing original.
public func goldgramLocationLabPoll(account: Account, traceToken: String) -> Signal<Never, NoError> {
    return account.postbox.transaction { transaction -> [PeerId] in
        goldgramDrainPending(accountPeerId: account.peerId, transaction: transaction)
        guard goldgramNativeHistoryEnabled() else { return [] }
        return goldgramGeoRotatingTargets(transaction: transaction,
            accountPeerId: account.peerId)
    }
    |> mapToSignal { ids -> Signal<Never, NoError> in
        GoldgramLocationLabTrace.targets(traceToken, count: ids.count)
        guard !ids.isEmpty else { return .complete() }
        // CloudUser/CloudGroup do not use channel getDifference. They are
        // still eligible for safe, bounded getHistory baselines below.
        let channelIds = ids.filter { $0.namespace == Namespaces.Peer.CloudChannel }
        let polls: [Signal<Bool, NoError>] = channelIds.map { id in
            return Signal { subscriber in
                let disposable = standalonePollChannelOnce(
                    accountPeerId: account.peerId, postbox: account.postbox,
                    network: account.network, peerId: id,
                    stateManager: account.stateManager,
                    locationTraceToken: traceToken
                ).start(completed: {
                    GoldgramLocationLabTrace.rpcComplete(traceToken)
                    subscriber.putNext(true)
                    subscriber.putCompletion()
                })
                return ActionDisposable { disposable.dispose() }
            }
        }
        let snapshots: [Signal<Bool, NoError>] = ids.prefix(4).map { id in
            return Signal { subscriber in
                let disposable = goldgramSeedDiscussion(account: account, peerId: id,
                    labOnly: true, locationTraceToken: traceToken).start(completed: {
                        subscriber.putNext(true)
                        subscriber.putCompletion()
                    })
                return ActionDisposable { disposable.dispose() }
            }
        }
        return combineLatest(polls + snapshots) |> ignoreValues
    }
}

// The UI owns this subscription while the selected account is the active
// service master, including native background execution / push wake windows.
// Stop polling when iOS execution time ends or the account switches.
public func goldgramMonitorDiscussions(account: Account) -> Signal<Never, NoError> {
    return Signal { _ in
        let queue = Queue(name: "GoldgramDiscussionMonitor")
        let impl = QueueLocalObject(queue: queue, generate: { GoldgramDiscussionMonitor(account: account, queue: queue) })
        return ActionDisposable { impl.with { $0.stop() } }
    }
}
