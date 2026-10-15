#!/usr/bin/env python3
"""Goldgram #74 account ownership and browser bridge contract guards."""
from pathlib import Path
root = Path(__file__).parent
store = (root / "GoldgramHistoryStore.swift").read_text()
screen = (root / "GoldgramArchiveScreen.swift").read_text()
mx = (root / "prepare_mx.py").read_text()
host = (root.parents[1] / "submodules/TelegramUI/Sources/SharedAccountContext.swift").read_text()
checks = {
    "trusted host": "goldgramPublishSelectedAccount(primary?.account.peerId.id._internalGetInt64Value() ?? 0)" in host,
    "clear on switching": "goldgramPublishSelectedAccount(0)" in host,
    "bridge symbol matches": "goldgram_bind_active_account_v1" in host and "goldgram_bind_active_account_v1" in store,
    "reader owner gate": "guard isSelected(accountId)" in store,
    "completion owner recheck": "self.isSelected(accountId)" in store,
    "browser ObjC factory": "@objc(GoldgramArchiveScreen)" in screen and "@objc(initWithCategory:)" in screen,
    "browser compiled into MX": "GoldgramArchiveScreen.swift" in mx,
    "native Mx history folders preserved": "mx_history_patches" in mx,
    "browser entry guard": "browser_entry" in mx and "mx_ui_source.count(browser_entry) != 1" in mx,
    "no legacy owner": "MxLastKnownUserId" not in screen,
    "bounded queries": 'NSNumber(value: 30)' in screen,
}
assert all(checks.values()), checks
print("Goldgram #74: selected-account bridge/browser structural invariants OK")
