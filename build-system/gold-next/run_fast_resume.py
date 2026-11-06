#!/usr/bin/env python3
"""Exercise the production obfuscated prefix check and foreground recovery timers."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
tcp = (root / 'submodules/MtProtoKit/Sources/MTTcpConnection.m').read_text()
account = (root / 'submodules/TelegramCore/Sources/Account/Account.swift').read_text()
chat = (root / 'submodules/ChatListUI/Sources/ChatListController.swift').read_text()
helper = 'static bool MTObfuscatedControlHeaderIsValid(' + tcp.split(
    'static bool MTObfuscatedControlHeaderIsValid(', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
generator = tcp.split('uint8_t controlBytes[64];', 1)[1].split('int32_t controlVersion;', 1)[0]
assert 'while (!MTObfuscatedControlHeaderIsValid(controlBytes))' in generator
assert tcp.index('while (!MTObfuscatedControlHeaderIsValid(controlBytes))') < tcp.index('NSData *effectiveSecret = nil;')
assert 'memcpy(outData.mutableBytes, controlBytes, 56);' in tcp
assert '>= 1.0' in chat and 'goldgramLastHeaderRepairAt >= 5.0' in chat
assert 'goldgramLastUISampleAt >= 10.0' in chat
for gate in ('inputs.raw == "online"', 'accountName == "online"', '!inputs.updating'):
    assert gate in chat
c_source = r'''
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
''' + helper + r'''
static int generated = 0;
static void fixture_random(void *bytes, size_t length) {
    memset(bytes, 0x42, length);
    if (generated++ == 0) ((uint8_t *)bytes)[0] = 0xef;
}
int main(void) {
    uint8_t bytes[64];
    for (int first = 0; first < 256; first++) {
        memset(bytes, 0x42, sizeof(bytes));
        bytes[0] = first;
        assert(MTObfuscatedControlHeaderIsValid(bytes) == (first != 0xef));
    }
    uint32_t forbidden[] = {0x44414548, 0x54534f50, 0x20544547, 0x4954504f,
                            0xdddddddd, 0xeeeeeeee, 0x02010316};
    for (unsigned i = 0; i < sizeof(forbidden) / sizeof(forbidden[0]); i++) {
        memset(bytes, 0x42, sizeof(bytes));
        memcpy(bytes, &forbidden[i], 4);
        assert(!MTObfuscatedControlHeaderIsValid(bytes));
    }
    memset(bytes, 0x42, sizeof(bytes));
    memset(bytes + 4, 0, 4);
    assert(!MTObfuscatedControlHeaderIsValid(bytes));
    uint8_t controlBytes[64];
''' + generator.replace('arc4random_buf', 'fixture_random') + r'''
    assert(generated == 2 && controlBytes[0] == 0x42);
    return 0;
}
'''
watchdog = 'private final class GoldgramForegroundConnectionRecovery' + account.split(
    'private final class GoldgramForegroundConnectionRecovery', 1)[1].split('\npublic class Account {', 1)[0]
stubs = r'''
import Foundation
final class ProcessInfo {
    static let processInfo = ProcessInfo()
    var systemUptime: Double = 100.0
}
struct PeerId {}
enum ConnectionStatus { case waitingForNetwork, connecting, updating, online }
final class Queue { func isCurrent() -> Bool { true } }
enum SwiftSignalKit {
    final class Timer {
        static var all: [Timer] = []
        let timeout: Double
        let completion: () -> Void
        var deadline: Double = .infinity
        init(timeout: Double, `repeat`: Bool, completion: @escaping () -> Void, queue: Queue) {
            self.timeout = timeout
            self.completion = completion
        }
        func start() {
            deadline = ProcessInfo.processInfo.systemUptime + timeout
            Timer.all.append(self)
        }
        func invalidate() { deadline = .infinity }
    }
}
final class Network {
    var requests: [(at: Double, reset: Bool)] = []
    func goldgramRequestTransportRecovery(resetTransport: Bool) {
        requests.append((ProcessInfo.processInfo.systemUptime, resetTransport))
    }
}
enum GoldgramForegroundSyncTrace {
    static var stages: [String] = []
    static func poll(accountPeerId: PeerId, stage: String) { stages.append(stage) }
}
func advance(to target: Double) {
    while let timer = SwiftSignalKit.Timer.all.filter({ $0.deadline <= target })
        .min(by: { $0.deadline < $1.deadline }) {
        ProcessInfo.processInfo.systemUptime = timer.deadline
        timer.invalidate()
        timer.completion()
    }
    ProcessInfo.processInfo.systemUptime = target
}
'''
checks = r'''
let oldForeground = UserDefaults.standard.object(forKey: "GoldgramForegroundActiveV1")
UserDefaults.standard.set(true, forKey: "GoldgramForegroundActiveV1")
defer {
    if let oldForeground {
        UserDefaults.standard.set(oldForeground, forKey: "GoldgramForegroundActiveV1")
    } else { UserDefaults.standard.removeObject(forKey: "GoldgramForegroundActiveV1") }
}
let network = Network()
private let recovery = GoldgramForegroundConnectionRecovery(queue: Queue(), network: network, accountPeerId: PeerId())
// Foreground can arrive before account ownership and network availability.
recovery.update(appActive: true, connectionMaster: false, managerUpdating: true, status: .connecting, flags: 1)
precondition(network.requests.isEmpty)
recovery.update(appActive: true, connectionMaster: true, managerUpdating: true, status: .waitingForNetwork, flags: 0)
precondition(network.requests.isEmpty)
recovery.update(appActive: true, connectionMaster: true, managerUpdating: true, status: .updating, flags: 7)
precondition(network.requests.count == 1 && !network.requests[0].reset,
             "resume must nudge immediately, including pending account sync")
advance(to: 103.99)
precondition(network.requests.allSatisfy { !$0.reset })
advance(to: 104.0)
precondition(network.requests.filter { $0.reset }.count == 1)
// Real transport success cancels recovery even while getDifference is busy.
recovery.update(appActive: true, connectionMaster: true, managerUpdating: true, status: .online, flags: 3)
advance(to: 130)
precondition(network.requests.filter { $0.reset }.count == 1,
             "ordinary account replay must not reset a working transport")
// Background cancels scheduled work immediately.
recovery.update(appActive: false, connectionMaster: true, managerUpdating: false, status: .updating, flags: 7)
let countBeforeBackground = network.requests.count
advance(to: 140)
precondition(network.requests.count == countBeforeBackground)
// A connection that opens during recovery gets its full context grace period.
recovery.update(appActive: true, connectionMaster: true, managerUpdating: true, status: .connecting, flags: 1)
advance(to: 143)
recovery.update(appActive: true, connectionMaster: true, managerUpdating: true, status: .updating, flags: 7)
advance(to: 146.99)
precondition(network.requests.filter { $0.reset }.count == 1)
advance(to: 147)
precondition(network.requests.filter { $0.reset }.count == 2)
advance(to: 155)
precondition(network.requests.filter { $0.reset }.count == 3)
// A second episode exhausts the rolling budget, then waits for a slot.
recovery.update(appActive: false, connectionMaster: true, managerUpdating: false, status: .updating, flags: 7)
advance(to: 160)
recovery.update(appActive: true, connectionMaster: true, managerUpdating: true, status: .updating, flags: 7)
advance(to: 164)
precondition(network.requests.filter { $0.reset }.count == 4)
advance(to: 400)
precondition(network.requests.filter { $0.reset }.count == 4,
             "reset budget must survive foreground/background transitions")
advance(to: 404)
precondition(network.requests.filter { $0.reset }.count == 5)
// Offline with a stale updating-context flag is also excluded.
recovery.update(appActive: true, connectionMaster: true, managerUpdating: true, status: .updating, flags: 4)
let offlineCount = network.requests.count
advance(to: 420)
precondition(network.requests.count == offlineCount)
print("Goldgram fast resume: immediate nudge, sync gating, progress grace, cancellation and reset budget OK")
'''
with tempfile.TemporaryDirectory(prefix='goldgram-resume-') as temp:
    work = Path(temp)
    c = work / 'prefix.c'
    c.write_text(c_source)
    binary = work / 'prefix'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(c), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    print('Goldgram MTProto: forbidden prefixes, zero second word and regeneration OK', flush=True)
    if '--prefix-only' not in sys.argv:
        swift = work / 'main.swift'
        swift.write_text(stubs + watchdog + checks)
        binary = work / 'resume'
        subprocess.run(['swiftc', str(swift), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
