# Goldgram — current handoff, 2026-10-18
## Authoritative current state
Repository sviridovski/Telegram-iOS. App branch gold-next.
Current app commit 81c66718988a1d3a09669a2b24e4b83a973bcdcc; exact tree 0e1a60499c0ab6bb7a8799aadee5216421518e1a.
CI #96 run39125379485 launched for current commit, status pending as of 2026-10-18: https://github.com/sviridovski/Telegram-iOS/actions/runs/39125379485
Prior CI #95 run39114532456/job117637501652 completed SUCCESS (real Swift SQLite gates, Mx and clean Swiftgram/extension build, IPA). Prior #94 also green.
User installed #95 and reproduced missing original: two edited messages show "Оригинал не был получен" in inline history, despite edits being saved. #95 is NEGATIVE for original capture on device; other behavior remains untested. Never conflate green CI with device validation.

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
