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
