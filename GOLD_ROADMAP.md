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

# Gold Roadmap

This roadmap originally belongs to the `gold` branch; active Gold Next decisions are tracked below.

## LATEST GOLD NEXT STATUS — 2026-10-13 / CODE ATOM #65

- User installed and tested #64: Swiftgram launches with inactive SQLite foundation; GitHub CI #64 GREEN.
- **#65** on gold-next: commit `ee0f7f1e4e642751431c97f4d4094a24de810b26`, GitHub Actions actual run_number **65**, ID `38360564036`, https://github.com/sviridovski/Telegram-iOS/actions/runs/38360564036. CI was **in_progress** at documentation snapshot; outcome not yet verified.
- New `build-system/gold-next/GoldgramLegacyImporter.swift`, compiled via `prepare_mx.py` and backed by existing `GoldgramHistoryStore`. Imports verified-account scoped MxEditHistoryByPeer (with 1.4.3 fallback) and MxDeletedMsgIds into SQLite using one transaction, upsert/ignore semantics, no data deletion. Unknown group/channel classification is skipped for edits; ambiguous deletion IDs stay unresolved.
- **NO automatic import or history capture** in #65. Import requires a trusted proof that the *entire historical shared Mx defaults blob* belongs to one authenticated Telegram account. Merely being logged into one account now is not proof; never guess ownership or mix accounts.
- Next: verify CI #65 and iPhone startup/navigation, then implement trusted per-account identity and migration activation as a *separate tested atom*, before any live message capture. Never mark unseen first version as a guaranteed original. Energy work paused.

---

## LATEST GOLD NEXT STATUS — 2026-10-13 (overrides older snapshots below)

- **#62**: Goldgram root folders, GitHub CI GREEN, user tested nested folder navigation on iPhone.
- **#63**: Goldgram mixed-MISC controls grouped into four semantic subfolders, GitHub CI GREEN, user explicitly confirmed the Deleted/Edited folder works on iPhone. Commit `5a9b2a2c8004c983975d88f47f72e3e63897fcef`.
- **#64**: isolated SQLite foundation committed on active `gold-next`: `ab5ca990ba58060d353dbacffb758533d42ccb0a`. GitHub Actions real run_number **#64**, run ID `38350338461`, https://github.com/sviridovski/Telegram-iOS/actions/runs/38350338461. It was **queued**, not verified GREEN, at this documentation snapshot.
- Code changes: new `build-system/gold-next/GoldgramHistoryStore.swift` and a build-time copy / sqlite3 linkage in `prepare_mx.py`; account-specific `Application Support/Goldgram/Accounts/<accountId>/goldgram_history.sqlite`; WAL, user_version 1, tables for dialogs/messages/revisions/events/unresolved deletions/retention, file protection, asynchronous bootstrap. **No automatic bootstrap, no capture, no data migration, no interface changes in #64.**
- **NEXT STEP:** inspect #64 GitHub CI. If it is green, test app launch, MX menu via 3-second long press on Help, Telegram chats/push, normal plugin functions on iPhone; no new history UI should appear yet. If red, repair *only* the exact failing build problem. Then proceed to an independent migration atom with safe account scoping, not before.
- Energy work remains paused. One functional change -> one commit -> one CI -> real-device test.

---

## ACTIVE GOLD NEXT / GOLDGRAM HANDOFF — 2026-10-13

**Read this section first.** This is the ACTIVE priority for the separate working branch gold-next. The remainder of this file documents the older gold-branch roadmap; the historical "performance first" gate is currently paused by the user, not a prerequisite for current Goldgram development.

- Repository: sviridovski/Telegram-iOS. Active application branch: gold-next. Documentation branch: docs/gold-roadmap. Keep these branches separate.
- Current working HEAD at this snapshot: e15a44295c85c67d62ec901e9a121fe15139bc93 (Goldgram settings folders). GitHub Actions run_number #62 / run ID 38327975778 was IN PROGRESS when documented; **not confirmed green or device-tested**. Previous #61 was GREEN.
- Swiftgram / Telegram 12.9.2, pinned MxGram 1.0.0 injection (Mx.dylib); TGExtra is not part of Gold Next. KSign iPhone deployment; open Mx/Goldgram using long-hold "Помощь"/Help for ~3 seconds. Preserve bundle ID, push, extensions, and injection.
- #62: initial navigation for seven nested Goldgram setting sections in the Mx UI, implemented as a build-time patch in build-system/gold-next/prepare_mx.py. This is **UI organization**, NOT moving Mx source files and NOT a history database. Validate CI, submenu navigation, toggle persistence, Ghost Exceptions, and iPhone/iPad behavior first.
- Next UI atom (#63 only after #62 succeeds and is tested): divide the mixed MISC section into meaningful subfolders, especially Deleted/Edited messages, Ghost/privacy, media, and tools. Preserve existing settings keys and hooks.
- Then prioritize **local SQLite message history**: original text, edited versions, deletion events and timestamps; browse Personal Messages, Groups/Chats, and Channels separately, each with Deleted / Edited / All Events; per-account storage, safe ID scoping, privacy, retention, and user controls.
- Planned retention presets: 1 day, 3 days, 7 days, and indefinitely; design per dialog type (optionally per dialog). These presets are known from the user's experience with Ghostgram; **they do not prove Ghostgram uses SQLite**.
- Important limit: iOS may suspend/terminate the client; SQLite cannot record edits/deletions while code is not running. Retain original text BEFORE edit when observed; on foreground return process updates.getDifference / channel difference. An original unseen before editing cannot generally be recovered from server current state.
- Read the detailed technical spec and acceptance checks in **GOLDGRAM_HISTORY_SQLITE_PLAN.md**, and the chronological migration/current-run handoff in **GOLD_NEXT_MIGRATION_PLAN.md**.
- Strict delivery: 1 logical atom -> 1 code commit -> GitHub Actions build (use **actual run_number**, do not invent numbers) -> real iPhone test -> next code atom. Documentation updates are separate commits on docs/gold-roadmap. Never touch old historical branches as part of a new feature atom.
- Power/RAM/thermal optimization is explicitly **ON HOLD** until user reactivates it. Do not introduce thermal changes with UI/SQLite atoms.

---

## Historical performance strategy (paused for Gold Next)

This was the original gold-branch rule. For Gold Next, the user has explicitly paused energy optimization to prioritize Goldgram functionality; preserve no-regression tests.

Primary targets:
- Reduce foreground and idle energy use.
- Reduce steady-state RAM.
- Maximize warm-resume survival under iOS memory pressure.
- Stress-test repeated ChatGPT ↔ Swiftgram switching.
- Stress-test coexistence with heavy games.
- Avoid unnecessary timers, polling, duplicate refreshes and background assertions.
- Preserve push, calls, message sync, uploads/downloads and TGExtra.
- One atom = one focused change = one commit = one build = one real-device test.

> iOS ultimately decides jetsam/termination. “Survive heavy games” is an optimization target, not a guarantee.

---

## Historical Phase 0 — Performance foundation (on hold, not a current gate)

- [x] Atom #1 — task-aware background work.
- [ ] Atom #2 — safe RAM/cache release audit.
- [ ] Atom #3 — coalesce duplicate non-message refreshes.
- [ ] Atom #4 — lazy-load TGExtra and optional subsystems.
- [ ] Atom #5 — media prefetch policy for background / Low Power Mode / thermal pressure.
- [ ] Atom #6 — thermal-state-aware throttling for nonessential work.
- [ ] Atom #7 — optional Battery+ profile.
- [ ] Atom #8 — lightweight event-based diagnostics, no production polling.
- [ ] Atom #9 — CI regression guards for timers/background work/TGExtra packaging.
- [ ] Atom #10 — map Telegram update/difference replay paths after resume.

Acceptance goals:
- Lower heat during app switching.
- Lower RAM after backgrounding without breaking warm resume.
- No production memory polling.
- No artificial keepalive whose only purpose is defeating iOS suspension.
- No regression in messaging, notifications, calls or media transfer.
- Compare each atom with the untouched golden baseline.

### Stable-build validation milestone — Ghostgram vs Gold A/B test

When Gold reaches a stable performance baseline, run a controlled A/B comparison against Ghostgram before moving on to major feature work.

Test protocol:
- Same physical iPhone.
- Same iOS version, battery/thermal starting conditions, network and screen brightness.
- Same accounts/chats and as close as possible to the same notification load.
- Same scripted usage scenario, especially repeated ChatGPT ↔ Telegram-client switching.
- 20–30 minutes per run.
- Repeat runs when possible instead of relying on a single sample.
- Test both normal multitasking and a memory-pressure scenario with a heavy game.
- Let the device cool back to a comparable state between runs.

Record for both Ghostgram and Gold:
- RAM footprint and RAM behavior over time.
- Battery delta over the test interval.
- Thermal state / visible heating behavior.
- CPU time / CPU utilization where measurable.
- Warm-resume success after app switching.
- Whether iOS keeps the client resident or jetsams/relaunches it under heavy-game pressure.
- Time to usable UI after returning to the client.
- Any messaging / notification / media-transfer regressions.

The goal is not to “win” a benchmark by disabling useful Telegram behavior. Gold should remain functionally correct while consuming fewer resources and surviving memory pressure for as long as iOS allows.

---

## Phase 1 — Deleted / edited message history

- Save deleted messages.
- Save own messages deleted “for everyone”.
- Save disappearing messages where available before deletion.
- Archive deleted media.
- Show edited messages inline.
- Separate deletion/edit histories.
- Group by personal chats / groups / channels / comments.
- Support bots.
- Support deleted/edited channel posts.
- Adjustable opacity for deleted/local-edit history.
- Exclusions by chat / group / folder.
- Optional long-press history.
- Retention / cache policy.
- Correct behavior after long suspension by handling Telegram difference/update replay rather than forcing permanent background execution.

---

## Phase 2 — Ghost Mode / privacy

- Master Ghost Mode.
- Do not send read receipts.
- Do not mark stories viewed.
- Do not send online presence.
- Do not send typing / recording / activity indicators.
- Automatic offline behavior.
- Read-on-actions exception.
- Per-chat / group / folder exclusions.
- Fine-grained activity settings.
- Timed stealth session.
- Optional send delay while staying offline.

---

## Phase 3 — Translation and message utilities

- Independent app UI language.
- Translation provider selection.
- Translate chats/messages.
- Translate before sending.
- Outgoing translation language.
- Reply as quote.
- Custom recent reactions.
- Local edit.
- Bookmark in long-press menu.
- Mark all read locally / on server.
- Auto word replacement.
- Optional anti-search text transform.
- Optional novelty text transforms.

---

## Phase 4 — Misc client utilities

- Client-side content-forward/save restriction handling where technically local.
- Optional source attribution when making a copy.
- Local retention controls for ephemeral media where feasible.
- Screenshot behavior controls where client-side.
- Sponsored-message filtering where client-side.
- Avoid Telegram proxy when system VPN is active.
- Bot-content compatibility helpers.
- Send gallery video as video-message where supported.
- Anti-spoiler.
- Poll-results helper where technically possible without faking server state.
- Anti-caps formatter.
- Camera-switch animation controls.
- Do not pause other audio while recording where safe.
- Optional transcription workflow.
- Hide messages from blocked users in public chats/groups.
- Anonymous sticker-send metadata behavior where technically possible.
- Search-history retention controls.
- Hide greeting sticker.
- GIF chat/profile backgrounds.
- “Remove via …” attribution controls.
- Audio equalizer.

---

## Phase 5 — Local-premium-style client features

Only genuinely client-side features.
No attempt to create server-side Premium, Stars, paid reactions, gifts or other server-validated entitlements.

- Client-only visual/UX premium-style features.
- Clear local-only labeling.
- No fake server balances or server entitlement claims.

---

## Phase 6 — Customization

- Custom fonts / import font.
- Exact last-seen display where available.
- Connection/update text controls.
- Telegram transcription mode selection.
- Disable voice autoplay.
- Hide emoji status.
- Disable blur on selection.
- Message-background blur controls.
- Auto blur color, size and intensity.
- GIF chat background.
- Video-message masks.
- Bubble editor / hide bubble tail.
- Auto formatting.
- Typing animation customization.
- Message gradients.
- Custom top bar: username / avatar / pinned.
- Double tap copy.
- Triple tap delete shortcut.
- Delete-for-me / delete-for-everyone shortcuts with safeguards.
- Auto-mute new channels.
- Checkmark color.
- Hide channel comments / view counter.
- Hide message time / edited status.
- Profile-item visibility controls.
- Avatar/story-ring customization.
- Hide/customize search bar.
- Square avatars / round forum avatars.
- Chat-row size.
- Account-switch button in header.
- Bottom bar / folder bar height.
- Global-container search.
- Quick bound buttons.
- AMOLED pure black / AMOLED keyboard.
- Hide cell separators.
- Sender avatar in chat list.
- Optional snow effect.
- Download progress in chat list/folders.
- Hide message preview.
- Tab-bar organizer.
- Input-bar size/position.
- Hide/add settings tabs.
- Optimized Liquid Glass.
- iPhone-style Liquid Glass.
- Glass tint/intensity/corners/blur/shadow/glare.
- Old pre-Liquid-Glass interface mode.

---

## Phase 7 — Icon packs and badges

- Alternate icon packs.
- Import custom icon packs.
- Restart helper after icon changes.
- Custom badge / Dynamic Island style badge.
- Badge editor with image/text/layers/background.
- Import badge from file/link.

---

## Phase 8 — Feed

Disabled by default because it can materially increase CPU/GPU/network/RAM use.

- Optional vertical media feed.
- Sources: recommendations / own chats / chosen channels.
- Video / GIF / video-messages / photos.
- Viewed/unread filters.
- Length filters.
- Shuffle.
- Autoplay / loop / sound defaults.
- Auto-next.
- Gesture controls.
- Privacy controls for viewed/read state where technically supported.
- Local viewing history.
- Strict prefetch/cache budget.

---

## Phase 9 — Security / private workspace

- App passcode.
- Face ID / Touch ID on account switch.
- Password lock for selected chats.
- Sensitive-chat auto-lock.
- Secret biometric folder.
- Call settings.
- Optional local call recording only where lawful and with explicit user controls.
- Optional local microphone inclusion/exclusion in recordings.

---

## Phase 10 — Voice and camera effects

Fully lazy-loaded and off by default.

- Voice changer.
- Anonymous / female / male / child / robot / custom presets.
- Custom voice editor.
- Camera/video-message masks.
- Anonymous combined face+voice mode.
- Mask catalog/cache limits.
- On-device processing where possible.

---

## Phase 11 — Device / location presentation

- Client-side device-model/system-version presentation controls.
- Presets and custom values.
- App-local location override where feasible.
- Optional walking-route simulation for testing.
- Keep isolated from core messaging.

---

## Phase 12 — Export / import / diagnostics

Treat session material as highly sensitive.

- Full-account chat export.
- Telegram Desktop-style HTML/result.json export.
- Export media/files.
- Face ID/passcode before export.
- Settings export/import.
- Separate configs per account.
- RAM display.
- Safe manual/automatic cache cleanup.
- Event-based diagnostics.
- Session import only for the user’s own sessions with strict local handling.
- Never log/upload auth keys or session secrets.

---

## Phase 13 — Plugins / GGAPI-like platform

- Plugin manager.
- Import plugin.
- Create plugin template.
- Plugin settings.
- Local documentation.
- Dev hot reload.
- Minimal capability API.
- Context-menu extension API.
- Selected-message access API.
- Draft insertion API.
- Local storage API.
- HTTP/network API with explicit permission.
- AI CommandCenter integration.
- Lazy-load plugins so disabled plugins consume effectively no runtime resources.

---

## Phase 14 — Low-priority / experimental

- Music status.
- App icon customization.
- Client identity display selector.
- Profile hyperlink presentation controls.
- Watermark on photos.
- Local profile presentation experiments.
- Other cosmetic/novelty features only while the performance baseline stays intact.

---

## Development discipline

For every feature after Phase 0:
1. One narrowly scoped atom.
2. One commit.
3. Behind a setting and default-off unless it is a safe core fix.
4. Event-driven hooks instead of polling whenever possible.
5. Lazy-load optional engines/frameworks.
6. Explicit cache limits/retention.
7. Verify background/foreground lifecycle.
8. CI build.
9. Real-device test.
10. Compare RAM, heat and warm-resume behavior with the previous Gold build.
11. Revert immediately if an atom harms the performance baseline.

**Current Gold Next order: Goldgram organization and message history, with strict no-regression safeguards. Revisit performance only on explicit user request.**
