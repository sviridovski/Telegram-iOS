"""Run the shipped UIKit-window coordinator with deterministic timers/queue fences."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "submodules/TelegramUI/Sources/SharedWakeupManager.swift").read_text()
window = src[src.index("    private final class BackgroundWindow"):src.index("    private var enableBackgroundTasks")]
methods = src[src.index("    private func startWindow("):]
source = """
import Foundation
import CoreFoundation
typealias UIBackgroundTaskIdentifier = Int
enum SwiftSignalKit {
    final class Timer {
        let fire: () -> Void
        init(timeout: Double, repeat: Bool, completion: @escaping () -> Void, queue: Queue) { fire = completion }
        func start() {}
        func invalidate() {}
    }
}
class Queue { static func mainQueue() -> Queue { Queue() } }
enum GoldgramProcessJournal { static func record(_ event: String) {} }
class Logger { static let shared = Logger(); func log(_ a: String, _ b: String) {} }
enum Policy { case always, never }
enum Signal<T> { case single(T) }
class Pipe<T> { func set(_ value: Signal<T>) {} }
struct Important { var pendingMessageCount = 0; var pendingStoryCount = 0 }
struct Tasks {
    var activeCalls = false, backgroundLocation = false, backgroundAudio = false, backgroundDownloads = false
    var isEmpty = true, importantTasks = Important()
}
class Postbox {
    var allowed = true
    var fences: [() -> Void] = []
    func setCanBeginTransactions(_ open: Bool, afterTransactionIfRunning: @escaping () -> Void = {}) {
        allowed = open
        if !open { fences.append(afterTransactionIfRunning) }
    }
    func drain() { let fs = fences; fences.removeAll(); fs.forEach { $0() } }
}
class Account {
    let id = 1, postbox = Postbox()
    let shouldKeepOnlinePresence = Pipe<Bool>(), shouldBeServiceTaskMaster = Pipe<Policy>()
    let shouldExplicitelyKeepWorkerConnections = Pipe<Bool>(), shouldKeepBackgroundDownloadConnections = Pipe<Bool>()
}
class Disposable { func dispose() {} }
var archiveOpen = true
var archiveFences: [() -> Void] = []
func goldgramSetArchiveAdmission(_ open: Bool, immediately: Bool = false) { archiveOpen = open }
func goldgramArchiveBarrier(_ done: @escaping () -> Void) { archiveFences.append(done) }
final class Manager {
    var accountsAndTasks: [(Account, Bool, Tasks)] = []
    var inForeground = true, hasActiveAudioSession = false, isInBackgroundExtension = false
    var backgroundProcessingTaskLaunched = false, backgroundStoryProcessingTaskLaunched = false
    var goldgramRefreshLeaseToken: String?, goldgramRefreshLeaseAccountId: Int?, goldgramLocationLeaseAccountId: Int?
    var silenceAudioRenderer: Int?, keepIdleDisposable: Disposable?
    func acquireIdleExtension() -> Disposable? { nil }
    var allowBackgroundTimeExtensionDeadline: Double?
    var currentExternalCompletion: (() -> Void, SwiftSignalKit.Timer)?
    var currentExternalCompletionValidationTimer: SwiftSignalKit.Timer?
    private var currentTask: BackgroundWindow?, explicitWindow: BackgroundWindow?
    var expirations: [() -> Void] = [], ended: [Int] = []
    func beginBackgroundTask(_ name: String, _ expire: @escaping () -> Void) -> Int? {
        expirations.append(expire); return expirations.count
    }
    func endBackgroundTask(_ id: Int) { ended.append(id) }
    func backgroundTimeRemaining() -> Double { 30 }
    func startExplicit() { explicitWindow = startWindow("explicit-extension", timeout: 20); checkTasks() }
    func finishExplicit() { explicitWindow!.timer!.fire() }
    func finishWake() { currentTask!.timer!.fire() }
""" + window + methods + """
func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
func drainArchive() { let fs = archiveFences; archiveFences.removeAll(); fs.forEach { $0() }; pump() }
let manager = Manager(), a = Account(), b = Account()
manager.accountsAndTasks = [(a,true,Tasks()),(b,false,Tasks())]
manager.checkTasks()
manager.inForeground = false
manager.accountsAndTasks[0].2.isEmpty = false
manager.allowBackgroundTimeExtensionDeadline = CFAbsoluteTimeGetCurrent() + 20
manager.startExplicit()
precondition(manager.expirations.count == 2)
manager.finishExplicit()
precondition(manager.ended == [1] && a.postbox.allowed)
manager.finishWake()
precondition(!a.postbox.allowed && !b.postbox.allowed)
a.postbox.drain(); pump()
precondition(manager.ended == [1] && archiveFences.isEmpty)
b.postbox.drain(); pump()
precondition(!archiveOpen && manager.ended == [1])
drainArchive()
precondition(manager.ended == [1,2])
manager.expirations[1]()
precondition(manager.ended == [1,2])
manager.goldgramRefreshLeaseToken = "system-refresh"; manager.checkTasks()
precondition(archiveOpen && a.postbox.allowed)
manager.startExplicit()
manager.goldgramRefreshLeaseToken = nil
manager.finishExplicit() // both queues are still busy
manager.expirations[2]()
precondition(!archiveOpen && manager.ended == [1,2,3])
manager.inForeground = true; manager.checkTasks()
a.postbox.drain(); b.postbox.drain(); pump(); drainArchive()
precondition(archiveOpen && a.postbox.allowed && manager.ended == [1,2,3])
"""
with tempfile.TemporaryDirectory() as temporary:
    main = Path(temporary) / "main.swift"
    main.write_text(source)
    binary = Path(temporary) / "window-test"
    subprocess.run(["swiftc", main, "-o", binary], check=True)
    subprocess.run([binary], check=True)
