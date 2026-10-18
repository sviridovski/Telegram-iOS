# Goldgram — current handoff, 2026-10-18
## Authoritative current state
Repository sviridovski/Telegram-iOS. App branch gold-next. Current app commit d3546619a333fb096ee89690ed3c86a286b22c10; exact tree f6991ce151e3a9f88af80ed8cb710806d84cad7e.
CI #95 run39114532456/job117637501652 COMPLETED SUCCESS: all runtime gates, Mx compile, clean Swiftgram/Core/UI/NotificationService build, host-only injection, IPA packaging/checksum/upload. https://github.com/sviridovski/Telegram-iOS/actions/runs/39114532456
Previous #94 run39112134878/job117630331640 also full SUCCESS.
Device validation of #95 remains pending. Last explicitly reported installed build #90. Never conflate green build with verified capture on device.

## Latest completed functional atom (#91–95)
1. Original capture: standaloneStateManager used by notification extension lacked main-account Postbox preprocessing. Added matching preprocessor before state replay, account-scoped consent shared through Postbox cache -103 (default OFF). Extension received payloads durable handoff -104 (512 events/4MiB), main drains on initial/15sec tick, deletes only after SQLite flush success. Direct NotificationService delete notifications also pass native retention.
2. Known original SQL C bridge restores true previously observed text; never invent original from first edit. Final #95 accepts genuinely received delayed unedited original in three previously early-return branches, baseline-only observation repairs baseline without replacing newer edited/deleted live body/version/media. Known pinned native baseline also propagated on edit/delete. Failed handoff flush can retry without restart. Clear Logs synchronizes new cutoff into extension in same transaction.
3. Broader personal/group/supergroup/channel target observation, up to8 recent targets, wake seed100 messages; channel-only polledChannel. Existing native background/master ownership and20sec expiring task retained. No fake audio/location or guarantee while iOS suspends.
4. Privacy & Functions selected-account separate totals for edited/deleted unique messages, updated on appearance and archive-change notification. Repeated edits count once; edited then deleted counts in both. Empty receipt-only placeholders excluded.
5. Apple SQLite real runtime rejected correlated outer m.is_deleted in inner ORDER BY (no such column). Shared archive and totals SQL now orders only local revision content/version. Actual production callback tested, #95 expects3 edited/2 deleted.

## Critical files
submodules/TelegramCore/Sources/State/GoldgramNativeHistory.swift
submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift
submodules/TelegramCore/Sources/Account.swift (locate exact tracked Account.swift if path differs)
Telegram/NotificationService/Sources/NotificationService.swift
GoldgramHistoryStore.swift, GoldgramMessageHistory.swift, SharedAccountContext.swift, prepare_mx.py (rg --files to locate)
Actual Swift runtime fixture test_native_capture.swift, extracted handoff run_notification_handoff.py, timer fixture run_retention_guard.py.
Pinned Mx23c980300c3e9c98f39ee2bd073fe83d317e15ba. Read specific current code and root AGENTS instructions; no full historical audit.

## Validation
All12 local Python suites passed; no local Swift compiler. macOS CI #95 passed production Swift SQLite writer/original C bridge/totals, induced rollback/retry, late-original preservation, notification consent/count/byte bounds, Postbox codec, retention guard, SDK typecheck, full actual app/extensions, IPA.
Device check: install #95 over current app without deleting archive. Capture/Originals in SQLite ON, foreground15sec; fresh message from another client, background app, edit twice/delete, reopen; compare original/numbered gray revisions, author/time, totals, ordinary timer tombstone and repeat navigation. Old never-received content cannot be reconstructed.

## User preferences and next action
User Stas, Russian informal bro. Work autonomously within already authorized scope, no repeated confirmation. One coherent functional atom; do not introduce unrelated optional changes or reopen historical #37–49. No subagents unless user/applicable instructions request.
Only meaningful progress updates. Improvement proposals ONLY AFTER task completion, detailed numbered list, never during progress.
User now migrating chat; do not start new code scope until concrete next request/device findings.
Suggested later options (NOT IMPLEMENTED): explicit priority chat list; capture health/last successful capture and original coverage; separately labelled partial notification previews.
Read this file first, then only top relevant sections of GOLD_ROADMAP.md / GOLD_NEXT_MIGRATION_PLAN.md / GOLDGRAM_HISTORY_SQLITE_PLAN.md. Older sections saying #94/#95 pending are superseded by this file.
