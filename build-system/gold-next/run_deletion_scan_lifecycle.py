#!/usr/bin/env python3
"""Run extracted production scheduler/permit with real SwiftSignalKit.

Storage/network stages below are controlled test doubles, not a real account
or Postbox database. This does not reproduce or prove the iPhone crash cause.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
source = (root / 'submodules/TelegramCore/Sources/State/GoldgramNativeHistory.swift').read_text()


def extract(start):
    begin = source.index(start)
    end = source.index('{', begin) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[begin:end]


production = '\n'.join(extract(start) for start in [
    'private final class GoldgramDeletionScanPermit',
    'private func goldgramDeletionScanAttempt(',
    'private func goldgramDeletionScanSession(',
])
assert 'guard enabled, active else' in production
assert production.count('switchToLatest') == 2
assert 'let cancelled = permit.cancel()' in production
swiftc = shutil.which('swiftc')
if not swiftc:
    if args.require_swift:
        raise SystemExit('Swift compiler required for lifecycle execution')
    print('Deletion lifecycle: source checks passed; Swift execution NOT run on this host')
    raise SystemExit(0)

cases = r'''
import Foundation
import SwiftSignalKit

func wait(_ semaphore: DispatchSemaphore, _ label: String) {
    precondition(semaphore.wait(timeout: .now() + 3.0) == .success, label)
}
func fence(_ queue: Queue) {
    let done = DispatchSemaphore(value: 0)
    queue.async { done.signal() }
    wait(done, "queue fence")
}

// Disabled release gate: no timer work may reach storage or the network.
do {
    let queue = Queue(name: "scan-disabled")
    let calls = Atomic(value: 0)
    let work = goldgramDeletionScanSession(foreground: .single(true), queue: queue,
        enabled: false, initialDelay: 0.01, interval: 0.02, deadline: 0.01,
        scan: { _ = calls.modify { $0 + 1 }; return .complete() }).start()
    Thread.sleep(forTimeInterval: 0.08)
    work.dispose(); fence(queue)
    precondition(calls.with { $0 } == 0)
}

// Real timer -> controlled storage -> RPC -> archive callback; no early run.
do {
    let queue = Queue(name: "scan-completed")
    let done = DispatchSemaphore(value: 0)
    let events = Atomic(value: [String]())
    let cancelled = Atomic(value: 0)
    let began = ProcessInfo.processInfo.systemUptime
    let work = goldgramDeletionScanSession(foreground: .single(true), queue: queue,
        enabled: true, initialDelay: 0.04, interval: 1.0, deadline: 1.0, scan: {
            precondition(ProcessInfo.processInfo.systemUptime - began >= 0.035)
            return goldgramDeletionScanAttempt(work: { permit in
                return Signal { subscriber in
                    queue.async {
                        guard permit.isActive else { return }
                        _ = events.modify { $0 + ["postbox"] }
                        queue.after(0.005) {
                            guard permit.isActive else { return }
                            _ = events.modify { $0 + ["rpc"] }
                            queue.after(0.005) {
                                guard permit.isActive else { return }
                                _ = events.modify { $0 + ["archive"] }
                                subscriber.putCompletion()
                                done.signal()
                            }
                        }
                    }
                    return EmptyDisposable
                }
            }, onCancel: { _ = cancelled.modify { $0 + 1 } })
        }).start()
    wait(done, "three-stage completion")
    work.dispose(); fence(queue)
    precondition(events.with { $0 } == ["postbox", "rpc", "archive"])
    precondition(cancelled.with { $0 } == 0, "completion is not cancellation")
}

// Foreground loss before the first timer cancels the timer, not just its RPC.
do {
    let queue = Queue(name: "scan-before-first")
    let active = ValuePromise<Bool>(true, ignoreRepeated: true)
    let calls = Atomic(value: 0)
    let work = goldgramDeletionScanSession(foreground: active.get(), queue: queue,
        enabled: true, initialDelay: 0.1, interval: 1.0, deadline: 0.1,
        scan: { _ = calls.modify { $0 + 1 }; return .complete() }).start()
    active.set(false); fence(queue)
    Thread.sleep(forTimeInterval: 0.15)
    work.dispose(); fence(queue)
    precondition(calls.with { $0 } == 0)
}

// Deadline disposes a hung request exactly once.
do {
    let queue = Queue(name: "scan-deadline")
    let done = DispatchSemaphore(value: 0)
    let disposed = Atomic(value: 0)
    let cancelled = Atomic(value: 0)
    let work = goldgramDeletionScanSession(foreground: .single(true), queue: queue,
        enabled: true, initialDelay: 0.01, interval: 1.0, deadline: 0.03, scan: {
            goldgramDeletionScanAttempt(work: { _ in
                Signal { _ in
                    ActionDisposable { _ = disposed.modify { $0 + 1 }; done.signal() }
                }
            }, onCancel: { _ = cancelled.modify { $0 + 1 } })
        }).start()
    wait(done, "request deadline"); fence(queue)
    work.dispose(); fence(queue)
    precondition(disposed.with { $0 } == 1 && cancelled.with { $0 } == 1)
}

// A late continuation already queued by the RPC cannot write after background.
do {
    let queue = Queue(name: "scan-late-response")
    let active = ValuePromise<Bool>(true, ignoreRepeated: true)
    let started = DispatchSemaphore(value: 0)
    let late = DispatchSemaphore(value: 0)
    let writes = Atomic(value: 0)
    let work = goldgramDeletionScanSession(foreground: active.get(), queue: queue,
        enabled: true, initialDelay: 0.01, interval: 1.0, deadline: 1.0, scan: {
            goldgramDeletionScanAttempt(work: { permit in
                Signal { _ in
                    started.signal()
                    queue.after(0.06) {
                        if permit.isActive { _ = writes.modify { $0 + 1 } }
                        late.signal()
                    }
                    return EmptyDisposable
                }
            }, onCancel: {})
        }).start()
    wait(started, "request start")
    active.set(false); fence(queue)
    wait(late, "late callback")
    work.dispose(); fence(queue)
    precondition(writes.with { $0 } == 0)
}

// Account-owner disposal revokes the old account before its queued callback.
do {
    let queue = Queue(name: "scan-account-switch")
    let started = DispatchSemaphore(value: 0)
    let late = DispatchSemaphore(value: 0)
    let writes = Atomic(value: [String]())
    func session(_ account: String) -> Signal<Never, NoError> {
        goldgramDeletionScanSession(foreground: .single(true), queue: queue,
            enabled: true, initialDelay: 0.01, interval: 1.0, deadline: 1.0, scan: {
                goldgramDeletionScanAttempt(work: { permit in
                    Signal { subscriber in
                        started.signal()
                        queue.after(0.06) {
                            if permit.isActive {
                                _ = writes.modify { $0 + [account] }
                                subscriber.putCompletion()
                            }
                            late.signal()
                        }
                        return EmptyDisposable
                    }
                }, onCancel: {})
            })
    }
    let old = session("A").start()
    wait(started, "old account start")
    old.dispose(); fence(queue)
    let current = session("B").start()
    wait(started, "new account start")
    wait(late, "old late response"); wait(late, "new response")
    current.dispose(); fence(queue)
    precondition(writes.with { $0 } == ["B"])
}

// Slow requests do not accumulate between ticks, even if deadline > interval.
do {
    let queue = Queue(name: "scan-no-overlap")
    let started = DispatchSemaphore(value: 0)
    let counts = Atomic(value: (active: 0, maximum: 0))
    let work = goldgramDeletionScanSession(foreground: .single(true), queue: queue,
        enabled: true, initialDelay: 0.01, interval: 0.04, deadline: 1.0, scan: {
            goldgramDeletionScanAttempt(work: { _ in
                Signal { _ in
                    _ = counts.modify { value in
                        let active = value.active + 1
                        return (active, max(value.maximum, active))
                    }
                    started.signal()
                    return ActionDisposable {
                        _ = counts.modify { ($0.active - 1, $0.maximum) }
                    }
                }
            }, onCancel: {})
        }).start()
    wait(started, "first tick"); wait(started, "second tick")
    work.dispose(); fence(queue)
    let result = counts.with { $0 }
    precondition(result.active == 0 && result.maximum == 1)
}

// A new foreground session starts once; completed work is not resurrected.
do {
    let queue = Queue(name: "scan-resume")
    let active = ValuePromise<Bool>(true, ignoreRepeated: true)
    let done = DispatchSemaphore(value: 0)
    let calls = Atomic(value: 0)
    let work = goldgramDeletionScanSession(foreground: active.get(), queue: queue,
        enabled: true, initialDelay: 0.01, interval: 1.0, deadline: 0.1, scan: {
            _ = calls.modify { $0 + 1 }; done.signal(); return .complete()
        }).start()
    wait(done, "first activation")
    active.set(false); fence(queue)
    active.set(true)
    wait(done, "second activation")
    work.dispose(); fence(queue)
    precondition(calls.with { $0 } == 2)
}
print("Deletion scan lifecycle: 8 integration scenarios passed (real scheduler, controlled storage/network)")
'''

kit = root / 'submodules/SSignalKit/SwiftSignalKit/Source'
files = sorted(kit.glob('*.swift'))
assert len(files) >= 20, 'real SwiftSignalKit sources required'
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    library = path / 'libSwiftSignalKit.dylib'
    subprocess.run([swiftc, '-swift-version', '5', '-emit-library', '-emit-module',
                    '-module-name', 'SwiftSignalKit', '-emit-module-path', str(path / 'SwiftSignalKit.swiftmodule'),
                    *map(str, files), '-o', str(library)], check=True)
    (path / 'main.swift').write_text('import Foundation\nimport SwiftSignalKit\n' + production + '\n' + cases)
    binary = path / 'scan-test'
    subprocess.run([swiftc, '-swift-version', '5', '-I', str(path), '-L', str(path),
                    '-lSwiftSignalKit', str(path / 'main.swift'), '-o', str(binary)], check=True)
    env = dict(os.environ, DYLD_LIBRARY_PATH=str(path))
    for attempt in range(3):
        print(f'Deletion lifecycle run {attempt + 1}/3', flush=True)
        subprocess.run([str(binary)], env=env, check=True, timeout=30)
