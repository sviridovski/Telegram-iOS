# Swiftgram Gold Next — Migration Plan

Updated: 2026-10-06

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

## Current next action

Wait for CI #45 for Atom Upgrade #1.

If it is green:

1. Download/install the clean 12.9.2 Swiftgram IPA.
2. Test the baseline.
3. Do not add TGExtra/MxGram yet.
4. Only after baseline acceptance start Atom Upgrade #2: remove TGExtra remnants.

If #45 is red:

- inspect the exact failing CI step,
- repair only the clean-baseline build infrastructure,
- keep Atom Upgrade #1 as one logical atom,
- do not move to TGExtra/MxGram work.
