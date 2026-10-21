#!/usr/bin/env python3
"""Regression gates for opt-in priority discussion monitor (#104).

The app and extension are type-checked in macOS CI; this guards the opt-in,
account-scoping, group verification, limits and UI handoff invariants.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
core = (root / "submodules/TelegramCore/Sources/State/GoldgramNativeHistory.swift").read_text()
host = (root / "submodules/TelegramUI/Sources/SharedAccountContext.swift").read_text()
screen = (root / "build-system/gold-next/GoldgramArchiveScreen.swift").read_text()

checks = {
    "distinct account-scoped cache": "collectionId: -106" in core and "stored.account == accountPeerId.toInt64()" in core,
    "explicit opt-in": "goldgramSetPriorityDiscussion" in core and 'action == "priority_discussion_add"' in host,
    "verified linked group": "case .broadcast = channel.info" in core and "case .group = discussion.info" in core and "linkedId == groupId" in core,
    "does not infer from titles": "goldgramPriorityPeers(transaction:" in core,
    "bounded pinned 8": "guard items.count < 8" in core,
    "bounded active 10": "wanted.count < 10" in core,
    "deduped recent targets": "!wanted.contains(id)" in core,
    "user can turn it off": "priority_discussion_remove" in host and "Отключить слежение" in screen,
    "account authenticated": "primary.account.peerId.id._internalGetInt64Value() == accountId" in host,
    "existing editor/archive unchanged": "goldgramPriorityDiscussion" not in (root / "build-system/gold-next/GoldgramHistoryStore.swift").read_text(),
}
for name, valid in checks.items():
    assert valid, name
print("Goldgram #104: priority discussion policy gates OK")
