## CURRENT HANDOFF — 2026-10-15 #75–#76 group/channel live capture (READ FIRST)

- User has **NO test partner or second Telegram account**, requested real group comments/discussion messages and channel news appear under existing Goldgram tabs to test #74 archive UI on public data. #74 GitHub Actions GREEN, user screenshots confirm the three category screens display empty event archive. No personal edit readback verification yet; previous #74 device acceptance is UI-only.
- **New functional atom: capture NEW observed texts of groups (peer_kind 1), supergroups/discussions (2), and channels (3), and list unedited public posts in the archive.** Existing personal category stays edit/delete-event-only. No backfill, historical scroll import, group-to-channel comment association guesses, deletion capture, channel edits, or inline chat bubble changes.
- **#75 code commit** `210fa4d2bffffeb4291dcb383f83fccbc6d707ad`, [Actions #75](https://github.com/sviridovski/Telegram-iOS/actions/runs/38671006019). Changed only `GoldgramHistoryStore.swift`, `AccountStateManagementUtils.swift`, the Gold Next workflow and new `test_sqlite_public_capture.py`. Incoming group + accepted `updateNewChannelMessage` only. Host classifies CloudGroup via TelegramGroup and CloudChannel via **confirmed TelegramChannel.info** `.group`/ `.broadcast` so discussion groups are distinct from broadcast channels, never namespace-only guessing. Writes under explicit authenticated account, opt-in `GoldgramSQLiteCaptureEnabled`, existing serial SQLite queue/transaction/unique keys, no extra network/third-party server and no content logging.
- SQLite `archiveIncoming` is generalized with peer_kind argument **default 0** to preserve personal capture ABI. Public capture has **new** `goldgram_archive_public_original_v1` symbol; old MX, Anti-Edit/Anti-Revoke, app ID, signature, Help long-hold and existing navigation unchanged. Reader now displays group/channel observed originals even without edit/delete events; personal unchanged. Metadata sender/time/thread is included only if actually known. A first live capture is a known observed version, but this does **not** recover unseen earlier edits or channel-post/comment root associations.
- Focused self-review identified **test-only** relative-path issue in #75 `test_sqlite_public_capture.py` before CI finished; #76 immediate corrective **test-only** commit `825bdbb4c3275d96ed859eeff702a93f5e032308` fixes `root.parents[2]` → `root.parents[1]` because `root=Path(__file__).parent`. [Actions #76](https://github.com/sviridovski/Telegram-iOS/actions/runs/38671084000) has launched; both CI outcomes were **not final** when this documentation was written. **#75/#76 together are ONE public-capture functional atom, NOT device-tested.**
- **Next:** verify #76 full CI, including new Python SQL/source test, actual Theos/MX Swift compilation, Bazel Swiftgram compile, IPA. If RED, investigate first real failing log and correct only this atom. If GREEN, user installs #76, confirms SQLite switch ON, **waits for a NEW channel publication or NEW group/discussion comment while Swiftgram is active**, then visits Goldgram → Channels or Groups & Chats and taps the numeric dialog to see text. Old posts on scroll are not in scope; group/channel edit histories and precise jump/inline rendering require separate later atoms. If still empty after confirmed live update, first diagnose capture/classification/readback, not start a new feature atom. Update docs with final CI and user device verification once known.

---

## 2026-10-15 — #74 CI GREEN, archive UI opens, data readback NOT YET VERIFIED

- Code commit `098fe92341385a42149fee6da6f5ab7593fa43c2`, GitHub Actions [#74](https://github.com/sviridovski/Telegram-iOS/actions/runs/38660592602) **completed SUCCESS**.
- User installed #74 on iPhone and supplied screenshots of **Личные сообщения**, **Группы и чаты**, **Каналы**. All three screens open without reported crash and display **"Записей пока нет / Локальная история текущего аккаунта"**. This confirms UI route and successful reader response/empty event query, **not** successful message/edit capture or presence of SQLite revision rows.
- Code review confirmed archive SQL shows only messages with `events.event_kind IN (1,2)` or deleted flags; ordinary original captures do **not** appear. Capture hooks are opt-in (`GoldgramSQLiteCaptureEnabled`), only incoming personal texts and real edits are currently recorded; group/channel and deletion capture are future atoms. Existing MX Anti-Edit and SQLite event capture are independent; old MX history cannot be assumed imported.
- **Next device test before further code:** confirm SQLite toggle ON; keep Swiftgram in foreground; another user sends a NEW incoming personal text, edits that exact message twice; reopen Personal archive; expect dialog and known original + final edit. If still empty, diagnose underlying capture/reader from concrete repro (without another feature atom); do not invent rows or assume success. Do not mark #74 fully device-accepted for SQLite readback until that test passes.
- No additional code commit or next feature atom authorized yet. Stable last fully device-approved code through #73; #74 UI confirmed but archive content unverified.

---

## ACTIVE HANDOFF — 2026-10-15, Goldgram SQLite browser #74 (READ FIRST)

- **#73** corrective commit `9908af79bc9f37747cfdbca7fcd008e130fb247e`, GitHub [Actions #73](https://github.com/sviridovski/Telegram-iOS/actions/runs/38552208819) **GREEN / SUCCESS**. User explicitly reported **iPhone verification: "Бро, все нормально, проверил, давай дальше"**. It confirmed app/menu stability after #73, **not** an in-app SQLite readback (reader had no UI then). This closes the #72-73 functional atom.
- **#74** code commit `098fe92341385a42149fee6da6f5ab7593fa43c2`, [Actions run_number #74, ID `38660592602`](https://github.com/sviridovski/Telegram-iOS/actions/runs/38660592602). **CI IN PROGRESS** at documentation time. DO NOT CALL GREEN or claim iPhone test; inspect full CI before asking user to install. Changed `build-system/gold-next/GoldgramHistoryStore.swift`, `GoldgramArchiveScreen.swift` (new), `prepare_mx.py`, `test_sqlite_browser.py` (new), `.github/workflows/build.yml`, and `submodules/TelegramUI/Sources/SharedAccountContext.swift` only.
- **One functional atom #74: account-bound native local archive browser.** Existing #71 Goldgram → Deleted & Edited category buttons dynamically open a new `GoldgramArchiveScreen` UITableViewController in pinned Mx; the original MX setting keys/rows and "Помощь" long-press remain intact. Browser asks `GoldgramArchiveReader.query` for paginated (30-at-a-time) event-bearing dialogs, then records with confirmed original as primary and latest saved edit dimmed as subtitle. Legacy global MX last-user value is *not* used for archive ownership.
- Account scope: authenticated `SharedAccountContext.activeAccountsValue.primary.account.peerId` publishes verified account ID over `goldgram_bind_active_account_v1`; switching accounts publishes 0 until a new primary resolves. Reader has an NSLock-protected active-ID gate both **before** SQL and **at completion**; existing browser fails closed if account changes. SQLite READONLY/WAL, off-main queries, no cloud writes or content logs; no data migration or new capture added.
- **Caveats / not implemented:** browser currently shows numeric peer IDs ("Диалог #...") rather than verified display names; only incoming personal text originally captured in #66 and edits in #68–70 appear. Groups/channels are empty unless future reliable capture exists. No full revision timeline, deletions capture, inline modifications in normal chat bubbles, native jump-to-message/thread, tombstones, or automatic old MX UserDefaults migration. SQLite stores received observations, not messages never seen during iOS suspension.
- **NEXT:** check #74 CI. If RED, inspect **first actual failing test/compiler step**, fix only #74; avoid another feature. If GREEN, user tests Help long-press, three categories open a **real** screen (not old placeholder), personal edit archive has a dialog + stored original/edit, groups/channels show honest empty state, other MX controls work, relaunch and switching accounts does not mix histories. User needs to confirm before any next atom. After user acceptance, plan scoped next atom for trustworthy peer names / recorded deletion events / richer history and eventually native navigation and inline edits.

---

## ACTIVE CI FIX — #72 RED → #73 compiling (2026-10-14)

- **#72** `a7081766b50b9c9c9a31ef4342ea56f1419811ca`, [Actions #72](https://github.com/sviridovski/Telegram-iOS/actions/runs/38522376163) **COMPLETED FAILURE**. Targeted SQLite schema/edit/reader checks **passed** at workflow step 9; actual Theos Mx Swift compilation failed at step 10 in `GoldgramHistoryStore.swift:692`. Both compiler errors: `cannot convert value of type 'Int' to expected argument type 'Int32'` for `offset` and `limit` in `GoldgramArchiveReader.query`'s call to `read`. Host Swiftgram compilation and IPA packaging were skipped, so #72 has **no validated installable artifact**.
- **Same functional atom, corrective build #73:** code commit `9908af79bc9f37747cfdbca7fcd008e130fb247e`, [Actions #73](https://github.com/sviridovski/Telegram-iOS/actions/runs/38552208819), initially **QUEUED** (not GREEN/device-tested at this documentation snapshot). Only changed `build-system/gold-next/GoldgramHistoryStore.swift`: safely cast bounded `offset` and `limit` to `Int32`; use `Int32(exactly: peerKind) ?? -1` and reject invalid peer kinds rather than trapping on a hostile/out-of-range caller value. No changed schema, SQL queries, settings, build dependencies or GUI.
- Focused self-check: real Swift compiler type-checked a locally constructed equivalent call/guard signature (PASS); additionally verified the modified source has bounded range guards, safe peer type conversion, and unchanged read-only queries. This is **not** a full Mx or Swiftgram build: wait for complete #73 GitHub CI.
- User-verified stable UI reference remains #71 (three new history folders, placeholder content). **Next:** if #73 RED, inspect first failing compile/build line; if GREEN, have user install and test application/menu/Anti-Edit/capture toggle after restart. Reader module is still not connected to the placeholder UI; do not claim in-app SQLite browsing works. Only after acceptance: account-context-bound UI reader atom, with no account inference from global UserDefaults.

---

## CURRENT HANDOFF — 2026-10-14, #71 device verified / #72 read-only reader in CI

- **#71** code `d295687b01d40e5c49a9b9d761de2c34e3dd5ab3`, Actions run **#71** (ID `38509108389`) [SUCCESS](https://github.com/sviridovski/Telegram-iOS/actions/runs/38509108389). **User's iPhone verification:** all three new category folders open and display the planned placeholders; no SQLite reader visible yet. This is an acceptance of the #71 navigation-only UI atom, not content capture/readback.
- **#72** code `a7081766b50b9c9c9a31ef4342ea56f1419811ca` on `gold-next`, Actions run **#72** (ID `38522376163`), [live CI](https://github.com/sviridovski/Telegram-iOS/actions/runs/38522376163). **CI in progress when documented; not GREEN or device-tested yet.** Changed only `build-system/gold-next/GoldgramHistoryStore.swift`, new `test_sqlite_reader.py`, and its CI invocation in `.github/workflows/build.yml`.
- **Implemented in #72, conditional on CI:** `@objc(GoldgramArchiveReader)` with async off-main, bounded SQLite READONLY `query:completion:` entry point taking an **explicit positive authenticated account ID** from a future caller; no fallback to the old ambiguous `MxLastKnownUserId`. Two queries: filtered event-bearing dialogs per category (personal = kind 0, groups = kinds 1/2, channels = kind 3) and paginated message records with known/unknown originals, last revision, revision count and timestamps. No DB creation, migration or network access when reading. Reject invalid inputs, distinguish absent archive/incompatible schema. No existing Mx functionality or UI is changed.
- **NOT implemented in #72:** a native caller supplying the active account context, history presentation in the three #71 folders, peer display names, new group/channel capture, deletion capture, native message navigation, inline dimmed edits and tombstones. Existing folders correctly remain placeholders until an independently tested UI/wiring atom. SQLite currently captures **incoming personal text only** when opt-in is enabled; other categories are not magically populated.
- **NEXT:** check #72 full CI. If RED inspect only the first failure and fix the same atom. If GREEN, verify build/device stability first; then next dedicated atom wires the native account-context identity and account-scoped reader to the Goldgram folder UI, without guessing identities. Follow with group/channel captures and trustworthy navigation/display each independently. Preserve `golden/` and old MX cache.

---

## CURRENT HANDOFF — 2026-10-14, #70 verified / #71 history folders in CI

- **#70** code HEAD `819c9953457077486f224e421046b11e3fbc9414`, Actions run **#70** `38497767443`, [CI completed SUCCESS](https://github.com/sviridovski/Telegram-iOS/actions/runs/38497767443). **User subsequently confirmed on iPhone:** "Проверил, все работает." Treat this as device acceptance for app/UI/MX edit regressions, **not** proof of SQLite rows because no archive reader exists yet.
- **#71** code commit `d295687b01d40e5c49a9b9d761de2c34e3dd5ab3` on `gold-next`; real Actions run number **#71**, ID `38509108389`, [build](https://github.com/sviridovski/Telegram-iOS/actions/runs/38509108389). **In progress when recorded; no GREEN or device claim.** Only `build-system/gold-next/prepare_mx.py` changed.
- **#71 UI-only scope:** append **Личные сообщения / Группы и чаты / Каналы** as separate navigable folder rows within Goldgram → Deleted & Edited. Existing MX row indices, toggles and feature keys retained. Folder contents explicitly report **SQLite archive reader not connected yet**; no fake persisted records and no changes to the account-scoped SQLite write pipeline. The root Mx entry remains Support/Help long-hold ~3 seconds.
- **User's target:** per-account archive by category → dialog → event, open the exact native peer/thread/message when a reliable anchor exists; show confirmed original prominently with latest edit subdued below instead of relying only on the MX pencil; deleted events and fallback tombstones; no guesses about linked channel posts. These are **future separate atoms**, not features claimed in #71.
- **NEXT:** finish #71 CI and diagnose only the first actual failing step if RED. After GREEN, user checks three new subfolders, unchanged capture switch/Anti-Edit/Anti-Revoke, app launch/restart. Only after user acceptance: implement account-safe SQLite **reader** + category/dialog/event lists, then group/channel and deletion capture, native navigation, inline edits, tombstones as isolated builds. Exact ordering can be refined per verified dependency; do not combine all changes or overwrite historical MX defaults.

---

## CI #68–#70 failure diagnosis — 2026-10-14 (CURRENT / READ FIRST)

- User provided screenshot: runs **#68** and **#69** both RED. GitHub job steps and full raw job logs were inspected: **both failed at step 9, `Validate Goldgram SQLite v1 to v2 migration`**, before Theos/Mx build and before Telegram Bazel compilation. Concrete traceback: `build-system/gold-next/test_sqlite_edits.py`, **line 31**, `AssertionError`.
- Root cause is **test-only**, not proven an app runtime failure: test asserted literal substring `'original_text, original_observed'` occurs in Swift source, but Swift SQL lists the columns on separate lines with indentation. Direct inspection confirms whitespace-tolerant regex `original_text\\s*,\\s*original_observed` matches correctly.
- Focused **#70 corrective commit** `819c9953457077486f224e421046b11e3fbc9414` on `gold-next`: change only one line in `build-system/gold-next/test_sqlite_edits.py` to `assert re.search(r"original_text\\s*,\\s*original_observed", source), ("Original columns not found in Goldgram Swift SQL")`. No changes to Swiftgram/Mx/SQLite runtime.
- Real GitHub Actions run_number **#70**, ID `38497767443`: https://github.com/sviridovski/Telegram-iOS/actions/runs/38497767443 . **In progress at this snapshot; NOT green or device-tested yet.**
- **NEXT:** wait for #70. If it passes first sqlite test gate, inspect the later actual compilation and packaging; if it fails later, obtain **job log and the first failing step/line** before any edit. When GREEN, user should install #70 (not older #68/#69) and verify app launch, Goldgram toggles, existing Anti-Edit/Anti-Revoke, and SQLite edit behavior as far as UI permits. New SQLite browser not yet implemented; passing app launch does not prove correct data persistence.
- Our tested safe reference remains **#67** / `bbacd59b3f512d9f8d685cec76ff22d18df4a7ad`, GREEN + screenshots. The whole #68–#70 sequence remains **ONE edit-capture functional atom**, with corrective commits only. No new features until this is green and iPhone-tested.

---

## CURRENT DEVELOPMENT STATE — 2026-10-13, SQLite edit capture (LATEST)

- User supplied screenshots of root Goldgram / Privacy & Features / Deleted & Edited and confirmed menus/legacy toggles open and operate on iPhone **after #67**. GitHub Actions **#67 GREEN**. Note: menu screenshot alone does **not** prove actual rows can be read from SQLite, because archive reader UI does not exist yet.
- Next *functional atom*: **SQLite edit revision capture** in `gold-next`. Base #67 commit `bbacd59b3f512d9f8d685cec76ff22d18df4a7ad`.
- First code commit `4a7aade1e8429dff2a8544ff2b84da87955d2b83` triggered CI run_number **#68**, run ID `38418467446`. Self-review found two SQL parameter-order bugs that could allow a green binary but prevent storing edits; DO NOT use the first #68 artifact for edit testing.
- Immediate corrective commit `78eb624459b30f73ba43a6f017233a54e154d757` triggered CI run_number **#69**, run ID `38418768848`. This is **a corrective build of the same #68 edit-capture atom**, not a new feature. Actual CI statuses were **in_progress** when recorded; verify #69 GREEN before iPhone installation: https://github.com/sviridovski/Telegram-iOS/actions/runs/38418768848
- Code: account-scoped `AccountStateManagementUtils.swift` taps **true incoming** private-chat `updateEditMessage` updates and calls new Mx C bridge `goldgram_archive_edit_v1`. Old Mx Anti-Edit/Anti-Revoke UI/logic is preserved, and existing `GoldgramSQLiteCaptureEnabled` switch remains **OFF by default**.
- SQLite serial storage queue + one transaction preserves original_text, updates metadata if known, appends ordered revisions with `revision_provenance=3`, inserts one edit event per actual text transition. Duplicate text repeated from an update does not create a new revision. Revert A→B→A creates another legitimate revision. Missing pre-edit original is **never invented**: `messages.original_text=NULL`, `original_observed=0`, first revision marked as observed EDIT (not original). No logging of bodies/identifiers.
- New CI script `build-system/gold-next/test_sqlite_edits.py` tests duplicate updates, reverts, account separation, unknown originals, rollback; corrective commit added tests **executing exact SQL strings extracted from Swift** with `archiveSQL`-style numeric-before-text parameter binding.
- **IMPORTANT NEXT:** Await #69 green and user test real iPhone. Test app launch and MX menu, receive incoming personal message, ask sender to edit twice, confirm original MX pencil badge and edit version reading, restart and verify; the new Goldgram SQLite event browser is NOT implemented so this is still only an indirect functional check, not an SQLite row readback. After that, next separate atom is safe account-scoped DELETION events (personal/global-ID ambiguity handled as unresolved), then groups/channels and UI.
- Remember proposed archival UI: Personal / Groups & Chats / Channels; click records to native chat/message/thread; show original prominent with edited text dimmed below; deleted items need local tombstone or fallback. Full design in `GOLDGRAM_HISTORY_SQLITE_PLAN.md`.
- Continue **one functional atom → corrective builds if needed → CI GREEN → user device test**. No energy/RAM atoms until history workflow is done.

---

## CURRENT CODE PROGRESS — 2026-10-13, atom #67 (READ BEFORE HISTORICAL ENTRIES)

- **#66** GitHub Actions run_number 66 GREEN; user reported the iPhone build works. Note: appearance of the toggle/app launch does **not yet constitute a database-content readback**, because the archive browser is still unimplemented.
- **#67** committed on active `gold-next`, SHA `bbacd59b3f512d9f8d685cec76ff22d18df4a7ad`. Real GitHub Actions run_number **67**, run ID `38402945569`: https://github.com/sviridovski/Telegram-iOS/actions/runs/38402945569. CI was **in_progress** at this documentation snapshot, not yet proven green or device-tested.
- #67 implements additive SQLite **v1 → v2** migration **under BEGIN IMMEDIATE/COMMIT**, rollback on failure, `PRAGMA user_version=2` on success, fail-closed on newer versions; preserves old dialogs, original_text, revisions, events, and unresolved deletions. New per-message columns: `sender_kind`, `sender_id`, `sent_at` (Unix ms), `thread_id`, `reply_to_message_id`, `root_channel_peer_id`, `root_channel_post_id`, `anchor_before_message_id`, `anchor_after_message_id`, `capture_provenance`; new revision provenance, browsing indexes.
- #67 also adds **actual metadata capture for newly observed incoming private-chat texts only** via `goldgram_archive_original_v2`, passing confirmed `AccountStateManager.accountPeerId`, user author ID if known, server timestamp, and thread ID if known. Existing original message contents are NEVER overwritten, missing metadata alone may be backfilled, and legacy v1 C entry point remains for compatibility. Linked channel-post context and original reply IDs remain **NULL until a future atom collects trusted mappings**; do not guess associations. Original certainty is recorded as live or catch-up; old v1 rows retain unknown provenance.
- CI now contains `build-system/gold-next/test_sqlite_schema.py`: real Swift v1/v2 DDL tested with a populated v1 database; verifies no data loss, indexes, v2 constraint, retry idempotence, rollback on simulated DDL failure.
- **NEXT:** verify actual #67 CI outcome. If red, only fix concrete failing CI step. If GREEN, user installs and confirms Swiftgram launches, long-hold Help opens Goldgram, SQLite toggle remains functional, messages arrive normally, prior saved MX anti-edit/revoke history and app push work, no crashes switching chats/accounts. Metadata lives in DB, no new visible history browser/inline revisions yet. Then one separately tested atom for real edited text capture and event version history, then deletions; roadmap for user-desired archive navigation remains below.
- Keep the #66 toggle OFF by default on clean installs, and continue **one atom → one commit → CI GREEN → user tests on iPhone**. Do not resume energy/RAM work yet.

---

- **2026-10-13 agreed future UX:** archive folders for Personal / Groups & Chats / Channels, tap event to open its original chat/topic/message, show confirmed original prominent with latest edited text dimmer directly below in the chat; deleted messages require a local tombstone/nearest-surviving-message fallback. Full design and independent atom plan are in `GOLDGRAM_HISTORY_SQLITE_PLAN.md`. No UI or server restoration is implemented yet.
## LIVE ARCHIVE ATOM #66 — 2026-10-13 (LATEST; READ FIRST)

- User reported iPhone test of **#65** succeeded; GitHub CI #65 **GREEN**.
- #66 code in active `gold-next`: commit `9f993dc5a2458a319a67cfb0b182e4acae884ea6`. GitHub Actions run_number **#66**, run ID **38388918610**, URL https://github.com/sviridovski/Telegram-iOS/actions/runs/38388918610. At this documentation snapshot the build was **in_progress, NOT yet confirmed green or device-tested**.
- #66 is the **first real, explicitly opt-in SQLite capture**. A new `GoldgramSQLiteCaptureEnabled` switch (OFF by default) appears inside Goldgram -> mixed MX features -> **Удалённые и изменённые** -> **Оригиналы в SQLite**.
- Scope of #66 is intentionally **incoming private-chat TEXT originals only**; no media, groups/channels, edits, deletion events, or history list screen yet. Keep legacy MX anti-edit/revoke working independently.
- Important: account identity comes **directly from TelegramCore's `AccountStateManagementUtils.swift` `accountPeerId`**, not stale `MxLastKnownUserId`. Host resolves a C ABI `goldgram_archive_original` function in Mx.dylib with `dlsym`; Mx writes asynchronously into per-account SQLite, deduped with `INSERT OR IGNORE`, preserving prior records.
- The host processes both live `updateNewMessage` and `updates.getDifference` catch-up. New live messages may be marked observed-original; catch-up first-known versions must NOT be promised as original because they may already have been edited.
- This new archive does not automatically migrate ambiguous historical MX defaults (#65 importer remains gated/inactive). **One account DB per authenticated Telegram account**. Local only, no telemetry/chat text logs.
- Next step: verify actual CI #66 conclusion; if RED inspect exact failure. If GREEN install via KSign and test nested switch, fresh incoming private message, background/resume, Force Quit/Restart persistence, plus base app/push/MX functions. Do not claim history view exists; SQLite data are not yet shown in Goldgram UI.
- After verified iPhone tests, next atom should archive edited versions and deletion events, using the same account-scoped bridge and carefully handling unscoped personal-chat delete IDs. Do not add together with UI browser. Follow **1 code atom -> 1 commit -> CI -> real device test**. Energy work paused.

---

# Swiftgram Gold Next — Migration Plan

Updated: 2026-10-13 (historical migration notes preserved)

## LATEST GOLD NEXT STATUS — 2026-10-13 / CODE ATOM #65

- User installed and tested #64: Swiftgram launches with inactive SQLite foundation; GitHub CI #64 GREEN.
- **#65** on gold-next: commit `ee0f7f1e4e642751431c97f4d4094a24de810b26`, GitHub Actions actual run_number **65**, ID `38360564036`, https://github.com/sviridovski/Telegram-iOS/actions/runs/38360564036. CI was **in_progress** at documentation snapshot; outcome not yet verified.
- New `build-system/gold-next/GoldgramLegacyImporter.swift`, compiled via `prepare_mx.py` and backed by existing `GoldgramHistoryStore`. Imports verified-account scoped MxEditHistoryByPeer (with 1.4.3 fallback) and MxDeletedMsgIds into SQLite using one transaction, upsert/ignore semantics, no data deletion. Unknown group/channel classification is skipped for edits; ambiguous deletion IDs stay unresolved.
- **NO automatic import or history capture** in #65. Import requires a trusted proof that the *entire historical shared Mx defaults blob* belongs to one authenticated Telegram account. Merely being logged into one account now is not proof; never guess ownership or mix accounts.
- Next: verify CI #65 and iPhone startup/navigation, then implement trusted per-account identity and migration activation as a *separate tested atom*, before any live message capture. Never mark unseen first version as a guaranteed original. Energy work paused.

---

## LATEST PROGRESS — 2026-10-13 (read before older migration checkpoints)

- #62 is green and user-tested (Goldgram root folder menu).
- #63 is green and user-tested for new nested Deleted/Edited messages settings. Commit `5a9b2a2c8004c983975d88f47f72e3e63897fcef`.
- #64 is now the active code atom: `ab5ca990ba58060d353dbacffb758533d42ccb0a` in `gold-next`. GitHub Actions actual `run_number=64`, run ID `38350338461`. **CI was queued at this snapshot, NOT confirmed GREEN**.
- #64 adds **inactive** `build-system/gold-next/GoldgramHistoryStore.swift` SQLite foundation and build-time copy/link in `prepare_mx.py`. It does not capture edits/deletions, does not read account history, does not migrate UserDefaults, and does not change the Goldgram UI.
- Next: verify CI #64, then user tests iPhone launch/Mx/Help gesture and key messaging functionality. Only on user-confirmed acceptance begin a **separate** migration/capture atom. No unrelated performance changes.
- Detailed schema and constraints: `GOLDGRAM_HISTORY_SQLITE_PLAN.md`.

---

## CURRENT HANDOFF — Gold Next / Goldgram (2026-10-13)

**This section and the "Current next action" at the bottom supersede all obsolete #45-era next-step instructions below.** Historical migration details remain for reference only.

- Repo: sviridovski/Telegram-iOS; active app branch gold-next; separate docs branch docs/gold-roadmap.
- Swiftgram 12.9.2 + pinned MxGram 1.0.0 integrated and distributed via GitHub CI / KSign; previous Telegram/TGExtra migrations are complete enough to work from this stable integration.
- Trusted latest successful GitHub Actions **run_number #61** (commit f5c656c93ebce312b78800a8a2fd89cdaa7b7ecb); Theos cache origin/master failure fixed in that CI commit. Do not re-open #45/#47-era history without a concrete regression.
- Current active code HEAD **e15a44295c85c67d62ec901e9a121fe15139bc93**; CI **run_number #62**, URL https://github.com/sviridovski/Telegram-iOS/actions/runs/38327975778. Status was **in_progress** at documentation time, NOT a confirmed successful build.
- #62 UI atom: create Goldgram folder navigation for existing Mx categories via build-system/gold-next/prepare_mx.py, while retaining Mx.dylib injection, settings keys, "Помощь" / Help long press (3 sec), push, iPad behavior and current functionality. This is only UI organization.
- Energy optimization and ProMotion work paused by user's explicit decision. New priority: Goldgram organized settings, then local history for edits/deletes.
- Planned next functional atom after green CI and on-device acceptance: split the mixed MISC category into sensible nested folders (personal messages / groups / channels history, Ghost/privacy, tools), with one change per commit.
- After menu work: SQLite local history, original snapshots, edit revisions, delete events, per account and per chat type, configurable retention, safe migration from old Mx UserDefaults. See GOLDGRAM_HISTORY_SQLITE_PLAN.md for full spec.
- Strong limitation: suspended apps cannot run a continuously active Mx hook. Catch-up with Telegram's difference/update replay after resume, while preserving only originals previously observed and captured. Do not claim unseen originals can be reconstructed or run permanent background keepalives.
- Delivery rule: **1 functional atom -> 1 commit -> 1 CI build with true run_number -> real iPhone test -> proceed**. Keep docs-only commits on docs/gold-roadmap so they do not trigger Gold Next CI or pollute functional history.

## Repositories and module boundaries

- Pinned Mx source: m1ronx1412/mxgram at 23c980300c3e9c98f39ee2bd073fe83d317e15ba; build-time adaptations made in build-system/gold-next/prepare_mx.py. Do not casually switch plugin version or modify upstream.
- The current Mx edit history in TLParser.swift is backed by UserDefaults key MxEditHistoryByPeer with a 2000-message cap and up to 20 versions per message; deleted-ID bookkeeping uses MxDeletedMsgIds and a 1000-key cap. Those are migration inputs, not the planned final persistence format.
- A dedicated SQLite-backed Goldgram history module should be isolated from upstream and Mx patching as practical. One encrypted-at-rest (iOS file protection) local database per Telegram account; separate **logical** views for personal, groups, and channels. No transmission of message text or history to third-party servers.
- Ghostgram retention choices of 1 day / 3 days / 7 days / forever are UX evidence only; the underlying Ghostgram storage engine has not been verified.

---

## Goal

Move Swiftgram Gold from the current stable Gold baseline based on Swiftgram / Telegram-iOS 11.3.3 to the current Swiftgram / Telegram-iOS 12.9.2 codebase, then replace TGExtra with MxGram in controlled atomic steps.

The project rule remains:

> 1 atom -> 1 commit -> 1 build -> test -> next atom

Do not mix migration, diagnostics, performance work, TGExtra removal, or MxGram integration in one atom.

## Protected rollback points

- Stable Gold control baseline: `15596f7a91778334888af34386e55e35e660f630`
  - Commit: `Gold: adaptive cold refresh for idle lists`
  - Swiftgram / Telegram version: 11.3.3
  - This is the current trusted pre-Postbox-background-cleanup point.
  - Keep it untouched as a rollback / A-B reference.

- RAM overlay test branch:
  - `test/gold-37-ram-overlay`
  - Diagnostic only.
  - Do not use as the migration base.

- Old `gold` branch:
  - Contains later experimental RAM/background work.
  - Do not use it as the migration base for Gold Next.

## Gold Next base

Branch: `gold-next`

Fresh Swiftgram master base:

- Base commit: `c7f26d6669e135c5f7222aa5816f51bdff42b213`
- Swiftgram / Telegram version: 12.9.2
- Xcode: 26.2
- Bazel: 8.4.2

Reason for rebasing the project on fresh Swiftgram instead of merging upstream into 11.3.3:

- Gold #37 is roughly 3260 Telegram upstream commits behind the current code.
- A giant merge into the old branch would combine upstream migration with Gold-specific changes and make regressions difficult to isolate.
- Gold Next therefore starts from current Swiftgram and receives only selected, proven Gold changes afterward.

## Atom Upgrade #1 — clean 12.9.2 baseline

Purpose: obtain a clean, installable Swiftgram 12.9.2 IPA before changing functionality.

Current Gold Next HEAD while this atom is being finalized:

- `1a705b224ae67c1684b8b7f5299adc2997fa698f`
- Commit message: `Gold Next: build clean Swiftgram 12.9.2 baseline`

Only build infrastructure/configuration may differ from fresh Swiftgram in this atom.

Known CI findings:

1. Fresh Swiftgram `Make.py` requires `sg_config`, but the current `appstore-configuration.json` lacked it.
   - Added `"sg_config": ""`.
2. CI #44 compiled the complete 12.9.2 project successfully:
   - 6052 / 6052 Bazel actions completed.
   - Output was `bazel-bin/Telegram/Swiftgram.ipa`.
3. CI #44 was marked failed only because the packaging step still searched for the old `Telegram.ipa` name.
4. Packaging was corrected to collect `Swiftgram.ipa`.
5. CI #45 is the next clean-baseline build.

Exit criteria for Atom Upgrade #1:

- CI green.
- Clean `Swiftgram.ipa` artifact produced.
- Install / launch succeeds.
- Account and chat database open normally.
- Sending and receiving messages work.
- Media opens.
- Extensions survive signing/install.
- Push/background behavior is checked.
- No TGExtra or MxGram changes are introduced yet.

Do not proceed to the next atom until this baseline is accepted.

## Atom Upgrade #2 — remove TGExtra remnants

Only after the clean 12.9.2 baseline is accepted.

Purpose:

- Remove obsolete TGExtra integration/injection remnants from the repository and CI.
- In particular, the legacy `.github/workflows/inject-tgextra.yml` is tied to the old 11.3.3 IPA and must not be part of Gold Next.

Rules:

- Do not add MxGram in the same atom.
- Do not add Gold performance changes in the same atom.
- Build and test a clean fresh Swiftgram without TGExtra first.

Exit criteria:

- CI green.
- IPA launches and basic Telegram/Swiftgram functionality works.
- No TGExtra bundle, dylib, injector step, or old TGExtra artifact dependency remains.
- Push/background behavior remains intact.

## Atom Upgrade #3 — MxGram minimal integration

Only after Atom Upgrade #2 is accepted.

Purpose:

- Integrate the current compatible MxGram version into the fresh 12.9.2 Swiftgram base.
- Start with the minimum integration necessary for loading MxGram.

Rules:

- Do not simultaneously port Ghostgram-like features.
- Do not simultaneously reintroduce Gold RAM/thermal changes.
- Verify compatibility with the current Telegram/Swiftgram ABI before expanding functionality.
- If MxGram is not compatible with 12.9.2, stop the atom and diagnose rather than adding broad workarounds.

Initial acceptance checks:

- Build succeeds.
- App launches.
- MxGram loads.
- Its settings/opening path works.
- Chats, media, push, foreground/background, and warm resume remain functional.
- No obvious thermal or RAM regression appears during ordinary use.

## Later MxGram atoms

After minimal integration is stable, add behavior one atom at a time.

Likely sequence:

1. Preferred MxGram opening gesture / entry point.
2. Deleted-message history.
3. Edited-message history.
4. Required Ghost Mode behavior.
5. Other chosen plugin/settings features.

Each feature must be independently buildable and testable.

## Gold performance migration

Do not blindly replay every old Gold commit.

After fresh Swiftgram + MxGram is stable:

1. Re-evaluate whether each old Gold optimization is still necessary on 12.9.2.
2. Port only changes that still solve a measured problem.
3. One optimization per atom.
4. Measure RAM, battery delta, thermal behavior, CPU, warm resume, and jetsam survival.

### Preserve / reconsider

The #37 adaptive refresh-rate work is a high-priority candidate to port because it produced a noticeable thermal improvement in real use.

### Do not automatically port

The post-#37 background Postbox purge experiments must not be carried over by default.

The experiments that called `Postbox.clearCaches()` on ordinary background entry showed no immediate `phys_footprint` reduction and became suspect after an unexpected cold restart.

If Postbox cache work is revisited, it must start again from measurement on the new 12.9.2 base.

## Architecture after migration

Target structure:

- Fresh Swiftgram / Telegram upstream base.
- Gold-specific changes isolated from upstream where practical.
- Own GoldCore / GoldUI direction for future features.
- MxGram treated as a replaceable integration layer, not as a reason to mix unrelated modifications.
- Stable rollback points retained before major feature stages.

Preferred checkpoints:

1. Gold #37 stable reference.
2. Gold Next clean 12.9.2.
3. Gold Next 12.9.2 with TGExtra fully removed.
4. Gold Next 12.9.2 + minimal stable MxGram.
5. Gold Next + selected proven Gold performance atoms.
6. Later Ghostgram-like Gold features.

## Bundle ID and push

Do not change Bundle ID or push-related identifiers during the migration unless a separate dedicated atom is created for that purpose.

Previous identifier changes caused background notifications to stop arriving until the app was opened.

Any future side-by-side installation must be treated as its own project stage and must verify:

- signed IPA,
- entitlements,
- extensions,
- App Groups,
- notification service extension,
- actual remote push delivery.

## Current next action — 2026-10-13

1. Verify GitHub Actions #62 conclusion for SHA e15a44295c85c67d62ec901e9a121fe15139bc93. Its run_number was #62; the docs snapshot has **no confirmed GREEN**.
2. If GREEN, install via KSign on iPhone. Confirm Goldgram opens by holding "Помощь"/Help 3 sec; all seven folders navigate correctly; original settings toggles persist; Ghost Exceptions, chat, notifications, media, and app launch still work. Include iPad regression check where applicable.
3. If RED, inspect the actual failed build step/log and repair only the verified issue (a new CI run has its own true run_number).
4. **Only after successful device validation**, proceed with a single #63-like atom to regroup MISC features into meaningful subfolders. Do not combine with SQLite.
5. Stage SQLite via independently testable atoms: schema/DB bootstrap -> migration of original/edit/deleted-ID history -> capture revisions & deletion events -> browser UI & retention -> foreground-resume reconciliation. Use the detailed checkpoints in GOLDGRAM_HISTORY_SQLITE_PLAN.md.
6. Keep energy-efficiency work paused. The user can explicitly resume it later.

The previous #45 checkpoint is historical and no longer the current action.
