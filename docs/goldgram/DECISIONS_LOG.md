# DECISIONS_LOG — engineering history, evidence and recovery

> **Canonical project passport (part 3/3).** Historic decisions and important evidence; unlike [CURRENT_STATUS](./CURRENT_STATUS.md), old entries should be **appended, not silently rewritten**. [PROJECT_CONTEXT](./PROJECT_CONTEXT.md). Dates/versions attributed to a user test are not GitHub-verified deployment claims.

## 1. Major design decisions

| Area / epoch | Decision / evidence | Invariant / action |
| --- | --- | --- |
| Telegram iOS 12.9.2→13.2 | Port Goldgram to Telegram iOS 13.2 with existing Ghost/Mx feature compatibility | Avoid 12.9 API assumptions on 13.2 |
| SQLite #64–#67 | Account-scoped Goldgram SQLite v2 stores original, revision and delete event, never a guessed original | One database per authorized account, preserve schema and WAL |
| #131–#133 | Added original capture evidence and attempt/commit fields to **same** SQLite | COMMIT is evidence; callbacks and source labels alone are not |
| Native capture/foreground | Collect real Telegram updates via TelegramCore/Postbox, record actual edit/deletion | Do not force chat openings, read receipts or online presence |
| UI cache / grouping | Archive and chat badges must read precomputed/async projections, not perform repeated SQLite scans in render | Protect scroll smoothness, avoid full scan per message |
| Separate deleted/edited journals | Allow one category to be cleared without corrupting the other | No global destructive delete or reset |
| Independent collector | Jailbroken iPhone 8 has independent Telegram session/collector DB | Source is read-only for Live; main phone uses **its existing SQLite** |
| Live Bridge | TLS-pinned HTTPS pull with pairing secret, source cursor ack only after COMMIT and dedup | Retry failures safely; never expose Telegram auth/session/key material |
| Cross-network Live | VPS/reverse SSH/HAProxy passthrough experiments | A tunnel working once is not proof of mobile/background delivery |
| Author search UI | Search by **real Telegram author ID** through TelegramEngine, not by text word | No false attribution, no extra account/DB/read marking |
| CI architecture | Split Mx and Native builds; native Bazel disk cache GC 10 GiB, max upload 12 GiB, parallel xcode-27 | RAM is ~7 GiB, not 12; keep cache warm and distinguish runner outage |
| Long-chat project continuity | Three permanent versioned documents in documentation-only branch | New chat reads docs then verifies newest GitHub API; docs should not launch CI |

## 2. Historic observations: original capture

**Early geographic/background experiments — not universal performance numbers:**
- Test **#134** without geolocation: reported **1/15** originals.
- Test **#135** with geolocation: reported **8/8** originals, about **135** archive entries / **65 COMMIT** at that point.
- Test **#136** without geolocation: ~335 total, 275 confirmed and 237 COMMIT in a particular session; **11 edits with zero recovered originals**.
- Interpretation: these runs reveal scheduling/capture gaps in their exact conditions; they **do not prove** CoreLocation causes Telegram updates or that geo is necessary/sufficient. Later releases changed several layers, so never compare percentages without identical event sets.

**Intermediate edits / independent collector:**
- Controlled send/edit/edit scenario: message texts **1→12→123** and **2→22→222** with roughly 10s between edits; an older collector/live-import combination displayed only last edits. This is the critical regression test.
- Separate historic follow-up with Collector/Supervisor **V2.4** reportedly captured all intermediate stages/Bridge records. It does **not** establish all later installed versions, always-on delivery, or a successful import into all possible dialogs.
- Import and network tests across **#215–#218** indicated local Wi-Fi in some conditions preserved originals better than remote Live; some originals arrived only after app reopened/after delay. Do not misclassify an asynchronously recovered original as permanently missing.

**Trustworthy coverage definition:** Count unique first unedited captures actually written and distinguish independently verified edits, delete updates, unknown origin, replay duplicate and observation time. Use receiver SQLite events and per-source cursors, not UI badge count alone.

## 3. UI / archive decisions and regressions

- Mx archive categories: personal, groups/chats, channels, deleted/edited; group/linked discussion projection, thread jump and native metadata bridge. Preserve old Mx indices/action tags and Ghost settings.
- User test around **#234** cleared only **edited journal (~2700 records, roughly 40s)** while deleted journal remained. #235 introduced index/fast-path improvements. **Clearing one category must never wipe the other.**
- Mx displayed edit details/revision count inside archive, yet chat bubble lacked the live count on some versions; **edit count ≠ reactions**. Tests must inspect both chat bubble and archive and avoid DB calls in layout.
- Some deleted messages later appeared only after visiting/scanning the source chat; the goal is automatic accurate deleted journal without opening every chat. Never claim solved until tested with newly deleted messages under realistic background conditions.
- After server-side source changes, deleted-message jump could fail. Keep exact chat/scope/root-post/thread anchor, allow honest failure for server-removed message rather than arbitrary navigation.
- **#244 UI** modified dashboard arrangement and personal/group archive shortcuts. It was not established as working IPA; subsequent #245 added search by true author with two scopes and navigation.

## 4. GitHub Actions and correction chronology (Nov 21–23, 2026)

| Run | Result, verified from GitHub jobs | Meaning |
| --- | --- | --- |
| #235 | Success, older workflow | At this stage single-stage builds often took ~37 min |
| #239, #240, #241 | Success (Mx + Native + Build) | Split jobs and warm cache improved roundtrip to ~14 min |
| **#243** | **SUCCESS**, SHA **ff67a435fd667b16bdc3858f860e0f47e8cacb4e**; runner starts in ~3s | **Confirmed clean base**; native Bazel elapsed 214.522s / 8294 disk-cache hits out of 10103 |
| **#244** | Failure overall; **Mx + Native cancelled without runners**, Build skipped | Cannot infer a Swift source error from these jobs |
| **#245** | Same: jobs cancelled without runners | Author search source landed, but not proven compiled |
| **#246** | Mx failed; Native cancelled | Real Mx compiler error: `setSectionHeaderTopPadding:` availability, iOS 15 guard required |
| **#247** | Mx failed; Native cancelled | Same availability issue |
| **#248** | Mx + Native cancelled before runners | Infrastructure/runner capacity; not compilation evidence |
| **#249** | Mx success; Native failed early on **PostboxImportCheck** | New author-search file directly imported Postbox and used `.postbox`, forbidden for new ChatListUI code |
| **#250** | **SUCCESS** mx/native/build; commit parent is exactly green #243. Installed on iPhone. Search by author returns results; tap to open chat FAILED. Native cold build 6054.604s. Bazel cache saved successfully. | Continue with #251 navigation fix; do not misclassify successful search as successful jump |

Artifacts/links: [#243](https://github.com/sviridovski/Telegram-iOS/actions/runs/45111847167) · [#249](https://github.com/sviridovski/Telegram-iOS/actions/runs/45233819435) · [#250 GREEN](https://github.com/sviridovski/Telegram-iOS/actions/runs/45240852665) · [#251 queued](https://github.com/sviridovski/Telegram-iOS/actions/runs/45264803031) · [navigation fix](https://github.com/sviridovski/Telegram-iOS/commit/caf15ec7e8dac8bdf3bdcf8b80c595be5275f147).

**Important failure classification:**
1. **queued/timeout/cancelled without runner** ⇒ GitHub infrastructure, not code compile result.
2. **failed job after runner, with compiler error** ⇒ source/SDK problem; inspect FIRST meaningful error.
3. **green job but other failed/skipped** ⇒ do not call entire run green.
4. **all CI jobs success** ⇒ compiled artifact exists, but behavior still requires iPhone test.

The public [macOS runner availability issue #15291](https://github.com/actions/runner-images/issues/15291) had relevant reports including xcode-27; support described hosted macOS capacity problems and 15-minute automatic cancellation. Never initiate repeated blind commits to fix runner capacity.

## 5. CI cache diagnosis and performance policy

- Native Bazel action-cache key consists of toolchain/dependency fingerprints plus commit SHA, with a restore-prefix. Mx cache uses toolchain fingerprint and Mx source inputs. Native cache GC target 10 GiB, saved cache cap 12 GiB **on disk**.
- In successful **#243**, a ~3.48 GB compressed native cache restored in ~99s; 8294/10103 Bazel actions were disk-cache hits, native build finished in ~3m41s. Runner itself had 3 logical CPUs and **7 GiB RAM**.
- On **#250**, waiting for xcode-27 VM ~5m14s, cache restore step ~1s and native compile far longer than #243. Probable **cold cache due to separate branch scope**; verify final job logs before claiming exact cache miss. Avoid unnecessary new CI branch for future fixes; don't modify compiler flags or reset Bazel cache casually.
- Target repeat CI **15–20 minutes** when warm; if >20 min, first inspect runner wait, restored key/hit rate, Bazel elapsed/critical path, cache upload/save and Mx per-step time. Do not trade correctness for speed.

## 6. New evidence — 2026-11-23 author-search navigation and warmed CI cache

- **#250 complete:** GitHub Actions [run #250](https://github.com/sviridovski/Telegram-iOS/actions/runs/45240852665) finished **all three jobs green**, IPA artifact exists. User installed it and sent a screenshot proving that author search returned multiple date-stamped messages. However **tapping the message had no effect**.
- **Cause in source:** `GoldgramAuthorSearch.swift` requires `navigationController as? Display.NavigationController`, but Mx's search UI is embedded in a **UIKit UINavigationController**; a second guard requires `EngineMessage.enginePeers` to contain the peer despite message.id already specifying it. Either guard silently abandons the tap.
- **#251 proposed correction:** [commit caf15ec](https://github.com/sviridovski/Telegram-iOS/commit/caf15ec7e8dac8bdf3bdcf8b80c595be5275f147) uses `context.sharedContext.makeChatController` with exact `message.id.peerId` and `.message(id: .id(message.id), ...)`. Push onto same UIKit nav stack; back button / left-edge swipe should pop and reveal the *unchanged* search screen/results/scroll offset. **Device success NOT yet verified**.
- **CI cache:** #250 cold Bazel: **6054.604 seconds**, 7539 local, 791 worker, 1773 internal, **zero disk-cache hits**. After finishing, step reported `Bazel cache save eligible: true`, **7,480,636 KiB** and `Cache saved with key: gold-next-bazel-xcode27-b058a733...-a159ca6...`. Mx cache saved in final job. #251 runs on **same branch with unchanged workflow/Mx input files**, so check that Mx cache is reused directly and native restore-prefix hits saved Bazel cache before interpreting compile duration.
- **#251 run:** [45264803031](https://github.com/sviridovski/Telegram-iOS/actions/runs/45264803031) was **queued** when added. It has not been declared green, nor installed.
- The ongoing architecture/collector status did not change in this navigation-only commit; no changes to collector, bridge or SQLite.

## 7. How to continue in a new ChatGPT chat

1. Read **all three Markdown docs** from branch **goldgram-project-docs**: PROJECT_CONTEXT, CURRENT_STATUS, DECISIONS_LOG.
2. **Verify latest state externally**: repository branch SHA, last green workflow, latest run jobs/steps/artifacts and any actual installed-IPA test results provided by user. The documents are a checkpoint, not a real-time source.
3. Work on the most recent unfinished task; don't ask the user to restate longstanding architecture.
4. Apply **one targeted edit per CI run**, use static checks first, ensure privacy and SQLite consistency. Never assume an overall GitHub Actions `failure` means a Swift compiler error.
5. On task completion **update CURRENT_STATUS in this docs branch**, append verified results to this file and change PROJECT_CONTEXT only for real architecture changes. Include commit SHA/run URL and test conditions, avoid personally identifying or secret values.

**Copy-paste handoff prompt:**

> Бро, продолжаем Swiftgram Gold / Goldgram в обычном Chat внутри Goldgram project. Прочитай docs/goldgram/PROJECT_CONTEXT.md, CURRENT_STATUS.md и DECISIONS_LOG.md из ветки goldgram-project-docs репозитория sviridovski/Telegram-iOS. Затем проверь фактический HEAD и GitHub Actions и продолжи последнюю незавершённую задачу. Не ломай SQLite, Ghost и Collector. Не считай код проверенным без зелёной CI и iPhone-теста. После результата обнови эти три документа (только изменённые части) и сообщи точные SHA и ссылки.

## 2026-11-24 local — #251 device regression, #252 candidate

- [#251](https://github.com/sviridovski/Telegram-iOS/actions/runs/45264803031) all jobs green, installed; user video shows tap leads to malformed/empty native chat in Mx. UIKit embedding was wrong for Display layout. Ghost exception screenshot shows overlapping text and inactive decorative add icon (no selection handler in pinned Mx source).
- Confirmed #251 hot cache: 8279 disk hits of 10103, Bazel 562.346s vs 6054.604s on #250; 9,040,776 KiB cache saved and Mx exact hit. Queue ~7 minutes. Reuse same branch; do not alter cache keys. Mx must rebuild when its recipe changes.
- [#252](https://github.com/sviridovski/Telegram-iOS/actions/runs/45287862914) commit 5fd55a7acad0bdc380e0b4e824deab14adeb6aec: native handoff via existing GoldgramArchiveReturnController + account validation + retained modal; contact picker with user confirmation through existing MxGhostExceptions storage; restore multiline footer sizing and add row. Three source files changed, no DB/collector/bridge/filter changes. CI in progress at snapshot; actual device results not yet verified.
