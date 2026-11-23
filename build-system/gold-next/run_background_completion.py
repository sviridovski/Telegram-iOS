#!/usr/bin/env python3
"""Test the production asynchronous flush with real SwiftSignalKit scheduling.

The writer is held behind a semaphore to model a busy SQLite serial queue.
The app main queue must remain responsive and cancellation must suppress late
completion. No duplicated Signal implementation or network/account is used.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
core = (root / 'submodules/TelegramCore/Sources/State/GoldgramNativeHistory.swift').read_text()
app = (root / 'submodules/TelegramUI/Sources/AppDelegate.swift').read_text()
helper = core.split('private let goldgramOriginalFlushQueue =', 1)[1].split(
    'private func goldgramSavedOriginal(', 1)[0]
helper = 'private let goldgramOriginalFlushQueue =' + helper
assert 'goldgramFlushOriginalCapture()' not in app
assert app.count('goldgramFlushOriginalCaptureAsync()') == 2
assert 'goldgramRefreshWork.set(work)' in app
bg = app.split('private func goldgramRunRefresh(', 1)[1].split(
    'private var clearNotificationsManager', 1)[0]
cleanup = bg.split('let complete: (String, Bool)', 1)[1].split('self.goldgramRefreshFinish = complete', 1)[0]
assert 'flush' not in cleanup.lower(), 'Expiry cleanup must never wait for the writer'
assert 'self.goldgramRefreshWork.set(nil)' in cleanup
assert 'task.setTaskCompleted(success: success)' in cleanup
assert 'task?.setTaskCompleted' not in cleanup, 'Retain the system task until completion'
assert 'guard !systemTaskCompleted else { return }' in cleanup
assert 'task.expirationHandler = { complete("ios_expiration", false) }' in bg
assert 'goldgramRefreshActiveToken == token' in bg
assert 'then(Signal<Never, NoError>' in bg
reason = '    private func goldgramRefreshCompletionReason(' + app.split(
    '    private func goldgramRefreshCompletionReason(', 1)[1].split(
    '    private var clearNotificationsManager', 1)[0]
stubs = r'''
import Foundation
let writer = Atomic<() -> Bool>(value: { true })
func goldgramFlushOriginalCapture() -> Bool {
    precondition(!Thread.isMainThread, "blocking writer fence must never run on main")
    let flush = writer.with { $0 }
    return flush()
}
struct Sample {
    var phase: String?
    var storedPinned: Int?
    var targets = 0
    var requests = 0
    var completed = 0
}
enum GoldgramBackgroundRefreshTrace {
    static var sample: Sample?
    static func find(_ token: String) -> Sample? { sample }
}
final class CompletionFixture {
    func reason() -> String { goldgramRefreshCompletionReason(for: "test") }
'''
checks = r'''
func spin(until predicate: () -> Bool, seconds: Double = 2.0) {
    let deadline = Date().addingTimeInterval(seconds)
    while !predicate() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    precondition(predicate(), "main queue timed out")
}
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
let writerDone = DispatchSemaphore(value: 0)
let work = MetaDisposable()
let _ = writer.swap({
    entered.signal()
    precondition(release.wait(timeout: .now() + 5.0) == .success)
    writerDone.signal()
    return true
})
var lateCompletion = false
work.set((goldgramFlushOriginalCaptureAsync()
    |> deliverOn(Queue.mainQueue())).start(next: { _ in lateCompletion = true },
                                         completed: { lateCompletion = true }))
precondition(entered.wait(timeout: .now() + 2.0) == .success)
// Model an OS expiry arriving while the SQLite fence is still blocked.
var expired = false
DispatchQueue.main.async {
    let started = ProcessInfo.processInfo.systemUptime
    work.set(nil)
    precondition(ProcessInfo.processInfo.systemUptime - started < 0.5)
    expired = true
}
spin(until: { expired })
precondition(!lateCompletion)
release.signal()
precondition(writerDone.wait(timeout: .now() + 2.0) == .success)
let workerDrained = DispatchSemaphore(value: 0)
goldgramOriginalFlushQueue.async { workerDrained.signal() }
precondition(workerDrained.wait(timeout: .now() + 2.0) == .success)
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
precondition(!lateCompletion, "expired work must not finish again after the fence releases")

// A normal task still completes only after the writer confirms its fence.
var normalCompletion = false
let committed = Atomic<Bool>(value: false)
let _ = writer.swap({
    let _ = committed.swap(true)
    return true
})
let normal = (goldgramFlushOriginalCaptureAsync()
    |> deliverOn(Queue.mainQueue())).start(next: { confirmed in
        precondition(Thread.isMainThread && confirmed && committed.with { $0 })
    }, completed: { normalCompletion = true })
spin(until: { normalCompletion })
normal.dispose()

// Cancellation before a queued fence starts must not invoke the writer.
let queueEntered = DispatchSemaphore(value: 0)
let queueRelease = DispatchSemaphore(value: 0)
goldgramOriginalFlushQueue.async {
    queueEntered.signal()
    precondition(queueRelease.wait(timeout: .now() + 5.0) == .success)
}
precondition(queueEntered.wait(timeout: .now() + 2.0) == .success)
let called = Atomic<Bool>(value: false)
let _ = writer.swap({ let _ = called.swap(true); return true })
let queued = goldgramFlushOriginalCaptureAsync().start()
queued.dispose()
queueRelease.signal()
let queuedDrained = DispatchSemaphore(value: 0)
goldgramOriginalFlushQueue.async { queuedDrained.signal() }
precondition(queuedDrained.wait(timeout: .now() + 2.0) == .success)
precondition(!called.with { $0 })

let completion = CompletionFixture()
GoldgramBackgroundRefreshTrace.sample = nil
precondition(completion.reason() == "postbox_unreached")
GoldgramBackgroundRefreshTrace.sample = Sample(phase: "capture_disabled")
precondition(completion.reason() == "capture_disabled")
GoldgramBackgroundRefreshTrace.sample = Sample(storedPinned: 0)
precondition(completion.reason() == "no_targets")
GoldgramBackgroundRefreshTrace.sample = Sample(storedPinned: 1)
precondition(completion.reason() == "targets_unavailable")
GoldgramBackgroundRefreshTrace.sample = Sample(storedPinned: 1, targets: 1, requests: 2, completed: 1)
precondition(completion.reason() == "incomplete_requests")
GoldgramBackgroundRefreshTrace.sample = Sample(storedPinned: 1, targets: 1, requests: 2, completed: 2)
precondition(completion.reason() == "completed")
print("Goldgram background completion: real SignalKit main responsiveness, expiry cancellation, fence order and reasons OK")
'''
with tempfile.TemporaryDirectory(prefix='goldgram-bg-completion-') as temp:
    work = Path(temp)
    main = work / 'main.swift'
    main.write_text(stubs + reason + '}\n' + helper + checks)
    sources = sorted((root / 'submodules/SSignalKit/SwiftSignalKit/Source').glob('*.swift'))
    executable = work / 'completion'
    subprocess.run(['swiftc', *map(str, sources), str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=20)
