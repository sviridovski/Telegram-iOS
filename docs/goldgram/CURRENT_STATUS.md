# CURRENT_STATUS — verified checkpoint

> **2026-11-24 local user date — #256 green and user-confirmed unified search; latest recovery checkpoint.** Read [PROJECT_CONTEXT](./PROJECT_CONTEXT.md) and [DECISIONS_LOG](./DECISIONS_LOG.md). Check latest GitHub branch/jobs/artifact before further changes.

## Current code / CI / device state

| Item | Latest confirmed status |
| --- | --- |
| Feature branch | `gold-next-243-author-search` |
| HEAD | `b616ea603876121253d4d7c40284e5aac6a0896d` (#256), direct parent #255 |
| Last green CI | [#256](https://github.com/sviridovski/Telegram-iOS/actions/runs/45317928698), all three jobs success; IPA artifact 14887166379, not expired at verification |
| Last installed and tested | #256 — user confirmed search works and reports satisfaction; individual subcases not separately reported |
| Failed candidate | [#255](https://github.com/sviridovski/Telegram-iOS/actions/runs/45311895241), Native success, Mx failed, Build skipped; NSDictionary conversion fixed in #256 |
| Next candidate | None; roadmap discussion only, no implementation approved. |
| Recovery | #256 latest green/user-tested search baseline; #254 previous green/device-tested archive-search and revision-diff baseline. Original port/telegram-13.2 not modified. |

## #252 corrections retained in #253

#253 changes only the `nativeJump` closure capture list from `[weak self]` to `[weak self = self]`, as recommended by the Swift compiler. GitHub commit parent and one-line diff verified. Weak ownership and navigation/account checks are unchanged; full compilation succeeded and user reported working on device.

1. **Author search navigation:** #251 pushed native ChatController into UIKit navigation, video shows blank/misaligned chat. #252 uses the existing native GoldgramArchiveReturnController via a closure installed by SharedAccountContext for the active account. Dismiss the UIKit modal, push exact message on Telegram Display navigation, back restores the same modal and results/scroll. Explicit failure alert and account validation. No second login/SQLite.
2. **Ghost exception screen:** screenshot shows overlapping original empty-row and footer text; #244 styling had forced non-Ghost footers to CGFLOAT_MIN, and the pinned upstream Mx plus was a nonselectable empty-state icon. #252 restores automatic footer/row height for this section and a real add-person row, with the shared TelegramEngine user picker (contact name or @username), explicit confirmation and the original MxGhostExceptions addPeerId API. Preserve existing exceptions, rename, remove, keys and online-status policy.
3. Three changed files: submodules/ChatListUI/Sources/GoldgramAuthorSearch.swift, submodules/TelegramUI/Sources/SharedAccountContext.swift, build-system/gold-next/prepare_mx.py. No modifications to SQLite, collector, Live Bridge or Ghost packet-filter rules. #253 compiled all three CI jobs and user reported all works; no broader capture/privacy regression suite claimed.

## Build speed

#251 native Bazel restored #250 cache, 8279 disk hits / 10103 processes, elapsed 562.346 s; cache saved again (9,040,776 KiB, within 12 GiB cap). Mx exact cache hit, build skipped. Full #251 wall time ~26m37s including ~7m runner queue. #252 retains same branch and all Bazel keys; changed Mx recipe intentionally requires Mx rebuild; do not reuse stale Mx. #252 restored #251 native cache (2,598,196,986 compressed bytes), 8194 disk hits / 10014 processes, elapsed 746.593 s before compiler failure; Mx cache missed as expected and Mx job succeeded. #253 leaves branch, cache keys, workflow and Mx inputs unchanged. #253 restored #251 Bazel cache, 8225/10103 disk hits, elapsed 1668.782s, critical path 1373.16s; cache saved (10,656,092 KiB after GC). Mx cache missed but saved in final build job. Overall workflow 38m17s. Next same-input run should be able to restore #253 Native and Mx caches; verify logs. Investigate critical path before changing cache policy. Target warm runs 15–20 min where feasible. No cache reset/new branch.

## Acceptance (#253 user reports all works)

- All three CI jobs and IPA artifact verified; user reports installed and working. Below are reusable regression checks, not claims of individually witnessed tests.
- Tap author hit, open exact group/private chat message in normal native UI, swipe left edge right / back, verify same result list and scroll; repeat several times.
- Ghost exceptions: clear layout, add by name and @username only after confirmation, cancel without changes, existing exception rename/removal unchanged. Check read/typing exemptions only apply to explicitly added users; online status not exempt. No private names/screenshots in public documentation.
- Check SQLite archive and Ghost unchanged; continue original-capture/intermediate edit/Live and deleted navigation work only after UI fixes verified.

## Prior unresolved tasks

- Original capture in channels/discussions and suspended app, intermediate edits, delayed live import, deleted jump anchors, chat edit counts; see prior DECISIONS_LOG and PROJECT_CONTEXT. Collector/Bridge deployed version still must be independently verified before updating. Update this file on confirmed result and append decision log; docs-only branch does not trigger CI.

## Roadmap (search and revision comparison approved; remaining ideas discussion only)

- UI/read-only improvements: local archive full-text/date/type/author filters, visual revision diff, bookmarks and tags, and simpler sync-status presentation. Existing revision history and original-route diagnostics should be reused, not duplicated.
- Privacy/storage: optional local Face ID gate, encrypted backup/restore with non-destructive merge, per-dialog retention/exclusions. Preserve account scoping, existing DB, clear-category semantics and explicit user choice. Any media organizer must respect content restrictions.
- Reliability: controlled own-test-message capture and import checks; exact deleted-anchor fallback, pagination and explicit partial search results, measure CI cache and expensive compilation steps. Proposals only; no feature changes in #253 checkpoint update.

## #254 combined feature — green and user-tested

- User approved implementing local archive search and visual comparison in one commit. [Code 89185f64](https://github.com/sviridovski/Telegram-iOS/commit/89185f6468e5081b46351689453fb47061c0fe75), verified parent #253. Only GoldgramHistoryStore.swift, GoldgramArchiveScreen.swift, test_sqlite_reader.py and build.yml changed.
- Search: read-only selected-account SQLite, existing fast visible projection/fallback, original and all stored revisions, literal Unicode case/diacritic-insensitive matching (including Cyrillic е/ё), all/edited/deleted, event-time today/7/30/all, current dialog or all archive, author filtering by known saved (kind,id) from record context menu. Displays matching intermediate text separately from latest. 30-row pages, bounded query length/offset; explicit search, no schema/index migration, no new DB, network search or automatic capture. Existing native author search unchanged.
- Revision comparison: context-menu action, original evidence preserved, red strikethrough removals and green underlined additions, compare stored sequential versions; no fabricated missing versions. Bounded 40 comparisons, 500 tokens/8000 UTF-16 units per diff; larger text falls back to plain before/after. Existing full local history remains available (up to 250 versions).
- Local isolated Swift harness passed real SQLite Unicode function registration, Cyrillic/е/ё, literal wildcard/null, five token diff cases. CI reader regression extended with actual extracted SQL fast/fallback, scope, author-kind, intermediate text, date/event, paging and cross-account isolation; #254 all CI jobs succeeded and reader regression explicitly passed; user reported all works.
- CI optimization: save validated staged Mx in independent successful Mx job, with final packaging cache save fallback; same input keys, final IPA checks unchanged. Native cache family unchanged. Mx rebuild needed because its compiled sources changed. Measure actual hits/timings, no speculative speed claim.

### #254 acceptance (user reported all works; reusable regression cases)

1. All CI jobs green and artifact present; install over #253 only then. Check prior Ghost, author navigation, archive and swipe-back regressions.
2. In each archive tap magnifier; search a known own test string with mixed Cyrillic case and е/ё, literal %/_; find an intermediate revision no longer in latest. Switch all/edited/deleted, period, dialog/all scope, known author via long press and clear author. Verify account changes and purge cannot expose stale results; results show exact message and return to same list.
3. Long-press own test record, choose «Сравнить редакции»: check added/removed words, punctuation, emoji, whitespace, missing-original label, very long message fallback, plain revision history. No changes to SQLite content, Ghost, Collector, Bridge or native capture expected.

## #255 unified search candidate (Native success, Mx failed)

- User approved unified Telegram + archive search after confirming #254. [Code 3312ed8](https://github.com/sviridovski/Telegram-iOS/commit/3312ed8cc689e736665227874653251b47f7cdec) direct parent #254; [CI #255](https://github.com/sviridovski/Telegram-iOS/actions/runs/45311895241) queued at API verification. Seven changed files: GoldgramAuthorSearch.swift, ChatController.swift, GoldgramHistoryStore.swift, GoldgramArchiveScreen.swift, prepare_mx.py, test_sqlite_reader.py, build.yml.
- Unified screen replaces native author search entry and Mx dashboard tile; #254 local archive magnifier and revision comparison remain accessible. Telegram/Archive/Both; optional literal text, selected actual user author by name or username, selected known dialog from root/archive lists, common send-date today/7/30/all. Selecting edited/deleted switches to Archive. Native text-only all-chat path uses TelegramEngine global search filtered to accessible root/archive cloud dialogs; author/explicit-dialog/date-only path uses bounded per-peer searches. TelegramEngine may fall back to local index; no guarantee of server availability or exhaustive search. Limits 1000 dialogs per folder, ten pages per peer/global, two peer searches concurrently, 5000 native hits, 20s chatlist and 30s request deadlines. Archive pages 30, offset cap 5000. No automatic opening/marking read, no new account/session or DB.
- C ABI bridge to Mx existing read-only SQLite reader and narrow native metadata/explicit prepare_jump resolver. Canonical dedup by full Telegram MessageId including peer namespace, not raw IDs/text; SQLite 2/3 share CloudChannel namespace. Local original/matched/latest shown; source labels. Date filter for unified search uses sent_at, excluding unknown send dates only when a date chosen; standalone #254 retains event-time. NativeJump from #253 and existing return stack reused; no SharedAccountContext edits. Ghost exception picker still has its existing explicit confirmation path, separate from choosing an author. No capture/filter/Collector/Bridge/SQLite-schema changes.
- #254 native CI log verified actual SQLite search regression passed, restored #253 cache, 8294/10103 disk hits, Bazel 185.345s, critical path 32.09s, saved cache under #254 SHA. Mx compiled and saved its staged cache independently. #255 preserves same keys, branch, and early Mx save; adds a Swift syntax preflight before expensive native compile and extends existing Python SQL regression for send/event date, unknown dates and source/identity guards. Local isolated Swift C ABI round-trip harness passed; full new tests and compilation not yet verified. Do not claim new performance numbers before CI.

### Unified search acceptance (CI green in #256; user confirms search works; detailed cases retained for regression)

1. Verify all CI jobs and IPA; install only green. Dashboard and in-chat search entry; test Telegram, Archive, Both with own known test strings and author selected by name/username; choose another chat, clear author/dialog, switch period and edited/deleted. Verify common sent-date filter, standalone archive event-date unchanged.
2. Same own test message matching both sources appears once with source label and stored matched text; distinct user/group/channel IDs do not merge; intermediate-only archive match still appears. Test no matches, partial/timeout, archive next page, cancellation when filters change and account switching/purge.
3. Tap native result and swipe back to same results/scroll; archive-only saved record opens preview, explicit jump checks availability; deleted/unavailable message does not jump arbitrarily. Test Ghost exception confirmation, local comparison, existing archive and collector behavior unchanged.

## #256 targeted Mx compile fix

- [#255](https://github.com/sviridovski/Telegram-iOS/actions/runs/45311895241) failed in Mx (job 138169385986, Build Mx 1.0.0 step); Native success, assembly skipped. Compiler: Sources/tgapi/GoldgramArchiveScreen.swift:2275:43 — 'NSDictionary' is not convertible to '[AnyHashable : Any]'. This is the unified metadata bridge, not the native search screen. Native log confirms #255 SQL regression passed (sent/event date, unknown dates, identity/bridge guards) and successful compile.
- [Fix b616ea6](https://github.com/sviridovski/Telegram-iOS/commit/b616ea603876121253d4d7c40284e5aac6a0896d) published; exact diff verified: only GoldgramArchiveScreen.swift changed, inside goldgramUnifiedMetadataV1. Construct a typed Swift dictionary from validated accountId/items and optional explicitly allowed prepare_jump, no cast or force cast. Keep account and action checks and native resolver. All #255 search modes retained; no other changes to native UI, database schema, capture, Ghost, Collector or Live Bridge. [#256](https://github.com/sviridovski/Telegram-iOS/actions/runs/45317928698) all three jobs success; IPA artifact verified; user confirms search works. #256 is latest recovery baseline.
- #255 Native restored #254 cache, 8224/10103 disk hits, Bazel 1413.863s, critical path 1152.67s, saved cache under #255 SHA. #256 changes only Mx Swift source; preserve Native cache family and all native source inputs, expect reuse of #255 native cache if runner/key available. Mx rebuild required due to changed source; prior failed Mx produced no usable cache. No cache reset. Existing #255 acceptance remains pending.

## #256 confirmed checkpoint and proposed next roadmap

- Native restored #255 cache, 8294/10103 disk hits, Bazel 175.427s, critical path 27.94s. Native cache saved under #256 SHA; Mx cache miss expected, staged Mx successfully saved. Total workflow 15m46s. Unified SQL regression explicitly passed again. All three jobs green. User reports search works; no broader per-case capture/Ghost/Collector test results inferred.
- Ideas for discussion (not authorized for implementation): local user-controlled bookmarks/tags/notes (references instead of duplicate stored message text), private contact notes/aliases, saved search filters and custom date range/highlight/sort/media filters for supported results, configurable contextual menu/quick actions, Face ID for local archive and previews, encrypted backup with account-aware non-destructive restore, simplified Live status and bounded reliability tests. Check existing Swiftgram/Mx analogues before adding features. Respect existing archive visibility, account scoping, user-initiated access, Ghost and storage rules. No new source changes or CI run for documentation.
