# CURRENT_STATUS — verified checkpoint

> **Canonical project passport (part 2/3).** Snapshot **2026-11-23 20:58 UTC**; **not a live dashboard**. Always query the repository and workflow runs before resuming. [PROJECT_CONTEXT](./PROJECT_CONTEXT.md) · [DECISIONS_LOG](./DECISIONS_LOG.md).

## 1. Current repo and branch reality

Repository: [sviridovski/Telegram-iOS](https://github.com/sviridovski/Telegram-iOS). Historical development is Telegram iOS **13.2** (port from 12.9.2). The old branch **gold-next is stale**; do not assume it's currently active.

| Item | Verified at snapshot |
| --- | --- |
| Active original development branch | **port/telegram-13.2** |
| Original branch head at the latest transfer | **38400f8cf6d6e87b2031eaa17c6c46f987ca98af**; CI **#249 failure** |
| Most recent confirmed green baseline | CI **#243**, SHA **ff67a435fd667b16bdc3858f860e0f47e8cacb4e**, all jobs success |
| Safe isolated feature branch | **gold-next-243-author-search** |
| Feature branch HEAD | **caf15ec7e8dac8bdf3bdcf8b80c595be5275f147** (#251; parent = green #250); the feature branch originally branched directly from green #243 |
| Latest feature CI | **#251**, run ID **45264803031** — created/queued, not yet verified green |
| #250 final API result | **SUCCESS: mx + native + build**; final IPA artifact present; user installed on iPhone and confirmed author search displays correct results |
| Dedicated documentation branch | **goldgram-project-docs**; documents-only, no CI push trigger, from #243 |
| Verified on actual main iPhone | User installed **#250** and confirmed contact/author search returns real messages. **Tapping a result did not open chat**; swipe return untested. #251 is fix candidate, not installed/tested. |

Sources: [green #243](https://github.com/sviridovski/Telegram-iOS/actions/runs/45111847167) · [green #250](https://github.com/sviridovski/Telegram-iOS/actions/runs/45240852665) · [new #251](https://github.com/sviridovski/Telegram-iOS/actions/runs/45264803031) · [navigation-fix commit](https://github.com/sviridovski/Telegram-iOS/commit/caf15ec7e8dac8bdf3bdcf8b80c595be5275f147).

**Important:** A feature commit existing, CI job completed, all CI jobs green, IPA created, IPA installed and behavior confirmed on iPhone are **six different facts**. Do not conflate.

## 2. Immediate next task: review #251 and test navigation

1. **#250 is green, installed** and author lookup works (verified by user + screenshot); however tapping search result does nothing. Prior code silently cast Mx/UIKit `UINavigationController` to Telegram's `Display.NavigationController` and also required optional `message.enginePeers[message.id.peerId]`.
2. The new **#251** [commit caf15ec](https://github.com/sviridovski/Telegram-iOS/commit/caf15ec7e8dac8bdf3bdcf8b80c595be5275f147) changed ONLY `submodules/ChatListUI/Sources/GoldgramAuthorSearch.swift`: create native chat using `context.sharedContext.makeChatController(context:chatLocation:subject:...)` from exact search result `message.id.peerId` and message ID; **push onto the EXISTING UIKit navigation stack** instead of casting, keeping search screen underneath. UIKit interactive back-swipe enabled. It does NOT modify database, collector or Mx patch files.
3. Check **#251 CI** [run 45264803031](https://github.com/sviridovski/Telegram-iOS/actions/runs/45264803031). At this snapshot `queued`. Read mx/native/build conclusions and artifacts; do not call green until completed. If compiler failure, inspect first exact error and fix in `gold-next-243-author-search`, not `port/telegram-13.2`.
4. When #251 actually green, user to install and **tap a real search result → opens exact source chat at message → swipe left edge to right returns to the SAME author result list, preserving author/scope/scroll/results**. Test private, group and channel discussion; account-switch and deleted targets separately. This navigation is **not device-verified yet**.
5. Keep warmed CI cache: **#250 native compiled cold for 6054.604s, 7539 local + 791 worker + 1773 internal, 0 disk-cache hits; successfully SAVED Bazel cache** under key family `gold-next-bazel-xcode27-b058a733...-a159ca6...` (saved 20:32:47 UTC, 7.14 GiB measured), and Mx cache also saved. #251 same branch and identical Mx cache input hashes; expect Mx exact cache hit and native Bazel restore-prefix hit. Verify actual restore messages, Bazel disk cache-hit count, durations. Don't change cache keys or workflow just for this fix.

### CI speed evidence for #250

- **Mx** success in ~12 min on freshly created branch; **native** started at 18:45:31 UTC and completed at 20:33:14 UTC; **build** success at 20:35:36 UTC.
- Cache restore finished in 1s **with empty restored key**; native Bazel build `Elapsed time: 6054.604s`, `10103 processes: 1773 internal, 7539 local, 791 worker` (cold build).
- Native after clean build stored a **reusable 7.14 GiB disk cache below the 12 GiB cap**, the `Save bounded Bazel disk cache` step was successful; Mx output cache saved by final build. **This is the expected path to a much faster #251; check the actual evidence**.

## 3. Feature acceptance checklist (partially verified)

- **Archive/Mx UI**: direct personal + group tiles, compact Ghost arrangement, original existing sections/other Mx actions intact; no crash after opening app, switching categories or selecting peer.
- **Author search**: #250 tested on iPhone — real author search returns messages, but result tap/navigation FAILED. #251 attempts to fix. Choose real peer from saved contact name (Cyrillic case and **е/ё**), @username; search inside selected chat / across locally known root+archive; show chat title, message excerpt and exact time; tap navigates to exact message. Confirm it never attributes anonymous admin, channel post or forward incorrectly, and never marks messages read.
- **Data integrity**: post-upgrade original SQLite remains unchanged except expected new captured data; deleted/edited journals stay separated and previously stored messages remain available.
- **Correctness**: false '0 matches' or missing dialogs must be diagnosed against explicit 1000-dialog/10-page limits and possible Telegram RPC errors; do not assert completeness.
- **Background + Live**: network type LTE vs Wi-Fi, after app suspension/foreground, delayed original reconciliation, intermediate edits across an independent account; the baseline collector must be left unchanged during current UI work.

## 4. Known open engineering problems

| Priority | Problem | Required evidence |
| --- | --- | --- |
| P0 | Verify #251 builds, exact-message tap navigation and interactive swipe back to results | all CI jobs+artifact, then actual iPhone test |
| P1 | 'Оригинал не получен' in comments/channels after delayed import or when Swiftgram suspended | event chain and **actual SQLite commit** |
| P1 | Fast multi-stage edits sometimes only preserve the final revision | controlled send/edit/edit test verified in collector DB and main DB |
| P1 | Some deleted posts lack reliable jump anchors after server message is gone | peer kind/id/message id, root post/discussion mapping and UI navigation test |
| P1 | Edit count shown in archive but not immediately in chat | local Mx event cache/update and rendered badge confirmation |
| P2 | Live cross-network catch-up, unknown sender/time labels | actual deployed Collector/Supervisor/Bridge versions + sanitized diagnostics |
| P2 | Avoid slow/cold CI cache, runner queue delays | cache restore/hit/miss, GC size, timings and runner labels |

## 5. Ground truth and files to check

- [CI YAML](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/.github/workflows/build.yml) (xcode-27, parallel mx/native/build, 10 GiB GC/12 GiB disk cache).
- [Author search](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/submodules/ChatListUI/Sources/GoldgramAuthorSearch.swift).
- [Mx integration](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/build-system/gold-next/prepare_mx.py).
- [SQLite native store](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/build-system/gold-next/GoldgramHistoryStore.swift).
- [Read-only Live v1 base specification](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/build-system/gold-next/GOLDGRAM_LIVE_SETUP.md).

## 6. Update discipline

On each **confirmed** completed task, edit this file in its **documentation-only branch**, replacing stale HEAD/run/status with real GitHub facts. Keep a short link to exactly which user/device test was confirmed. If Native logs could not be read, say **'not verified'**, not success.

Keep last known green CI and last user-tested IPA separate. Do not introduce secret/identity-bearing data into the public documentation. For the newest development branch always verify latest GitHub HEAD (do not rely on this dated snapshot).
