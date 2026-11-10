#!/usr/bin/env python3
"""Execute AppDelegate's actual refresh completion closure with Swift test doubles."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


root = Path(__file__).resolve().parents[2]
source = (root / "submodules/TelegramUI/Sources/AppDelegate.swift").read_text()
refresh = source.split("private func goldgramRunRefresh(", 1)[1]
completion = refresh.split("        let complete: (String, Bool) -> Void", 1)[1].split(
    "        self.goldgramRefreshFinish = complete", 1
)[0]
completion = "        let complete: (String, Bool) -> Void" + completion

assert "[weak self, task] reason, success in" in completion
assert "task?.setTaskCompleted" not in completion
system_finish = completion.split("let finishSystemTask =", 1)[1].split(
    'if finished && reason == "ios_expiration"', 1
)[0]
assert system_finish.index("task.expirationHandler = nil") < system_finish.index(
    "task.setTaskCompleted(success: success)"
)
assert "self.goldgramRefreshActiveToken == token" in system_finish
assert completion.count("self.goldgramRefreshActive = false") == 1
assert "guard !finished, self.goldgramRefreshActiveToken == token" in refresh
assert "if !finished && self.goldgramRefreshActiveToken == token" in refresh

fixtures = r'''
import Foundation

final class Task {
    var expirationHandler: (() -> Void)?
    var results: [Bool] = []
    func setTaskCompleted(success: Bool) { results.append(success) }
}
final class Work {
    func set(_ value: Any?) {}
}
final class Lease {
    private var release: (() -> Void)?
    init(_ release: @escaping () -> Void) { self.release = release }
    func dispose() {
        let release = self.release
        self.release = nil
        release?()
    }
}
final class SharedWakeupManager {
    var synchronous = false
    var pending: [() -> Void] = []
    func onRefreshLeaseRelease(token: String, completion: @escaping () -> Void) -> Bool {
        pending.append(completion)
        return true
    }
    func release() { if synchronous { drain() } }
    func drain() {
        let callbacks = pending
        pending.removeAll()
        for callback in callbacks { callback() }
    }
}
enum GoldgramProcessJournal { static func record(_ text: String) {} }
enum GoldgramBackgroundRefreshTrace {
    static func finish(_ token: String, reason: String) {}
    static func leaseReleased(_ token: String) {}
}
final class UserDefaults {
    static let standard = UserDefaults()
    func set(_ value: Double, forKey: String) {}
}
final class Owner {
    var goldgramRefreshActive = true
    var goldgramRefreshActiveToken: String? = "old"
    var goldgramRefreshActiveSince: Date? = Date()
    var goldgramRefreshFinish: ((String, Bool) -> Void)?
    let goldgramRefreshWork = Work()
    var goldgramRefreshLease: Lease?
    let manager = SharedWakeupManager()

    func install(_ task: Task, hasLease: Bool = true) {
        let token = "old"
        weak var leaseManager: SharedWakeupManager? = self.manager
        var finished = false
        var systemTaskCompleted = false
        if hasLease { goldgramRefreshLease = Lease { [manager] in manager.release() } }
        /* ACTUAL_COMPLETION */
        self.goldgramRefreshFinish = complete
        task.expirationHandler = { complete("ios_expiration", false) }
    }
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

// The task stays active while Postbox/archive drain. A repeated completion is harmless.
do {
    let owner = Owner(), task = Task()
    owner.install(task)
    owner.goldgramRefreshFinish?("completed", true)
    expect(owner.goldgramRefreshActive, "Drain lost refresh ownership")
    expect(task.results.isEmpty, "Task completed before drain")
    owner.goldgramRefreshFinish?("goldgram_deadline", false)
    owner.manager.drain()
    expect(task.results == [true], "Deferred completion must run exactly once")
    expect(!owner.goldgramRefreshActive, "Drained task still active")
    expect(task.expirationHandler == nil, "Expiration cycle retained")
}
// Another execution window can finish the handoff synchronously from lease.dispose().
do {
    let owner = Owner(), task = Task()
    owner.manager.synchronous = true
    owner.install(task)
    owner.goldgramRefreshFinish?("completed", true)
    expect(task.results == [true], "Inline completion lost")
    expect(owner.goldgramRefreshFinish == nil, "Inline completion retained")
}
// Expiration wins over a pending successful drain and late callbacks cannot affect a new token.
do {
    let owner = Owner(), task = Task()
    owner.install(task)
    let oldCompletion = owner.goldgramRefreshFinish!
    oldCompletion("completed", true)
    task.expirationHandler?()
    expect(task.results == [false], "Expiration failed to complete task")
    owner.goldgramRefreshActive = true
    owner.goldgramRefreshActiveToken = "new"
    oldCompletion("goldgram_deadline", false)
    owner.manager.drain()
    expect(task.results == [false], "Task completed twice")
    expect(owner.goldgramRefreshActiveToken == "new", "Old callback cleared new token")
    expect(owner.goldgramRefreshActive, "Old callback cleared new task")
}
// No-account and owner-deallocation paths still complete the actual system task.
do {
    let owner = Owner(), task = Task()
    owner.install(task, hasLease: false)
    owner.goldgramRefreshFinish?("no_account", false)
    expect(task.results == [false], "No-account task leaked")
}
do {
    var owner: Owner? = Owner()
    let task = Task()
    owner!.install(task)
    owner = nil
    task.expirationHandler?()
    expect(task.results == [false], "Owner-deallocation task leaked")
}
// Dropping the launch-handler argument must not deallocate the task during its drain.
do {
    let owner = Owner()
    var task: Task? = Task()
    weak var weakTask: Task? = task
    owner.install(task!)
    task = nil
    expect(weakTask != nil, "System task was only weakly retained")
    owner.goldgramRefreshFinish?("goldgram_deadline", false)
    expect(weakTask != nil, "Task released before drain completed")
    owner.manager.drain()
    expect(weakTask == nil, "Completed task retained in a cycle")
}
print("Refresh task lifecycle: six Swift scenarios passed")
'''

parser = argparse.ArgumentParser()
parser.add_argument("--require-swift", action="store_true")
args = parser.parse_args()
swift = shutil.which("swift")
if swift is None:
    if args.require_swift:
        raise SystemExit("Swift is required for refresh lifecycle tests")
    print("Refresh source checks passed; Swift execution unavailable on this host")
else:
    with tempfile.TemporaryDirectory() as directory:
        harness = Path(directory) / "RefreshLifecycle.swift"
        harness.write_text(fixtures.replace("/* ACTUAL_COMPLETION */", completion))
        subprocess.run([swift, "-swift-version", "5", str(harness)], check=True, timeout=60)
