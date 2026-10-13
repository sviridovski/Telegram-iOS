# Goldgram — SQLite History, Deleted/Edited Messages, and UI Handoff

**Approved by user:** 2026-10-13. **Status:** design/roadmap only; the SQLite functionality is **NOT IMPLEMENTED**. No code atom is authorized merely by updating this file.

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
