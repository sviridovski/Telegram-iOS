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
