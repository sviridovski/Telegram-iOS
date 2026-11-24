# CURRENT_STATUS — verified checkpoint

> **2026-11-24 local user date — #253 green CI and user-tested checkpoint.** Read [PROJECT_CONTEXT](./PROJECT_CONTEXT.md) and [DECISIONS_LOG](./DECISIONS_LOG.md). Check latest GitHub branch/jobs/artifact before further changes.

## Current code / CI / device state

| Item | Latest confirmed status |
| --- | --- |
| Feature branch | `gold-next-243-author-search` |
| HEAD | `0fc68f7f10ea0da0e7998866f802dece8d188ec1` (#253), parent failed #252; latest verified green #253 |
| Last green CI | [#253](https://github.com/sviridovski/Telegram-iOS/actions/runs/45294198691), all three jobs success; IPA artifact 14878545864, not expired at verification |
| Last installed and tested | #253 — user confirmed installed/tested and all works on 2026-11-24 local; individual acceptance subcases not separately reported |
| Failed candidate | [#252](https://github.com/sviridovski/Telegram-iOS/actions/runs/45287862914), Native failed, Mx success, Build skipped; Swift ImplicitStrongCapture in SharedAccountContext.swift:1308 |
| Next candidate | None. #253 is the new recovery baseline; planning only, no new source changes approved yet. |
| Recovery | #250 green and author lookup confirmed, but result tap ignored. #243 older green baseline. Original port/telegram-13.2 not modified. |

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

## Proposed roadmap (discussion only; not approved for implementation)

- UI/read-only improvements: local archive full-text/date/type/author filters, visual revision diff, bookmarks and tags, and simpler sync-status presentation. Existing revision history and original-route diagnostics should be reused, not duplicated.
- Privacy/storage: optional local Face ID gate, encrypted backup/restore with non-destructive merge, per-dialog retention/exclusions. Preserve account scoping, existing DB, clear-category semantics and explicit user choice. Any media organizer must respect content restrictions.
- Reliability: controlled own-test-message capture and import checks; exact deleted-anchor fallback, pagination and explicit partial search results, measure CI cache and expensive compilation steps. Proposals only; no feature changes in #253 checkpoint update.
