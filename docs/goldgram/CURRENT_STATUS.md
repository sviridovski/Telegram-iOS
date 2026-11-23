# CURRENT_STATUS — verified checkpoint

> **2026-11-23 23:20 UTC / 2026-11-24 local user date.** Read [PROJECT_CONTEXT](./PROJECT_CONTEXT.md) and [DECISIONS_LOG](./DECISIONS_LOG.md). Check latest GitHub branch/jobs/artifact before further changes.

## Current code / CI / device state

| Item | Latest confirmed status |
| --- | --- |
| Feature branch | `gold-next-243-author-search` |
| HEAD | `5fd55a7acad0bdc380e0b4e824deab14adeb6aec` (#252), parent green #251 |
| Last green CI | [#251](https://github.com/sviridovski/Telegram-iOS/actions/runs/45264803031), commit caf15ec7e8dac8bdf3bdcf8b80c595be5275f147; all three jobs success |
| Last installed and tested | #251, user supplied screen recording + Ghost exceptions screenshot; **two UI problems confirmed** |
| Next candidate | [#252](https://github.com/sviridovski/Telegram-iOS/actions/runs/45287862914), in_progress at API check; no green or on-device success claimed |
| Recovery | #250 green and author lookup confirmed, but result tap ignored. #243 older green baseline. Original port/telegram-13.2 not modified. |

## #252 corrections

1. **Author search navigation:** #251 pushed native ChatController into UIKit navigation, video shows blank/misaligned chat. #252 uses the existing native GoldgramArchiveReturnController via a closure installed by SharedAccountContext for the active account. Dismiss the UIKit modal, push exact message on Telegram Display navigation, back restores the same modal and results/scroll. Explicit failure alert and account validation. No second login/SQLite.
2. **Ghost exception screen:** screenshot shows overlapping original empty-row and footer text; #244 styling had forced non-Ghost footers to CGFLOAT_MIN, and the pinned upstream Mx plus was a nonselectable empty-state icon. #252 restores automatic footer/row height for this section and a real add-person row, with the shared TelegramEngine user picker (contact name or @username), explicit confirmation and the original MxGhostExceptions addPeerId API. Preserve existing exceptions, rename, remove, keys and online-status policy.
3. Three changed files: submodules/ChatListUI/Sources/GoldgramAuthorSearch.swift, submodules/TelegramUI/Sources/SharedAccountContext.swift, build-system/gold-next/prepare_mx.py. No modifications to SQLite, collector, Live Bridge or Ghost packet-filter rules. Static exact-anchor checks only; full compile/device acceptance pending.

## Build speed

#251 native Bazel restored #250 cache, 8279 disk hits / 10103 processes, elapsed 562.346 s; cache saved again (9,040,776 KiB, within 12 GiB cap). Mx exact cache hit, build skipped. Full #251 wall time ~26m37s including ~7m runner queue. #252 retains same branch and all Bazel keys; changed Mx recipe intentionally requires Mx rebuild; do not reuse stale Mx. Check #252 actual cache restoration/hit rates, compile and queue separately. Target warm runs 15–20 min where feasible. No cache reset/new branch.

## Acceptance (pending)

- #252 all three CI jobs and IPA artifact verified before installing.
- Tap author hit, open exact group/private chat message in normal native UI, swipe left edge right / back, verify same result list and scroll; repeat several times.
- Ghost exceptions: clear layout, add by name and @username only after confirmation, cancel without changes, existing exception rename/removal unchanged. Check read/typing exemptions only apply to explicitly added users; online status not exempt. No private names/screenshots in public documentation.
- Check SQLite archive and Ghost unchanged; continue original-capture/intermediate edit/Live and deleted navigation work only after UI fixes verified.

## Prior unresolved tasks

- Original capture in channels/discussions and suspended app, intermediate edits, delayed live import, deleted jump anchors, chat edit counts; see prior DECISIONS_LOG and PROJECT_CONTEXT. Collector/Bridge deployed version still must be independently verified before updating. Update this file on confirmed result and append decision log; docs-only branch does not trigger CI.
