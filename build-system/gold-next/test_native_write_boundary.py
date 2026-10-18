#!/usr/bin/env python3
"""Verify capture ownership at real Postbox writes, not a list of API fetchers."""
from pathlib import Path
r = Path(__file__).resolve().parents[2]
p = (r/'submodules/Postbox/Sources/Postbox.swift').read_text()
a = (r/'submodules/TelegramCore/Sources/Account/Account.swift').read_text()
n = (r/'submodules/TelegramCore/Sources/State/GoldgramNativeHistory.swift').read_text()
u = (r/'submodules/TelegramUI/Sources/SharedAccountContext.swift').read_text()
add = p.split('public func addMessages(', 1)[1].split('public func messageExists', 1)[0]
update = p.split('public func updateMessage(', 1)[1].split('public func offsetPendingMessages', 1)[0]
assert add.index('prepareStoreMessage') < add.index('postbox.addMessages('), 'Capture before inserting any source'
assert 'prepareStoreMessage(message)' in update, 'Capture before replacing, not after old content is lost'
assert 'defer { self.preparingStoreMessage = false }' in update, 'Reentry guard always reset'
assert a.index('postbox.setStoreMessagePreprocessor') < a.index('self.networkStatsContext ='), 'Install before account managers start fetches'
assert 'self.impl.with { impl in impl.storeMessagePreprocessor = prepare }' in p, 'Install on the same serial Postbox queue'
# The two previously uncovered native loaders must use the shared public write API.
for path in ['submodules/TelegramCore/Sources/TelegramEngine/Messages/ReplyThreadHistory.swift',
             'submodules/TelegramCore/Sources/State/Holes.swift']:
    s = (r/path).read_text()
    assert 'transaction.addMessages(' in s and 'preprocess: false' not in s
# Local archive cleanup/restore deliberately bypass server-change capture.
assert 'transaction.updateMessage(id, preprocess: false' in u
assert 'transaction.addMessages([restored], location: .Random, preprocess: false)' in n
assert 'goldgramSnapshotAuthor(transaction: transaction, id: id)?.id' in n
state = (r/'submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift').read_text()
edit = state.split('case let .EditMessage(id, rawMessage):', 1)[1].split('case let .UpdateMessagePoll', 1)[0]
assert edit.index('transaction.addMessages([message], location: .Random)') < edit.index('transaction.updateMessage(id'), 'Missing native row still saves full delivered edit'
assert 'transaction.getMessage(id) == nil' in edit
assert '"eventKind": 0' in n, 'Received bodies also persist outside the bounded Postbox baseline ring'
assert 'goldgramMonitorDiscussions(account: account)' in u
monitor = u.split('self.goldgramDiscussionMonitorDisposable.set(',1)[1].split('self.widgetDataContext =',1)[0]
assert 'shouldBeServiceTaskMaster.get()' in monitor and 'isMasterClient()' in monitor
assert 'applicationInForeground' not in monitor, 'background execution must not immediately stop capture'
wake = (r/'submodules/TelegramUI/Sources/SharedWakeupManager.swift').read_text()
assert 'wasInForeground && !value && goldgramNativeHistoryEnabled()' in wake
assert 'allowBackgroundTimeExtension(timeout: 20.0, extendNow: true)' in wake
assert 'case .group = peer.info' in n and 'prefix(4)' in n, 'Monitor is limited to accessible groups and bounded'
assert 'viewTracker.polledChannel(peerId: id)' in n and 'limit: 100' in n
assert 'readHistory(' not in n and 'joinChannel(' not in n, 'Monitoring must not mark read or join chats'
assert 'self.goldgramDiscussionMonitorDisposable.dispose()' in u
print('Goldgram #88: account-local capture boundary covers discussion/chat-list writes and preserves maintenance bypasses')

# #90: only implicit server/timer removal preserves tombstones. Explicit clear
# remains an intentional direct Postbox deletion, even with capture disabled.
validation = (r/'submodules/TelegramCore/Sources/State/HistoryViewStateValidation.swift').read_text()
assert validation.count('if goldgramRetainDeletion(accountPeerId: accountPeerId, transaction: transaction, mediaBox: postbox.mediaBox, id: id) { continue }') == 2
assert 'return .single(Set(maybeRemovedMessageIds))' not in validation, 'failed exact-ID checks are not proof of deletion'
retain = n.split('func goldgramRetainDeletion(',1)[1].split('func goldgramUnresolvedDeletions',1)[0]
assert retain.index('goldgramPreserveRetained') < retain.index('guard goldgramNativeHistoryEnabled()'), 'capture OFF must not purge retained messages'
timer = (r/'submodules/TelegramCore/Sources/State/ManagedAutoremoveMessageOperations.swift').read_text()
assert timer.index('goldgramPreserveRetained') < timer.index('if isRemove,')
assert 'transaction.deleteMessages(' in u, 'Clear Logs still purges local tombstones'
print('Goldgram #90: validation/timer retention and service-master background lifecycle wiring OK')
