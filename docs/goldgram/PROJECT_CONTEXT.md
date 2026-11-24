# PROJECT_CONTEXT — архитектура и инварианты Goldgram

> **Canonical project passport (part 1/3).** Project: **Swiftgram Gold / Goldgram**, source repository [sviridovski/Telegram-iOS](https://github.com/sviridovski/Telegram-iOS). This documentation branch deliberately has **no Actions build trigger**. Updated: **2026-11-23**. Primary language: Russian. This public repository must never contain private messages, account IDs, secret keys, credentials, personal IP/VPS endpoints, .session files, p12 or mobileprovision.

**Other parts:** [CURRENT_STATUS](./CURRENT_STATUS.md) · [DECISIONS_LOG](./DECISIONS_LOG.md). **Read all three before continuing the project in a new chat.** The live repository, CI and device tests are always more authoritative than a stale status snapshot.

## 1. Mission and supported environments

Swiftgram Gold is a modified Telegram iOS client based on the Telegram iOS **13.2** code line (ported from the older 12.9.2 line), with Mx and a Goldgram SQLite history system. The purpose is to **capture real originals, actually observed intermediate edits, deletions and their metadata**, display and navigate their history in chats, groups, channels and linked discussions.

Devices in the project:
- **Main iPhone 15 Pro Max**: Swiftgram UI, Telegram native account state, Postbox, Goldgram native/Mx archive, per-account SQLite and Live importer. As of 2026-11-19 it ran iOS **27.2.1**. Actual app build/version must be independently reconfirmed after each install.
- **Secondary jailbroken iPhone 8**: independent Telegram collector and supervisor, own local SQLite; connected to main phone via read-only Live Bridge. Its OS/jailbreak and installed collector version must be checked against the actual device before changing its scripts.
- No desktop/Mac is available for the normal user development flow; GitHub Actions builds the IPA, GitHub-connected ChatGPT reads/writes source and diagnostics, and iPhone handles deployment/test. The CI IPA is **unsigned for later independent signing**; never commit signing credentials.

**Truthfulness contract:** a message seen only after its first edit is NOT proof of the original. Absence of an intermediate edit cannot be repaired by inventing it. A placeholder 'Оригинал не получен' means the original is not verified, not that it never existed. Respect evidence and attribution. An update callback is not the same as a successful SQLite COMMIT.

## 2. Architecture, boundaries and flow

~~~text
Telegram server / MTProto
   ├── Main iPhone native TelegramCore + Postbox
   │    ├─ live update / updateDifference / snapshots / replay
   │    ├─ notification and OS BGAppRefresh diagnostics
   │    └─ GoldgramNativeHistory + event policy
   │          └─ serial capture/write -> per-account Goldgram SQLite
   │
   └── Independent Telegram session on iPhone 8 (Telethon collector)
        └─ per-device local collector SQLite
             └─ read-only HTTPS Live Bridge with certificate pin + pairing key
                  └─ main phone polling + validated, deduplicated import
                       └─ same main-phone per-account Goldgram SQLite
                            (source edit/delete cursors advance after COMMIT)

Main-phone SQLite -> GoldgramArchiveReader + category/group projection
                  -> Mx UI / edit counts + GoldgramArchiveScreen
                  -> native metadata bridge -> open exact source chat/message

Search by person: TelegramEngine.contacts (real peer selection)
    -> TelegramEngine.messages.searchMessages(fromId=authorPeerId)
    -> author-specific results and navigation (without archive writes)
~~~

- Native TelegramCore and its authenticated account own source identity and update ordering. Mx cannot invent missing Postbox peers. An ObjC/C boundary resolves native metadata asynchronously without duplicate login or duplicate storage.
- Collector is an **independent observed-event source**, not a second authority to overwrite existing originals. Bridge is a read-only export endpoint; importing merges into the existing account SQLite and deduplicates.
- Standard functionality and Ghost/invisible mode must remain intact. Passive collection/search must not mark messages read or reveal online status; do not open other chats automatically or modify privacy/read state.

## 3. Main iPhone SQLite: exact schema and lifecycle

Implementation: [GoldgramHistoryStore.swift](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/build-system/gold-next/GoldgramHistoryStore.swift). Schema is **v2** (SQLite PRAGMA user_version=2). Base location:
**Application Support/Goldgram/Accounts/{authenticatedAccountId}/goldgram_history.sqlite**.

Important implementation rules:
- Account ID comes from the **authenticated Telegram account**, never derived from peer/chat/message IDs; all keys are scoped by peer kind, peer ID and message ID. File is WAL-enabled; protect database and -wal/-shm sidecars.
- Writes are serialized through the storage queue and account-safe connections. Avoid blocking UI/render thread. SQL migration v1→v2 is transactional; additional indexes/audit tables are additive and do not reset existing data.
- Core tables: **dialogs**, **messages** (original_text, original_observed, sent_at, sender_kind/id, thread/reply/root-post anchors, deleted flag), **revisions** (version_index, text, observed_at, server_edit_at, provenance), **events** (edit/delete kind, unique event_key, source, observation/server times), **unresolved_deletions** (scope unknown — NEVER guess target dialog), **retention_settings** (NULL means forever).
- Additional additive tables **original_capture_evidence** and **original_capture_attempts** record verified first-original capture, source, enqueue/commit status and attempt counters within the **same database**. The capture source identifies where observed, not causal proof of successful background scheduling.
- Indices for full (peer_kind,peer_id,message_id) scope, revisions, source event time, author, discussion root and messages by sent time. Recent #235 added per-message event index to reduce full-dialog scans.
- **Clear journal categories independently**. Purging edited messages cannot erase deleted journal or reset whole SQLite. Do not run destructive migrations, drop tables or rebuild DB automatically. Data preservation across new IPA installs is mandatory.
- Legacy Mx migration: [GoldgramLegacyImporter.swift](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/build-system/gold-next/GoldgramLegacyImporter.swift) is opt-in and guarded by **verified source-account ownership**; never run silently at startup.

## 4. Native capture, lifecycle and evidence

Source map:
- [GoldgramNativeHistory.swift](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/submodules/TelegramCore/Sources/State/GoldgramNativeHistory.swift): native replay/difference/history, account-safe event capture, diagnostics, background refresh stages.
- [AccountStateManagementUtils.swift](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift): original/edit/public capture callbacks and authenticated source handling.
- [GoldgramEventPolicy.swift](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/submodules/TelegramCore/Sources/State/GoldgramEventPolicy.swift): event normalization/testable policy.
- [AppDelegate.swift](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/submodules/TelegramUI/Sources/AppDelegate.swift): app lifecycle and background experimental flows.
- [GoldgramArchiveScreen.swift](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/build-system/gold-next/GoldgramArchiveScreen.swift): operator diagnostics for Postbox/replay, BGAppRefresh, original evidence and SQLite COMMIT.

**iOS scheduling limits:** BGAppRefresh, push paths, CoreLocation/geolocation experimental activity and foreground/lifecycle triggers **never guarantee** the app stays active or captures all incoming originals. Compare stages separately: network/MTProto receipt → Postbox apply → SQLite admission → COMMIT → UI projection. The user's observed foreground capture is generally better than suspension capture, but never infer quantitative coverage without a controlled test.

Known difficult cases: public channel posts and linked discussion comments, peer/sender identity, delayed original after a Live sync, repeated fast edits, deletions with missing peer scope, navigation to already-removed server messages, stale UI counts and background delivery on LTE/VPN. Preserve true timestamps when available; do not substitute the observation timestamp for server send/edit time without explicit distinction.

## 5. Independent collector / Live Bridge

- Collector on jailbroken **iPhone 8** has its own Telegram session and local SQLite in **/var/mobile/Library/GoldgramCollector/**. Versions mentioned in historical conversations: V2.3, V2.4 and later **V2.7.2**; Supervisor version should match. **Installation of exact versions is not verified from this source repository**. Read current collector/supervisor scripts and installed config before touching them.
- Historical Live Bridge labels include V214 and V216. The tracked [GOLDGRAM_LIVE_SETUP.md](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/build-system/gold-next/GOLDGRAM_LIVE_SETUP.md) and [goldgram_iphone8_live_server.py](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/build-system/gold-next/goldgram_iphone8_live_server.py) describe **baseline Live v1**, not necessarily the deployed later VPS variant.
- Baseline protocol: opt-in **pinned-certificate HTTPS** pull on a local Wi-Fi link; random pairing secret protected by main-phone Keychain; **read-only SELECT from collector SQLite**. No exporting Telegram credentials/session files. Events are imported in validated batches; sender/peer kinds must be explicit. **Move per-account edit/delete cursors after successful SQLite COMMIT only**, retry after failure, deduplicate replay, reject ambiguous batches without cursor movement.
- The baseline v1 documentation states roughly **12-second foreground polling**, and explicitly disclaims 100% capture during iOS suspension. Remote experiments later used VPS, reverse SSH tunnel and HAProxy TCP passthrough for access across LTE/Wi-Fi; this is **not proof** of full background reliability. Do not store real endpoints, SSH material, TLS private keys/fingerprints or pairing secrets in any public doc.
- Some originally unknown messages later get genuine originals once catch-up arrives. Observe delayed recovery; never fabricate historical edits or treat network delivery as identical to UI refresh.

## 6. UI, archive grouping, edit counters and navigation

Key source:
- [prepare_mx.py](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/build-system/gold-next/prepare_mx.py): patch/integration into external Mx source during CI. Preserve original indices/action tags/persisted Mx setting identifiers; use exact, guarded patch anchors. Respect iOS SDK availability.
- [GoldgramArchiveScreen.swift](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/build-system/gold-next/GoldgramArchiveScreen.swift): categories for private messages, groups/chats, channels, deleted and edited history; live/import/diagnostics.
- [GoldgramArchiveGrouping.swift](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/build-system/gold-next/GoldgramArchiveGrouping.swift): accounts, folders, channel/comment grouping and pagination.
- [GoldgramMetadataBridge.m](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/build-system/gold-next/GoldgramMetadataBridge.m): asynchronous ObjC-to-native metadata resolver, avoids blocking UI/duplicating Postbox state.
- [ChatListController.swift](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/submodules/ChatListUI/Sources/ChatListController.swift) and [ChatController.swift](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/submodules/TelegramUI/Sources/ChatController.swift): native entry points and navigation.
- UI introduced around #244: direct personal/group archive tiles and compact Ghost layout, retaining earlier sections. Show **number of edits** next to a message in the chat itself (not just archive details; not emoji reaction count) and update after new edits. Opening deleted messages must preserve target scope/anchor and handle absent server messages honestly.
- Avoid SQLite queries during rendering/layout, do not corrupt read/unread status or invisibility. A data grouping fix is not complete until the iPhone UI confirms it.

## 7. Telegram author-based search — experimental

[GoldgramAuthorSearch.swift](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/submodules/ChatListUI/Sources/GoldgramAuthorSearch.swift) (landed via #245 onward, rebased into #250 experiment). Purpose: find messages **actually authored by one Telegram peer**, selected by saved contact name (including **е/ё**) or **@username**, not messages containing that name as text.

Two scopes: **«В этом чате»** / **«Во всех чатах»** (including locally enumerated root and archive lists). Results should show title of actual chat, snippet, timestamp and navigate to exact message. Code uses TelegramEngine.contacts and TelegramEngine.messages.searchMessages(peer/fromId); checks message.author.id. Anonymous admins, channel pseudonyms and forwards must not be falsely attributed to a human.

Explicit upper bounds in current code: **up to 1000 dialogs in root + 1000 in archive, 10 pages × 100 results per dialog, 2 concurrent requests**. A result with zero matches does **not** prove there are zero messages everywhere: pagination, missing local dialogs or RPC/network errors can limit coverage. The author search **does not use an independent iPhone 8 collector, create a separate Telegram login, or write archives**. Its behavior is **not confirmed on-device** until a green IPA is installed/tested.

## 8. CI and build performance contract

[Gold Next CI workflow](https://github.com/sviridovski/Telegram-iOS/blob/a159ca601d72750556f045ebb8820c4541f64ba0/.github/workflows/build.yml):
- Mac runner label **xcode-27**. Parallel **mx** and **native**, then **build** assembly, symbol/IPA checks; unsigned IPA is later re-signed externally.
- Mx compiled-output cache keyed to toolchain fingerprint and a deterministic set of Mx patch/input files. Native Bazel disk cache restored by key family using versions.json/.bazelrc/MODULE.bazel.lock and SHA. 10 GiB target Bazel cache GC and **12 GiB maximum cache upload size** are **disk storage limits, NOT 12 GiB RAM**. #243 runner logged **3 logical CPUs and 7 GiB RAM**.
- GitHub Actions cache is branch-scoped; a clean branch off green #243 does not guarantee access to cache built on sibling port/telegram-13.2 branch. Track cache restored key, actual cache hit/miss, Bazel hit count and completion time.
- Performance goal: **15–20 minutes** for hot-cache repeat runs, without compromising build correctness. Prior #243: Bazel compile ~214.5s, **8294 disk-cache hits out of 10103 processes**; new separate-branch #250 suffered probable cold cache. Distinguish GitHub runner queues/cancellations from compiler and test failures.
- New ChatListUI code must not directly `import Postbox` or use `.postbox`: PostboxImportCheck rejects this; use TelegramEngine wrappers. For Mx using `setSectionHeaderTopPadding`, guard with iOS 15 runtime availability when minimum target is older.
- **No heavy rebuild only to update these docs**: this documentation branch is deliberately not in the workflow's push branch filter. Do not change active branch build.yml solely to store project notes.

## 9. Non-negotiable constraints / working practice

1. **Never reset/create a second SQLite** for main-phone Goldgram; preserve all real originals, revisions, deletions, account scoping, retention and Live cursors.
2. **Privacy first**: no automatic read receipts, online status leak, account cross-contamination, forced chat opens or stealth-mode regressions. Do not publish message contents or authentication/security information.
3. An original is authentic only when evidence supports it. Keep unknown authors, unobserved originals and missing intermediate versions **unknown**, not guessed.
4. Don't modify iPhone 8 Collector/Supervisor/Bridge for a purely UI task. No automated transport switching without test and user request.
5. Keep a **last confirmed green CI** and a **last tested installed IPA** as two separate checkpoints. Don't claim a new commit or workflow is successful until API verifies all jobs and an artifact; don't force-push stable code.
6. All fixes: short diff, targeted tests, log of first real error, CI SHA/run links, iPhone acceptance criteria, rollback plan. Avoid multiple identical red builds; respect warm caches.
7. User works in **ordinary Chat inside ChatGPT project "Goldgram project"**, not Work. New chat reads these three docs and checks GitHub live first; don't force user to repeat project setup.

**Maintenance:** architecture changes update THIS file only after verified code changes; current build snapshot goes into [CURRENT_STATUS](./CURRENT_STATUS.md); dated tests and decisions are appended to [DECISIONS_LOG](./DECISIONS_LOG.md). In a public repository all content must remain sanitized.

## Navigation and Ghost exceptions update (#252, candidate; not yet device-tested)

- **Do not embed native ChatController in the UIKit Mx stack.** #251 rendered an empty/misaligned chat screen. #252 hands exact message ID to TelegramUI after dismissing the existing UIKit modal, pushes chat through Display.NavigationController with the existing GoldgramArchiveReturnController, and restores the same search modal on back/swipe. The return list retains its selected author and scroll offset; account checks are mandatory. See GoldgramAuthorSearch.swift and SharedAccountContext.swift at commit 5fd55a7acad0bdc380e0b4e824deab14adeb6aec.
- **Ghost exceptions:** the original empty-state plus icon was decorative; #252 candidate adds a selectable add-person row (also when list is nonempty), native contact/username selection and explicit confirmation. Only actual user peers can be added. Existing MxGhostExceptions store, keys, profile rename/removal and privacy semantics are preserved; online status remains outside per-peer exceptions. Restore automatic multiline footer/row height to avoid overlapping text. No new database. Verify on device before calling these changes successful.

## #254 candidate — local archive search and visual revision comparison

Search is an explicit read-only query over the existing selected-account SQLite and its visible-row projection, with legacy predicate fallback. A connection-local literal Unicode matcher searches verified original and stored revisions; no database/schema change, indexing side copy, new capture, cloud request, or network author lookup. Event-time filters, dialog scope, and known saved sender kind/id maintain existing identity boundaries. Results use existing native metadata/navigation, with search result generation/account checks. Visual revision comparison is a bounded UI projection of saved versions, not a rewrite of stored content or proof of any unobserved versions. Original is labeled only when evidence supports it; raw history remains available. Source commit 89185f6468e5081b46351689453fb47061c0fe75; #254 CI green and user reported working (see CURRENT_STATUS).

## #255–256 — unified search architecture

Native unified search UI (GoldgramAuthorSearch.swift) uses the selected account's TelegramEngine and a same-process, runtime-only C adapter to existing Mx GoldgramArchiveReader.searchLocal; no link to Mx module from ChatListUI and no duplicate DB. Explicit query filters, generation/account guards, bounded pages/deadlines, archive purge invalidation. Local saved text stays local; Telegram mode uses explicit TelegramEngine search. Canonical merge by full EngineMessage.Id / peer namespace (archive kinds 2/3 map CloudChannel), never by text or raw IDs alone. Unified period uses send time in both sources; standalone #254 event-date mode remains. Existing native exact jump and return controller reused; archived-only records provide saved-version preview and explicit prepare_jump availability check. Ghost author-selection path is separated from Ghost exception confirmation; existing privacy/capture/Collector rules unchanged. Source commit 3312ed8cc689e736665227874653251b47f7cdec; #256 fixes metadata dictionary construction (b616ea603876121253d4d7c40284e5aac6a0896d), all CI jobs succeeded and user confirms search works.

## #257 candidate — personal metadata and references

Goldgram personal bookmarks and contact cards are explicit user-created metadata in bounded versioned account-scoped JSON (Goldgram/Accounts/<account>/Personal/references-v1.json), atomic writes, iOS complete file protection, no backup for this metadata folder. This is not a second SQLite or archive and stores no message-body copies; references use canonical cloud peer/message namespace. Bookmarks are links to existing messages/currently visible archived revisions, not undeletable copies. Read exact archive identity via existing selected-account read-only SQLite with scoped messageId and revalidated revision visibility; no new schema/migration or capture. Personal contact alias/note is local only and never changes server profile. User-selected actual author can open search or own related bookmarks. Native jump/back reused. Dashboard and search toolbar routes are explicit UI actions. Source 80c974795d9bb1d029a8329817517404a1125a55; CI/device pending. Preserve Ghost, independent Collector, Live Bridge, account scoping and archive purge.
