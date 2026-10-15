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

## AGREED UX DIRECTION — In-chat History Navigator (2026-10-13)

**Status: requested/design only; NOT implemented by SQLite capture atom #66.** User wants a real archive organized by Personal chats / Groups & chats / Channels, with each archived event selectable to jump back into the actual Telegram conversation and show historical content directly around the message in the normal chat UI.

### Desired navigation and appearance

- Goldgram -> Deleted & Edited -> **Personal** / **Groups & Chats** / **Channels**.
- Within each category: dialogs grouped by peer name, then events with original excerpt, edit/delete flag, sender when known, original sent date/time when known, and source channel post or associated discussion context.
- Tap an archived item -> switch to the **correct authenticated Telegram account**, open the real peer or discussion thread, scroll and highlight the surviving message. Use the host native account-aware and thread-aware navigation, not guessed public t.me URLs.
- When current message still exists, render **confirmed original in normal/primary text**, and **latest edited text below it in a dimmer, legible style**, per user's preferred direction. If there are multiple edits, provide a tap-to-expand version timeline with known edit time vs local observation time. Display can be optional to avoid cluttering every normal chat.
- Example: Group "Альфа", Ivan, Oct 12 16:42: original "Встреча сегодня в 18:00"; latest edit "Встреча завтра в 18:00". Click -> open exact message in "Альфа"; original prominent, latest edit subdued.
- Another example: news item published to a channel followed by a user's edited/deleted comment in a **linked discussion group**. Store the comment's real discussion-group peer + message ID + thread ID and (when verified) the original channel post ID. Tap -> open **discussion thread at the comment**, not just the channel home, with optional "View original channel post" link.
- Event archive should function offline for already recorded content even if the source chat no longer exists or access was revoked.

### Important caveat: deleted originals have no native server-side anchor

- **Edited message still present**: native navigation and inline rendering can work reliably, subject to access and available account/chat state.
- **Message deleted for everyone**: Telegram/Postbox may no longer have a displayable message or message index. Trying to jump by a deleted ID alone may fail. Plan a local **tombstone/placeholder overlay** anchored via captured date, thread, adjacent surviving message IDs and local archive metadata; alternatively open the closest valid message and show a local history card. Never imply deleted server content was restored on Telegram.
- **Channel post or comment removed / inaccessible**: open the relevant channel/discussion if still accessible; else show a standalone archived record and an honest "cannot jump to original position" status.
- No assumption that the earliest seen text is definitely original: label it "earliest known version" when edit already predated first capture. Sender/time/thread/category must also display UNKNOWN if never observed.
- Display historic contents only if already observed and stored locally; iOS background suspension and Telegram API limitations remain.

### Repository-grounded feasibility

- Existing Swiftgram APIs: \`submodules/TelegramUI/Sources/SharedAccountContext.swift\` has \`navigateToChat(accountId:peerId:messageId:)\`, \`navigateToChatController\`, and \`navigateToForumThread\`. \`submodules/TelegramUI/Sources/Chat/ChatControllerNavigateToMessage.swift\` implements navigation, message highlighting and forum/topic-aware \`replyThread\` routing.
- Current SQLite **v1** \`GoldgramHistoryStore.swift\` lacks \`sender_id\`, \`sent_at\`, \`thread_id\`, \`root_channel_post_id\`, \`adjacent_message_ids\`, and robust event source / import certainty flags. Add these with a **versioned v2 SQLite migration**, not by silently replacing old schema or DB files.
- Use per-account peer kind + peer ID + message ID and actual thread/root channel post identity; do not treat channel message IDs as global. A channel post and a comment in a linked discussion are different messages and different peers.
- A read-only local archive browser needs indexed, asynchronous, paginated SQLite queries; inline chat decorations should be only on visible affected messages, with bounded cache and no global hot-loop re-layout.
- The overlay must not mutate Telegram remote content; avoid inventing persistent Postbox messages that may sync incorrectly. It is strictly client-side.

### Safe atomic roadmap after #66 validation

1. **#66 only after CI GREEN + user on-device test:** opt-in archiving of incoming private original text; browser not available yet. Verify actual creation/persistence before claiming it works.
2. Implement **v2 schema metadata** (sender, source timestamp, thread/root post, display and provenance flags; migration tests and downgrade fail-closed). One atom/build/device test.
3. Capture **edits** and version timeline, correctly scoped to account/peer/id, with deduplication and old/unknown-original distinction. One atom.
4. Capture **deletions**, including unresolved global IDs and channel-specific IDs, without cross-dialog false matches. One atom.
5. Expand event capture to **groups/supergroups/channels/comment threads**, with discussion mapping only when known. One or more atoms.
6. Build **archive browser** (Personal/Groups/Channels, peer list, event list, search/retention filters). One UI atom.
7. Build **tap -> native chat/thread navigation** for existing messages, account-aware + message anchor. One UI atom.
8. Build **inline subdued revisions** for surviving chat bubbles, respecting voiceover/readability, dynamic fonts and performance. One UI atom.
9. Build **deleted-message local tombstone/fallback navigation**, test disappearing items, inaccessible sources and imported uncertain originals. One or more atoms.
10. Recheck retention 1/3/7 days/forever and ensure archives never appear under the wrong account or peer. Never combine these all into one build.


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

# Goldgram — SQLite History, Deleted/Edited Messages, and UI Handoff

**Approved by user:** 2026-10-13. **Status:** design/roadmap only; the SQLite functionality is **NOT IMPLEMENTED**. No code atom is authorized merely by updating this file.

## LATEST GOLD NEXT STATUS — 2026-10-13 / CODE ATOM #65

- User installed and tested #64: Swiftgram launches with inactive SQLite foundation; GitHub CI #64 GREEN.
- **#65** on gold-next: commit `ee0f7f1e4e642751431c97f4d4094a24de810b26`, GitHub Actions actual run_number **65**, ID `38360564036`, https://github.com/sviridovski/Telegram-iOS/actions/runs/38360564036. CI was **in_progress** at documentation snapshot; outcome not yet verified.
- New `build-system/gold-next/GoldgramLegacyImporter.swift`, compiled via `prepare_mx.py` and backed by existing `GoldgramHistoryStore`. Imports verified-account scoped MxEditHistoryByPeer (with 1.4.3 fallback) and MxDeletedMsgIds into SQLite using one transaction, upsert/ignore semantics, no data deletion. Unknown group/channel classification is skipped for edits; ambiguous deletion IDs stay unresolved.
- **NO automatic import or history capture** in #65. Import requires a trusted proof that the *entire historical shared Mx defaults blob* belongs to one authenticated Telegram account. Merely being logged into one account now is not proof; never guess ownership or mix accounts.
- Next: verify CI #65 and iPhone startup/navigation, then implement trusted per-account identity and migration activation as a *separate tested atom*, before any live message capture. Never mark unseen first version as a guaranteed original. Energy work paused.

---

## IMPLEMENTATION STATUS UPDATE — 2026-10-13

- User confirmed #62 folder navigation and #63 nested Deleted/Edited messages folder on iPhone. Both CI runs are GREEN.
- **First SQLite foundation code atom #64 committed**: `ab5ca990ba58060d353dbacffb758533d42ccb0a` on `gold-next`. GitHub Actions run_number #64 / run ID `38350338461` was **queued** at this snapshot (no success claim).
- New source module `build-system/gold-next/GoldgramHistoryStore.swift` is compiled into injected Mx via build-time `prepare_mx.py`; its setup entry point is **not called yet**, so it creates no DB on existing installs and stores no messages.
- Implemented proposed v1 DDL: `dialogs`, `messages`, `revisions`, `events`, `unresolved_deletions`, `retention_settings`; indexed composite peer-kind/peer-ID/message-ID keys; one DB per positive Telegram account ID; WAL; SQLite schema version 1; file protection; serialized off-main bootstrap.
- **Still to implement:** verified account-ID plumbing, creation on explicit user opt-in, legacy UserDefaults migration, message original snapshots and subsequent edits/deletes, folder history UI, configurable retention cleanup and foreground resume reconciliation.
- Immediate next action: inspect CI #64, then obtain user confirmation that new IPA launches and existing MX functions remain intact. **Do not claim SQLite history is already working**.
- After #64 acceptance, migrate old history in a separate atom; do not merge capture and migration. Power/RAM improvements remain paused.

---

## How to resume in a new chat

- Work on the actual repo **sviridovski/Telegram-iOS**, app branch **gold-next**. Documentation lives on **docs/gold-roadmap** (GOLD_ROADMAP.md, GOLD_NEXT_MIGRATION_PLAN.md, this file).
- Continue from the actual current HEAD, not historical messages. Snapshot at this writing: **e15a44295c85c67d62ec901e9a121fe15139bc93**, Goldgram folder UI atom #62. GitHub Actions run **#62** (38327975778) was **in_progress**, result not yet verified. Last verified GREEN run **#61**.
- Build target: Swiftgram 12.9.2 with pinned **MxGram 1.0.0** integrated as **Mx.dylib**, source m1ronx1412/mxgram commit **23c980300c3e9c98f39ee2bd073fe83d317e15ba**. Build-time Mx source patches are in build-system/gold-next/prepare_mx.py. Mx/Goldgram opens from long-press **"Помощь" / Help, ~3 sec**; user installs via KSign, without a desktop PC.
- **Power/RAM/ProMotion work is ON HOLD.** User's active priority: logical UI subfolders in Goldgram, then reliable original/edited/deleted message history for private chats, groups, and channels, especially after the app is backgrounded.
- Work atomically: one change -> one commit -> one successful CI run using **real GitHub Actions run_number** -> real device test -> next change. Do not combine UI reorganization with DB migration or with hook changes. Do not modify the documentation branch when implementing app code.
- Do not browse unrelated #37–#49 history; use this handoff and inspect only the needed current files.

## Approved product design

### Goldgram UI hierarchy (folders, not separate SQLite files)

- **History** -> **Personal messages** -> Deleted / Edited / All events -> Conversations -> Message history.
- **History** -> **Groups and chats** -> Deleted / Edited / All events -> Conversations -> Message history.
- **History** -> **Channels** -> Deleted / Edited / All events -> Channels -> Message history.
- A channel's comments/discussion group must use its **real peer identity**, not be guessed solely from visual context; optional cross-link only when reliably mapped.
- Other Goldgram top-level groups: **Ghost Mode / Privacy**, **MX Tools & Media**, **Storage & Retention**, **About / Language**. Preserve the original user-facing features, toggles, and functionality when relocating their UI.
- For each captured event show, if known: sender and conversation, original text, each saved revision, edit/deletion state, server timestamp versus local observation timestamp, and explicit "original unavailable" when not observed.
- Optional per-chat exceptions, search, long-press revision history, and local export may follow later; do not mix these into the first storage atom.

### Storage architecture

- Use native **SQLite3**, database named **goldgram_history.sqlite**, **one app-sandbox database per Telegram account**, avoiding collisions between accounts. Logical type separation happens via DB columns and UI, **not separate physical SQLite databases** for personal/groups/channels.
- **WAL** journaling, transaction boundaries, indexed lookups, schema versioning (PRAGMA user_version), one serialized writer and asynchronous bounded write batches; **do not perform disk writes or full history scans on the render/main thread**. No hot polling.
- Initial proposed tables:
  - **dialogs**: account scope, peer_kind (user/basic_group/supergroup/channel), authoritative peer ID, optional name snapshot, last_event_at.
  - **messages**: composite key (account, peer kind, peer ID, message ID); original_text when positively observed; first_seen_at; last_seen_at; deleted state and flags; optional thread_id only if known.
  - **revisions**: composite message foreign key, ordinal version, text, received_at, server_edit_date if provided, content hash for idempotency. Preserve earliest confirmed original as version 0; avoid duplicate revisions from repeated history fetch.
  - **events**: edit/delete event type, message composite key or explicit unresolved scope, event_time and observed_at, origin/update type, deduplication key, resolution status.
  - **unresolved_deletions** (if required): raw delete IDs in account-wide scope until unambiguously associated to a previously observed message. Never guess a peer and pollute another conversation's history.
- To avoid duplicate events: unique composite keys plus content checks; treat reaction/view refreshes separately from actual edits (real edit_date / updateEditMessage evidence).
- The user's agreed baseline retention choices: **1 day, 3 days, 7 days, indefinitely (forever)**. Support separate policies for Personal / Groups / Channels and optionally per-chat override later. Additional 30/90-day presets are optional and **not** required initially. Expose manual clear by conversation/category; safe age/cap-based cleanup on application events, not a timer spinning all day.
- Protect sensitive history locally. Use iOS file-protection classes chosen with documented foreground/background tradeoffs, apply to the DB **and WAL/SHM sidecars**; avoid contents in os_log, crash logs, telemetry, analytics, network requests, or third-party APIs. Offer a clearly understandable opt-in/opt-out. Define backup policy before enabling exports or cloud backups.
- SQLite WAL and deleting records do not by themselves guarantee forensic secure erasure of bytes on storage; do not advertise that guarantee.

### Verified current Mx behavior and migration inputs

- Mx source **Sources/tgapi/TLParser.swift** currently keeps edited versions in memory + **NSUserDefaults MxEditHistoryByPeer**, keyed by peer and message ID; cap about **2,000 messages** and **20 revisions** per message. Original snapshots are flushed with a delay (~5 sec); edit-version changes serialize the whole dictionary immediately.
- Mx also uses **MxDeletedMsgIds** for deletion markers, with cap around **1,000 tracked ID keys**. Deletions in ordinary cloud chats can come as account-wide message IDs with no peer. Channel/supergroup message IDs are **not globally unique**.
- Migrate supported legacy defaults transactionally and idempotently, preserving original order. Back up the old UserDefaults values until parity is verified; no blind deletion. Records without trustworthy peer mapping stay unresolved; never import into the wrong conversation.
- Use verified account identity, peer kind, peer ID, and message ID in lookup and all caches. Do not confuse a message deleted in one channel with another channel's same message ID.
- Existing **updates.getDifference** and **updates.getChannelDifference** paths already exist in Mx; audit them before changing. Existing Mx hook neutralizes some deletions and handles short/new/edit update forms. Validate both live updates and catch-up after resume.
- On app suspension/termination, Mx code **does not run continuously**. When Telegram later sends a diff, an edit/delete event may be visible but the **original version is not recoverable** if it was never captured before the edit/delete. SQLITE IS PERSISTENCE, NOT A BACKGROUND MONITOR OR SERVER HISTORY SERVICE.
- If supporting media later, retain only media already legally and technically accessible to the user, within explicit storage policy; do not pull media after it is absent.

## Atomic development sequence (logical atom labels; CI build numbers are assigned by GitHub)

1. **#62 (IN PROGRESS / UNVERIFIED)** — nested Goldgram menu over current 7 Mx categories. Code commit e15a44295c85c67d62ec901e9a121fe15139bc93; CI run ID 38327975778. After GREEN, on-device test folder navigation and settings. Do **not** pretend this already moved Mx files or created SQLite.
2. **Next UI atom (expected #63 if no intervening builds)** — split MISC into semantic nested categories, keeping unchanged underlying switch keys, callbacks, injected dylib, Help gesture, iPad and push. One CI + device test.
3. **SQLite foundation atom** — add isolated GoldgramHistory store (schema, path per account, WAL, migrations and tests, optional nonfunctional database bootstrap), without turning on capture.
4. **Migration atom** — import old edited history + deleted ID scopes idempotently; compare counts and samples; keep old source until verified.
5. **Original capture atom** — capture original text once on first credible receipt, index by account/peer/message, bounded async transactions; no plaintext logs.
6. **Edit/delete event atoms** — version archive, tombstones and scoped delete handling, each independently tested. Do not store an already-edited version as if original.
7. **History browser / retention atoms** — personal/groups/channels folder UI, filters, edit timeline, 1/3/7-day or forever policies, cleanup and manual clear.
8. **Foreground resume/difference atom** — map short updates and account/channel difference replay; reconcile confirmed events and mark missing originals honestly, without permanent background execution.
9. Compare with Ghostgram via repeatable real-device tests; test two accounts, duplicate message IDs in distinct channels, chats with edits while app foreground/background/suspended/terminated, clean restarts, message deletion during inactivity, TTL and text/media, no false badges. Measure storage growth/performance.

## Release gates

- CI GREEN, IPA launches, Mx loads, Goldgram Help gesture works; no TGExtra artifacts, notifications, login, chats, media, calls, or iPad regressions.
- A deleted/edited record must never show another conversation's message. Distinguish original observed, later version, unknown origin, and event caught up after resume.
- Zero unwanted network exfiltration, no plaintext message bodies in diagnostics, predictable retention and manual clearing, no main-thread database bottlenecks.
- One finished tested atom before beginning another. If CI is red, diagnose only the exact failing step.

## Ghostgram comparison — epistemic note

The user reports Ghostgram offers history retention for **1 day, 3 days, 1 week, and indefinitely**. This confirms configurable retention as a useful target UX, **not** Ghostgram's underlying storage technology. It could be SQLite, another DB, a flat-file store, or another mechanism; do not claim Ghostgram specifically uses SQLite without inspecting credible implementation evidence.
