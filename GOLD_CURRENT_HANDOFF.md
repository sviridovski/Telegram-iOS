# Goldgram — current handoff, 2026-10-18
## Authoritative current state
Repository sviridovski/Telegram-iOS. Branch gold-next.
App HEAD cf40fced4e53d3fbdb03f065f05f1f51e3b19197 (Swift reader argument ordering fix, CI #99); diagnostic feature commit d30dccf50585d3400ba072a40f63c2ac7f51be3e (#97), fixture correction 0e3d98c0fe0a98d5d39727bfa31a83f37a1faebb (#98).
CI #99: https://github.com/sviridovski/Telegram-iOS/actions/runs/39150498261 (queued when written). #97/#98 also triggered; final validation is #99.
CI #96 run39125379485 success, but user installed the newer fix and still reports "Оригинал не был получен" on device; #95 likewise. Therefore do NOT claim device issue fixed.

## Current diagnostic atom (#97–99)
User asks for a concrete phone diagnostic test instead of more unverified fixes. Added an opt-in privacy-safe in-app test in GoldgramArchiveScreen, accessible through "Тест" on root pages of history folders (Personal / Groups / Channels / Deleted). "Начать новый тест" resets diagnostic counters ONLY, not chat archive; "Показать результат" shows stage counts and aggregate SQLite facts for selected account since test start.
Stage counts from TelegramCore: full confirmed live server-original accepted into writer, Postbox unedited/edited preprocessing and enabled state, SQL-original retrieval hits, inline-known/unknown decisions. No message texts, names, message IDs or hashes are stored in diagnostic counters or returned in report. Counts are event counters, not distinct-message numbers.
Reader supports query mode "diagnostics" and reports fresh SQLite rows, confirmed originals, edited rows lacking originals, and total edited rows. Fixture checks aggregate counters on real Swift SQLite. Fixture correction adjusts expected baseline count to five, including late and retried original. #99 fixes Swift argument label order for reader's new diagnosticSince field.
Changes: GoldgramNativeHistory.swift, GoldgramArchiveScreen.swift, GoldgramHistoryStore.swift, test_native_capture.swift.
Current commits: https://github.com/sviridovski/Telegram-iOS/commit/d30dccf50585d3400ba072a40f63c2ac7f51be3e, https://github.com/sviridovski/Telegram-iOS/commit/0e3d98c0fe0a98d5d39727bfa31a83f37a1faebb, https://github.com/sviridovski/Telegram-iOS/commit/cf40fced4e53d3fbdb03f065f05f1f51e3b19197
Test: install final green #99 over old app (no deletion); open Goldgram > Updated/Deleted > one of the history folders, tap "Тест", "Начать новый тест". Fresh message from second client (while iPhone app foreground), wait, edit twice, return to same folder "Тест" > "Показать результат"; send screenshot of counters and SQLite. No need to clear archive or log private content. Interpret counters to isolate server delivery, native processing, SQLite persistence, or inline display.
Next: check #99 CI, fix compile/test failures if any, have user test, then investigate based on evidence. No unrelated changes.

## Latest fix (#96, awaiting CI and device re-test)
The native Postbox snapshot preprocessor can miss a live new-message original when an edit overtakes deferred Postbox replay. The existing direct full-server incoming API update capture path was completely disabled while native SQLite mode was ON.
Now TelegramCore immediately persists verifiably unedited original text from live updateNewMessage (including messages from other logged-in clients) and accepted updateNewChannelMessage, BEFORE postponed Postbox application, with authenticated account and verified peer kind.
Native writer records eventKind=0, originalObserved=true, originalText=<actually received text>, baselineOnly=true so an out-of-order original repairs baseline but never replaces newer content or creates a false edit. An edit already present, an edited difference/catch-up, or a notification preview is NOT labelled as an original.
Changes: GoldgramNativeHistory.swift, AccountStateManagementUtils.swift and test_native_capture.swift. Test fixture now checks direct baseline-only original, delayed original without fake revision. CI #96 still pending.
Commit https://github.com/sviridovski/Telegram-iOS/commit/81c66718988a1d3a09669a2b24e4b83a973bcdcc
Device re-test after CI: install #96 over #95 without deleting logs, enable capture, create truly new message on second client while Swiftgram foreground, confirm initial message displayed, edit twice, then check original/revisions, background/deletion/author/totals separately. iOS may never deliver an original while suspended.

## Previous completed functional atom (#91–95)
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
#95 bug reported; #96 targeted fix committed. Await CI and new on-device findings; do not start unrelated changes.
Suggested later options (NOT IMPLEMENTED): explicit priority chat list; capture health/last successful capture and original coverage; separately labelled partial notification previews.
Read this file first, then only top relevant sections of GOLD_ROADMAP.md / GOLD_NEXT_MIGRATION_PLAN.md / GOLDGRAM_HISTORY_SQLITE_PLAN.md. Older sections saying #94/#95 pending are superseded by this file.
