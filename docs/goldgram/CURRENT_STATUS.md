# CURRENT_STATUS — verified checkpoint

> **Canonical project passport (part 2/3).** Snapshot **2026-11-23**, GitHub API queried around 19:30 UTC; **not a live dashboard**. Always query the repository and workflow runs before resuming. [PROJECT_CONTEXT](./PROJECT_CONTEXT.md) · [DECISIONS_LOG](./DECISIONS_LOG.md).

## 1. Current repo and branch reality

Repository: [sviridovski/Telegram-iOS](https://github.com/sviridovski/Telegram-iOS). Historical development is Telegram iOS **13.2** (port from 12.9.2). The old branch **gold-next is stale**; do not assume it's currently active.

| Item | Verified at snapshot |
| --- | --- |
| Active original development branch | **port/telegram-13.2** |
| Original branch head at the latest transfer | **38400f8cf6d6e87b2031eaa17c6c46f987ca98af**; CI **#249 failure** |
| Most recent confirmed green baseline | CI **#243**, SHA **ff67a435fd667b16bdc3858f860e0f47e8cacb4e**, all jobs success |
| Safe isolated feature branch | **gold-next-243-author-search** |
| Feature branch HEAD | **a159ca601d72750556f045ebb8820c4541f64ba0**; commit created with **one parent = green #243** |
| Latest feature CI | **#250**, run ID **45240852665** |
| #250 at last API check | **mx success; native in_progress** at `Build clean Swiftgram`; final IPA **NOT YET CONFIRMED** |
| Dedicated documentation branch | **goldgram-project-docs**; documents-only, no CI push trigger, from #243 |
| Verified on actual main iPhone | The last *known* usable baseline includes #234/#243-era features; do not treat #250 as installed or tested without explicit user confirmation |

Sources: [green #243](https://github.com/sviridovski/Telegram-iOS/actions/runs/45111847167) · [red #249](https://github.com/sviridovski/Telegram-iOS/actions/runs/45233819435) · [in-progress #250](https://github.com/sviridovski/Telegram-iOS/actions/runs/45240852665) · [feature commit](https://github.com/sviridovski/Telegram-iOS/commit/a159ca601d72750556f045ebb8820c4541f64ba0).

**Important:** A feature commit existing, CI job completed, all CI jobs green, IPA created, IPA installed and behavior confirmed on iPhone are **six different facts**. Do not conflate.

## 2. Immediate next task: complete/review #250

1. Check **newest workflow run and head branch SHA** using GitHub Actions API, do not rely on the above frozen text.
2. For **#250**, check **mx + native + build**, first meaningful error if red, runtime of each step, final artifacts, and Bazel cache summary. Don't interpret `queued/cancelled` without a runner as a Swift compile error.
3. If red: use **gold-next-243-author-search** for a **small targeted correction**, rerun CI, retain #243 as clean recovery point. If green: confirm final IPA artifact, then conduct actual iPhone search/UI tests.
4. The #250 change brought **#244 UI + #245 author search**, with updates through #249, directly onto **green #243** rather than inheriting the failed commits. It also changes author search to **TelegramEngine API** to avoid the PostboxImportCheck from #249.
5. **Do not publish a new commit merely because an old run was slow**. Diagnose whether the new branch has no warm Bazel cache, whether code truly fails, or a GitHub xcode-27 hosted runner is unavailable.

### Why #250 is slower than #243

- Green #243 runner started in ~3s, `native` compiled in ~3m41s, Bazel reported **8294 disk cache hits / 10103 processes** and a cache restore lasting ~99s.
- #250 waited ~5m14s for hosted macOS runner and its native job restored cache in ~1s, a **strong cold-cache indicator**, but actual cache miss must be verified from complete Native logs.
- At the snapshot, `mx` #250 was already successful, Native remained in `Build clean Swiftgram` for far longer than #243. **Unknown final result**. New branch scope can block cache reuse from sibling branch.

## 3. Feature acceptance checklist (not yet proven)

- **Archive/Mx UI**: direct personal + group tiles, compact Ghost arrangement, original existing sections/other Mx actions intact; no crash after opening app, switching categories or selecting peer.
- **Author search**: choose real peer from saved contact name (Cyrillic case and **е/ё**), @username; search inside selected chat / across locally known root+archive; show chat title, message excerpt and exact time; tap navigates to exact message. Confirm it never attributes anonymous admin, channel post or forward incorrectly, and never marks messages read.
- **Data integrity**: post-upgrade original SQLite remains unchanged except expected new captured data; deleted/edited journals stay separated and previously stored messages remain available.
- **Correctness**: false '0 matches' or missing dialogs must be diagnosed against explicit 1000-dialog/10-page limits and possible Telegram RPC errors; do not assert completeness.
- **Background + Live**: network type LTE vs Wi-Fi, after app suspension/foreground, delayed original reconciliation, intermediate edits across an independent account; the baseline collector must be left unchanged during current UI work.

## 4. Known open engineering problems

| Priority | Problem | Required evidence |
| --- | --- | --- |
| P0 | Complete #250 native build; possible Swift compiler errors still unknown | first real Native error or all CI jobs success |
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
