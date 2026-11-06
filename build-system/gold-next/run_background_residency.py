#!/usr/bin/env python3
"""Run connection-lease and image-cache lifecycles from production Swift in macOS CI.

Only framework dependencies are stubbed. The lease methods, cache storage,
notification observers and cleanup are extracted unchanged from app sources.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
wakeup = (root / 'submodules/TelegramUI/Sources/SharedWakeupManager.swift').read_text()
app = (root / 'submodules/TelegramUI/Sources/AppDelegate.swift').read_text()
cache = (root / 'submodules/TelegramPresentationData/Sources/PresentationsResourceCache.swift').read_text()
lease = wakeup.split('    func acquireGoldgramLocationLease(', 1)[1].split(
    '    // #111:', 1)[0]
lease = '    func acquireGoldgramLocationLease(' + lease
# Production gates must keep this account active independently of short polls.
assert '|| self.goldgramLocationLeaseAccountId != nil ||' in wakeup
assert wakeup.count('|| self.goldgramLocationLeaseAccountId == account.id') == 2
assert 'account.shouldKeepOnlinePresence.set(.single(primary && self.inForeground))' in wakeup
assert 'shouldKeepOnlinePresence' not in lease
assert 'guard enabled != self.goldgramLocationSessionRunning' in app
assert 'self.goldgramLocationSession.set(nil)' in app
assert 'primary?.account.id' in app and '|> distinctUntilChanged' in app
assert 'self.onRunningChanged(false)' in app and 'self.onRunningChanged(true)' in app
assert 'if (error as? CLError)?.code == .locationUnknown { return }' in app
assert app.count('taskIdHolder.taskId = nil') == 2

stubs = r'''
import Foundation
public final class UIImage {}
public final class PresentationTheme {}
public struct PresentationResourceParameterKey: Hashable { let value: Int }
enum UIApplication {
    static let didEnterBackgroundNotification = Notification.Name("background-fixture")
    static let didReceiveMemoryWarningNotification = Notification.Name("memory-fixture")
}
final class Atomic<T> {
    private let lock = NSLock()
    private var value: T
    init(value: T) { self.value = value }
    func with<R>(_ body: (T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(value)
    }
    func swap(_ value: T) -> T {
        lock.lock()
        defer { lock.unlock() }
        let previous = self.value
        self.value = value
        return previous
    }
}
protocol Disposable { func dispose() }
final class ActionDisposable: Disposable {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func dispose() { let action = self.action; self.action = nil; action?() }
}
struct AccountRecordId: Equatable { let value: Int64 }
final class Queue {
    static func mainQueue() -> Queue { Queue() }
    func isCurrent() -> Bool { Thread.isMainThread }
    func async(_ body: @escaping () -> Void) { DispatchQueue.main.async(execute: body) }
}
final class LeaseFixture {
    var goldgramLocationLeaseToken: String?
    var goldgramLocationLeaseAccountId: AccountRecordId?
    var taskChecks = 0
    func checkTasks() { taskChecks += 1 }
'''
checks = r'''
let manager = LeaseFixture()
let first = manager.acquireGoldgramLocationLease(accountId: AccountRecordId(value: 1))
precondition(manager.goldgramLocationLeaseAccountId?.value == 1)
let switched = manager.acquireGoldgramLocationLease(accountId: AccountRecordId(value: 2))
first.dispose()
precondition(manager.goldgramLocationLeaseAccountId?.value == 2,
             "stale account cleanup must not release the newer account")
precondition(manager.taskChecks == 2)
switched.dispose()
precondition(manager.goldgramLocationLeaseAccountId == nil)
precondition(manager.goldgramLocationLeaseToken == nil && manager.taskChecks == 3)
switched.dispose()
precondition(manager.taskChecks == 3, "release must be idempotent")

let theme = PresentationTheme()
var images: PresentationsResourceCache? = PresentationsResourceCache()
weak var regular: UIImage?
weak var parameter: UIImage?
let key = PresentationResourceParameterKey(value: 1)
func populate() {
    regular = images!.image(1, theme) { _ in UIImage() }
    parameter = images!.parameterImage(key, theme) { _ in UIImage() }
}
populate()
precondition(regular != nil && parameter != nil, "cache must retain both variants")
NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
precondition(regular == nil && parameter == nil, "background must release cached images")
populate()
precondition(regular != nil && parameter != nil, "images must regenerate after cleanup")
NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
precondition(regular == nil && parameter == nil, "memory pressure must also release images")
// A displayed image retains its own reference after cache cleanup.
let displayed = images!.image(2, theme) { _ in UIImage() }!
NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
let regenerated = images!.image(2, theme) { _ in UIImage() }!
precondition(displayed !== regenerated)
weak var releasedCache = images
images = nil
precondition(releasedCache == nil, "notification observers must not retain caches")
NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
print("Goldgram background residency: account switch, stale release, cache eviction and regeneration OK")
'''
source = stubs + lease + '}\n' + cache.replace('import UIKit', '').replace('import SwiftSignalKit', '') + checks
with tempfile.TemporaryDirectory(prefix='goldgram-background-') as temp:
    main = Path(temp) / 'main.swift'
    main.write_text(source)
    binary = Path(temp) / 'background-test'
    subprocess.run(['swiftc', str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
