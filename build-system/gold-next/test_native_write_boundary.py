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
print('Goldgram #88: account-local capture boundary covers discussion/chat-list writes and preserves maintenance bypasses')
