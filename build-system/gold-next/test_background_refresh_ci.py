#!/usr/bin/env python3
"""Goldgram #107: OS-scoped discussion refresh and safe Bazel cache policy."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
app = (root / "submodules/TelegramUI/Sources/AppDelegate.swift").read_text()
core = (root / "submodules/TelegramCore/Sources/State/GoldgramNativeHistory.swift").read_text()
ui = (root / "build-system/gold-next/GoldgramArchiveScreen.swift").read_text()
workflow = (root / ".github/workflows/build.yml").read_text()
bazel = (root / "Telegram/BUILD").read_text()

assert "BGAppRefreshTaskRequest" in app
assert "BGAppRefreshTask" in app and "goldgramRunRefresh(refresh)" in app
assert 'goldgramScheduleRefresh()' in app
assert 'task.expirationHandler = { complete(false) }' in app
assert 'self.goldgramRefreshWork.set(nil)' in app
assert 'goldgramRefreshPriorityDiscussions(account: account)' in app
assert 'GoldgramLastRefreshStartedV1' in app
assert 'Фоновые проверки iOS:' in ui
assert 'BGTaskSchedulerPermittedIdentifiers' in bazel
assert '{telegram_bundle_id}.refresh' in bazel
assert "goldgramCaptureEnabled(accountPeerId: account.peerId, transaction: transaction)" in core
assert "goldgramPriorityPeers(transaction: transaction," in core
assert '.prefix(3)' in core
assert 'standalonePollChannelOnce(' in core
assert 'joinChannel(' not in core
assert "actions/cache/restore@v4" in workflow
assert "actions/cache/save@v4" in workflow
assert "--cacheDir=\"/private/var/tmp/goldgram-bazel-action-cache\"" in workflow
assert "3 * (1024 ** 3)" in workflow
assert "verify_mx.py" in workflow
print("Goldgram #107: scoped BGAppRefresh and bounded Bazel cache policy verified")
