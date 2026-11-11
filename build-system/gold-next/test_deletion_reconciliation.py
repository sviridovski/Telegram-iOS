#!/usr/bin/env python3
"""Exercise the production deletion policy; verify bounded worker integration.

The macOS workflow runs the extracted Swift policy. A Linux host without
Swift can only run the source/integration checks and reports that explicitly.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'submodules/TelegramCore/Sources/State/GoldgramNativeHistory.swift').read_text()
workflow = (root / '.github/workflows/build.yml').read_text()


def extract(start):
    begin = source.index(start)
    brace = source.index('{', begin)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[begin:end]


policy = extract('private enum GoldgramDeletionScanPolicy')
worker = extract('private func goldgramReconcileDeletions(')
assert re.search(r'^import MtProtoKit$', source, re.MULTILINE), 'MTRpcError requires its defining module in this file'
monitor = source.split('private final class GoldgramDiscussionMonitor', 1)[1].split('// #114:', 1)[0]
assert 'chatListGetAllPeerIds()' in worker, 'include archived chats, not only recent ten'
assert 'linkedDiscussionPeerId' in worker and 'goldgramPriorityPeers(' in worker
assert 'min(8, ordered.count)' in worker and 'limit: 32, fromUpperBound: true' in worker
assert 'range: 1 ... upper' in worker and 'state.upperBounds' in worker
assert '.messageEmpty(data)' in worker, 'only explicit empty-ID evidence'
assert 'case .messagesNotModified: return' in worker
assert 'id.peerId == batch.peer.id' in worker
assert 'channel.participationStatus == .member || !live.isEmpty' in worker
assert 'group.membership == .Member || !live.isEmpty' in worker
assert 'goldgramRetainDeletion(' in worker and 'deleteMessages(' not in worker
assert 'transaction.addMessages(' not in worker, 'no stale server overwrite or fake edits'
assert worker.count('GoldgramForegroundActiveV1') == 2
error_path = worker.split('|> `catch`', 1)[1].split('|> mapToSignal', 1)[0]
assert '.single(nil)' in error_path and 'empty.insert' not in error_path
assert 'state.upperBounds' not in error_path, 'failed RPC keeps the message cursor'
assert 'GoldgramForegroundSyncTrace.foregroundActive |> deliverOn(queue)' in monitor
assert 'static let automaticScanEnabled = false' in policy, 'device-crash containment must remain off'
assert monitor.index('self.deletionScanWork.set(nil)') < monitor.index('guard GoldgramDeletionScanPolicy.automaticScanEnabled, active else')
assert monitor.index('guard GoldgramDeletionScanPolicy.automaticScanEnabled, active else') < monitor.index('self.deletionScanWork.set((scanClock')
assert 'timeout(8.0, queue: queue, alternate: .complete())' in monitor
assert 'delay(5.0, queue: queue)' in monitor and 'delay(10.0, queue: queue)' in monitor
assert 'self.deletionScanPulse.dispose()' in monitor and 'self.deletionScanWork.dispose()' in monitor
assert not re.search(r'readHistory|readMessageContents|updateStatus|setTyping|beginBackgroundTask', worker)
cache_ids = re.findall(r'ItemCacheEntryId\(collectionId: (-\d+), key: ValueBoxKey\(length: 0\)\)', source)
assert len(cache_ids) == len(set(cache_ids)), 'scan cursor must not overwrite another cache record'
assert 'python3 build-system/gold-next/test_deletion_reconciliation.py' in workflow
print('Deletion reconciliation: source integration checks passed')

cases = r'''
precondition(!GoldgramDeletionScanPolicy.automaticScanEnabled, "automatic scanning remains disabled pending device investigation")
func check(_ requested: Set<Int32>, _ empty: Set<Int32>, _ live: Set<Int32>, _ access: Bool, _ expected: Set<Int32>) {
    precondition(GoldgramDeletionScanPolicy.confirmed(requested: requested, empty: empty,
        live: live, accessible: access) == expected)
}
check([1, 2, 3], [2], [1, 3], true, [2])
check([1, 2, 3], [], [1], true, []) // omitted IDs are not deletion evidence
check([1, 2, 3], [1, 2, 3], [], false, []) // loss of access
check([1], [1, 99], [], true, [1]) // unsolicited IDs are ignored
check([1], [1], [1], true, []) // conflicting live evidence wins
check([1, 2], [1, 2], [], true, [1, 2]) // all deleted, access confirmed
check([], [1], [], true, [])
precondition(GoldgramDeletionScanPolicy.nextUpperBound(scanned: []) == Int32.max)
precondition(GoldgramDeletionScanPolicy.nextUpperBound(scanned: [1]) == Int32.max)
precondition(GoldgramDeletionScanPolicy.nextUpperBound(scanned: [5, 3, 4]) == 2)
var upper = Int32.max
let saved: [Int32] = [1000, 999, 900, 10, 2, 1]
var visited: [Int32] = []
for _ in 0..<3 {
    let batch = Array(saved.filter { $0 <= upper }.prefix(2))
    visited += batch
    upper = GoldgramDeletionScanPolicy.nextUpperBound(scanned: batch)
}
precondition(visited == saved && upper == Int32.max, "scan old cached history then wrap for new messages")
print("Deletion reconciliation: 12 production-policy cases passed")
'''
swiftc = shutil.which('swiftc')
if swiftc:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        (path / 'main.swift').write_text('import Foundation\n' + policy + '\n' + cases)
        subprocess.run([swiftc, str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
        subprocess.run([str(path / 'test')], check=True)
else:
    print('Swift compiler unavailable: production-policy execution NOT run; macOS CI required')
