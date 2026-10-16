#!/usr/bin/env python3
"""#78: archive native message navigator ownership, ID scoping and fail closed."""
from pathlib import Path
r=Path(__file__).parent
store=(r/"GoldgramHistoryStore.swift").read_text()
screen=(r/"GoldgramArchiveScreen.swift").read_text()
host=(r.parents[1]/"submodules/TelegramUI/Sources/SharedAccountContext.swift").read_text()
checks = {
    "C bridge consistent": "goldgram_register_native_navigation_v1" in store and "goldgram_register_native_navigation_v1" in host,
    "scoped active account": "selectedAccount == accountId" in store and "primary.account.peerId.id._internalGetInt64Value() == accountId" in host,
    "selected host context": "goldgramNativeNavigationContext = self" in host and "goldgramNativeNavigationContext = nil" in host,
    "main-thread only": "guard Thread.isMainThread" in store and "guard Thread.isMainThread" in host,
    "native chat method": "shared.navigateToChat(" in host and "messageId: messageId" in host,
    "complete peer namespace": "Namespaces.Peer.CloudUser" in host and "Namespaces.Peer.CloudGroup" in host and "Namespaces.Peer.CloudChannel" in host,
    "message target": "Namespaces.Message.Cloud" in host,
    "removed guesswork": "MxLastKnownUserId" not in screen,
    "reader method": '@objc(navigateToMessage:)' in store,
    "row action": '"action": "prepare_jump"' in screen and 'request["action"] = "open_message"' in screen,
    "async native check": "goldgramRestoreSnapshot(transaction:" in host and "getMessagesLoadIfNecessary([id])" in host,
    "sheet dismissal order": "presenter.dismiss(animated: true, completion: open)" in screen,
    "missing content detail": "showLocalRecord(entry" in screen and "showArchiveJumpFailure" not in screen,
    "tombstone safe": 'entry["deleted"] as? NSNumber' in screen,
    "non-overridden revisions": 'latestText' in screen and 'originalText' in screen,
}
assert all(checks.values()), checks
print("Goldgram #78: account-scoped native peer/message navigation guards OK")
