# PROJECT_CONTEXT — архитектура и инварианты Goldgram

> **Canonical project passport (part 1/3).** Project: **Swiftgram Gold / Goldgram**, source repository [sviridovski/Telegram-iOS](https://github.com/sviridovski/Telegram-iOS). This documentation branch deliberately has **no Actions build trigger**. Updated: **2026-11-23**. Primary language: Russian. This public repository must never contain private messages, account IDs, secret keys, credentials, personal IP/VPS endpoints, .session files, p12 or mobileprovision.

**Other parts:** [CURRENT_STATUS](./CURRENT_STATUS.md) · [DECISIONS_LOG](./DECISIONS_LOG.md). **Read all three before continuing the project in a new chat.** The live repository, CI and device tests are always more authoritative than a stale status snapshot.

## P0 development priority (user-approved 2026-11-25)

**Universal Goldgram Plugin Engine first.** [PRIORITY_ROADMAP.md](./PRIORITY_ROADMAP.md) is the controlling forward plan: finish reusable GGAPI/GoldAPI, plugin-owned UI/settings and callbacks, multi-plugin lifecycle, hot reload/import, secure scoped services, diagnostics, SDK and real-device tests before optional new plugin or native Goldgram features. AI Commander 2.1.8 is the first reference plugin, not a hardcoded replacement. After user-confirmed engine acceptance, resume both independent plugins and native Goldgram development. Critical regressions/security/privacy and CI fixes remain allowed. Preserve Ghost, SQLite, Collector, Live Bridge and target 15–20 min builds.

**Подробный утверждённый технический план:** [PLUGIN_ENGINE_2_ROADMAP.md](./PLUGIN_ENGINE_2_ROADMAP.md). После проверки #270 следующий этап — многоплагинность (ориентир #271), затем сетевой API, SSE, UI, lifecycle, GGAPI/GoldAPI, обновления, диагностика и SDK. Номера ориентировочные; критерии приёмки обязательны.

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

## #259 candidate — native bookmark action and search 2.0

Native context menu uses explicit user-selected ordinary cloud message identity with protection/ephemeral/service guards, reuses GoldgramPersonalUI, and optionally resolves currently visible archive via existing exact read-only adapter; no body copies, no additional capture or network write. Unified query adds optional inclusive send-time upper bound and send-date ordering in existing SQLite reader; defaults preserve standalone archive and exact-reference behavior. Native Telegram media filters use verified MessageTags and available message metadata; archive media classification not inferred. Search presets are optional metadata in the same protected version-1 JSON (no second store or schema migration), bounded at 20, account guard, explicit restore and separate search submit. Text highlighting is only display projection. Source faaae4908f5606f94d20405206f8bab7f1463832, CI/device pending.

## #260 candidate — configurable dashboard and message context menu

GoldgramLayoutPreferences stores installation-local UI choices only (versioned Codable JSON in UserDefaults, bounded decode, canonical known ID order, hidden/pinned IDs, corruption fallback). Default dashboard retains all 13 original tiles, archive totals and settings; customization uses the existing tile instances and route IDs, groups pinned tiles above the reordered visible tiles, retains totals/settings and a permanently accessible customization entry. No personal message content, SQLite schema, account data, capture, Ghost or Collector changes. Menu preferences affect only four additional Goldgram actions, not native Telegram actions: bookmark, search current chat, open personal favorites, contact cards. Only bookmark is enabled by default; existing ordinary cloud-message/protection guards apply. Native chat search button now has stable UIBarButtonItem identity and participates in UpdateChatPresentationInterfaceState's native right-button composition in ordinary cloud chats, excluding selection/search/secret modes. No timer/polling. Source 3481fad1b63864a45f48dd282ac4867d2d53a248; CI/device verification pending.

## #261 candidate — unified media center 1.0

Separate wide teal dashboard tile ID 33, integrated into #260 preferences migration (old default maps to new default; custom order/hide/pin retained, new ID appended). Existing Mx Media settings ID 22 unchanged. Native GoldgramMediaCenter in ChatListUI reuses account context, TelegramEngine search, root/archive dialog scope, explicit author/dialog pickers, personal bookmark bridge and native exact-message handoff/back. Eight categories over six native tag families; all view starts one page per family, 50/page, at most ten pages/family and 1000 deduplicated messages, cancellation/generation and active-family guards, 20/30s query timeouts. Current-account known cloud peers only; no protected/ephemeral/secret/spoiler/restricted/sponsored or expired entries, current local message/peer revalidation before preview/download/bookmark. Thumbnail decode from existing Telegram metadata, no automatic full media fetch. Explicit user-approved download through native engine resources into Telegram cache, system Quick Look when supported, exact-message fallback to native Telegram viewer. Links displayed from webpage metadata or caption, no auto-open. Local known-size/date/author/text filters and loaded-result sort; global author search is a bounded result filter, not exhaustive. One result per full message identity, no media archive reconstruction or second DB, no external service or capture/Ghost/Collector changes. CI/device validation pending. Source 67b1649a27ffe37cb1dac80b4f31d8be4e7e8734.

## #262 media center compile fix

EnginePeer in the 13.2 source has five cases, including community(TelegramCommunity). Media center acceptsPeer now explicitly rejects community and secretChat and fails closed on unknown future cases; ordinary user/channel/legacyGroup checks unchanged. Community is not supported by GoldgramUnifiedIdentity.sources, so no expansion of identity or capture. One source file changed; architecture and privacy boundaries otherwise unchanged. Source 7d1b137dbbde22ec6cffbcaac142735e9ba7ccfa; full CI pending.

## Media center lifecycle correction (after #262)

Do not clear GoldgramMediaCenter rows, search results, cursors or tasks in speculative viewWillDisappear: a cancelled sheet drag/pop can call it before dismissal commits. State belongs to the controller and survives cancelled transitions and native message handoff. ARC/deinit disposes the query, dialog, preview and download tasks on actual controller release. Explicit search/filter changes and account invalidation remain the clear boundaries; on account mismatch reset started and cancel preview/download. No change to protection gates, persistence, native media search, Ghost or Collector. Source fa1af6457deac9b55763e7bf8cd9fc3bd1fdeecb; device verification pending.

## #264 candidate — Media Center 1.1 freshness and migration-aware picker

Media-only picker adds known peer type, scoped ID, username, available tiny avatar (type icon fallback), last available chat-list message date and sorts by activity. Collapse only legacyGroup.migrationReference to an ordinary available supergroup in loaded dialog list; retain exact predecessor IDs and message identities, never merge by title or numeric ID alone. Standard picker behavior unchanged. Selected-chat media starts family 6 (unfiltered native getHistory, 100 messages/page, up to three pages) before six existing tag families; local filters still apply. Dedicated TelegramEngine.goldgramMediaSearch opts into remote-only search, explicitly reports missing primary remote reply, excludes secret additional results, and does not invoke ordinary Swiftgram silent forceLocal fallback. Existing normal search behavior unchanged. If initial recent history fails/times out/is empty, bounded read of up to 300 existing cached messages for the selected current peer, source-labelled, deduplicate exact message IDs and prefer server copies. No cache scan of other peers. Explicit refresh resets search; cancelled swipe state preserved. No new database, external session, media capture, Ghost or Collector changes. Source 745b2813e648d746cbbd90e60bc1c72c5bf8cc88. Full CI/device acceptance pending.

## #265 — merge newest indexed native history even on successful remote response

- #264 all three jobs green; final IPA artifact 14965342930 unexpired at verification. User installed. Picker now identifies active supergroup and last activity Nov 25 2026; media center still shows 140 remote rows dated July 2025, zero local rows; screenshot shows a current ordinary chat photo. Same-title picker improved, freshness not accepted. Exact server/parser cause remains unverified. #264 only read local cache if initial remote history failed, timed out or returned empty; successful stale response prevented independent local read.
- Published b2aa12134c7389ea267fc5c40394e14a07817591, direct #264 parent, three files verified: GoldgramAuthorSearch.swift, TelegramEngineMessages.swift, test_personal_metadata.py. [#265](https://github.com/sviridovski/Telegram-iOS/actions/runs/45513761277), status in_progress at check. Always seed selected eligible current peer from native Postbox cloud history before remote tag queries, use existing transaction.getMessages bounded upper-to-lower MessageIndex range limit 300 (verified API implementation) instead of allMessageIndices enumeration. Same account/peer, protection and ephemeral eligibility unchanged; no extra storage, background collection, archive schema, Ghost or Collector changes. Source IDs deduplicated; server-confirmed eligible result removes local marker. Remote/global search otherwise retained. Compact counts and newest raw current-peer timestamps for local and unfiltered remote history distinguish freshness from category filters. Explicit cachedHistoryPending guard prevents old timeout interfering with later requests. Existing swipe contract preserved. Ten source conditions checked before publication, CI preflight extended; no local iOS compilation or device test. Cache configuration unchanged, actual reuse pending. #264 last green installed, #263 swipe-confirmed fallback. After green IPA, compare newest local/remote history dates and ordinary media in same group, photo category and refresh; verify swipe and native jump/back. If still stale, inspect precise source freshness and eligibility before further fixes. Plugin engine + floating AI composer workflow remains next roadmap priority after media acceptance.


## #266 candidate — group auto-delete search presentation

Ordinary still-live group-wide TTL is treated separately from short/view-once/Autoclear/secret/protected media. Timed search rows remain transient and are tied to current native messages, with batched native observation and expiry deadline; native exact jump only after revalidation. No independent timed-media download, bookmark, archive copy or persistent store. All other eligibility gates and account boundaries retained. Source 9ed27532ab3576fe7a9b82a503f36116a6deea28, CI/device verification pending. See CURRENT_STATUS and DECISIONS_LOG for test conditions and limitations.


## #266 acceptance / Plugins direction

#266 group TTL search candidate is CI-green and user reports media freshness fixed. Native expiry/protection regression matrix remains a separate test. Next product phase is the hybrid Plugins platform; prior design is in CURRENT_STATUS and DECISIONS_LOG, not yet implemented. Do not alter existing archive, Ghost, Collector or account boundaries for plugin work.


## #267 candidate — local plugin architecture

GoldgramPlugins.swift owns account-scoped atomic plugin JSON and native manager/settings UI. Dashboard ID 34 is configurable. Imported JS is disabled until approved, executes on-demand in disposable local nonpersistent WebKit worker with restricted bridge and timeout, not persistent JSContext. Native settings are rendered from validated plugin-declared sections. No archive/Telegram/session access or network in MVP. This is a deliberate staged compatibility subset; see current status for exact boundaries and test gates. Source ccdb78d54cd638a27de8ecc96a1501ef6466c5c2, CI/device validation pending.


## #268 candidate — native AI service and scoped composer

GoldgramAI.swift implements an opt-in, per-account native AI service under Plugins. ChatController supplies only the currently visible writable ordinary cloud draft snapshot and guarded native insertion callback. Request confirmation exposes exact prompt/draft and fixed DeepSeek destination; Keychain secret stays outside JS, cancel/preview/insert require current identity. This is not yet the full GGAPI chat/network bridge and the imported 2.1.8 remains incompatible. Existing #267 JS runtime remains isolated. See current status and decisions for limitations/test matrix. CI/device validation pending.


## #269 candidate — plugin-owned AI and scoped GGAPI

Imported plugin source is authoritative for UI schema, profiles, commands and callback logic; native Swift provides narrow, user-approved bridges. Disposable worker registers floating button/context actions, runs original callbacks on demand; account/plugin-specific secure credential is not exposed to JavaScript. Native broker restricts requests to DeepSeek with payload confirmation and current chat/draft validity. Selected/visible currently authorized ordinary text only; no Telegram session, raw archive, send or typing access. First enabled floating plugin selected. See current status and decisions for tested subset and outstanding gaps. #269 CI/device pending.


## #270 candidate — native confirmation preferences

Reusable engine-level account/plugin policy governs repeated DeepSeek request and draft-preview prompts independently, default on and explicit user opt-out; no plugin-side policy mutation. Code/grant lifecycle reset, action scoping, existing permission/context validation and manual Telegram send preserved. See CURRENT_STATUS/DECISIONS_LOG. iOS validation pending.


## #270 checkpoint
Confirmation policy opt-out verified on device; see CURRENT_STATUS and DECISIONS_LOG. Next: independent multi-plugin execution.


## #271 candidate — registry / multi-plugin controls

GoldgramAIButtonGroup hosts per-plugin buttons with independent execution and shared movable layout; UUID-qualified context action routes, safe registration revocation, max four disposable workers, per-account/plugin execution lease, merge-on-commit of settings/storage. Shared draft snapshot remains authoritative. See CURRENT_STATUS and DECISIONS_LOG for limits, CI and device acceptance.


## #272 candidate — provider network policy and model catalog
Scoped native route dispatcher, sanitized provider metadata, key-scoped cache, explicit foreground refresh, plugin-defined dynamic model select; see CURRENT_STATUS and compatibility guide. No new database, no changes to archive/Collector/Ghost.


## #273 — native fallback versus JS plugin settings

Native reserve assistant and imported plugins have independent credentials and settings. Native configuration is keyed by account; plugin credentials are keyed by account and plugin UUID. Plugin UI/commands are JS-owned; the generic catalog does not overwrite legacy JS model choices. Native button switch does not disable plugin registrations. See CURRENT_STATUS for partial device verification.


## #273 accepted checkpoint
Network Engine and plugin generation accepted by user; JS-defined message actions visible on device. Next stage: SSE, maintaining native reserve/plugin separation and scoped permissions.


## #274 candidate — opt-in streaming transport

Native bounded SSE parser/delegate, per-plugin streamingOptions, local optional progress panel, scoped stop and compatible JSON, worker RPC progress callbacks. No new database, credentials or Telegram send capability. See CURRENT_STATUS and DECISIONS_LOG for limitations and test gates.


## #274 accepted checkpoint
Streaming transport accepted for the tested on-device generation flow; optional per-plugin controls remain an architectural requirement for new features. Next P0: extended declarative UI Engine. See CURRENT_STATUS and DECISIONS_LOG for evidence and remaining regression checks.


## #275 candidate — declarative plugin UI

Native controls and validated JS-owned schema, optional UI preferences scoped by account/plugin, explicit re-render and action filtering. No new permissions or storage database; see CURRENT_STATUS and DECISIONS_LOG for limits and test gates.

## #276 candidate — scoped event bus and disposable lifecycle

Keep disposable Workers and existing global execution slots. Opt-in automatic foreground chat.opened/closed subscriptions use only eligible chat metadata, no draft/messages, network, UI output or send. Scoped callback tokens, local event emission limits, current-context/grant checks, cancellation and local settings/storage merge. Explicit command registration maps to existing context-menu actions, not slash interception. No persistent runtime, plugin.stop/onUnload parity or guaranteed delivery. See CURRENT_STATUS and DECISIONS_LOG for test gates and limitations.

## #276 accepted — lifecycle checkpoint (2026-11-26)

Following the prior 1/1 screenshot, user confirmed all works after being asked to verify the manual `/lifecycle` context-menu action and disabled chat event counters, and explicitly approved proceeding to #277. Treat those flows as user-reported working, not individually instrumented test results. #276 is current green/device-accepted recovery baseline (`ce7db08f07db254d132f88b99accaaee1233636a`; CI success, 31m11s). Restart persistence, rapid-navigation limits, account isolation, safe mode and earlier feature regressions remain in the test matrix.

## #277 candidate — bounded GGAPI data services

Extend only the existing foreground snapshot boundary: text history is explicitly incomplete, selected media is kind/ID metadata behind optional media.read plus chat/messages grants, and logical UTF-8 files use optional bounded fileData in the existing account/plugin JSON record (atomic validated merge, no arbitrary filesystem or new database). No native archive, read-state, session or send bridge. See CURRENT_STATUS and DECISIONS_LOG for evidence and limits.

## #278 candidate — separate read-only context and writable composer

The plugin host may run foreground explicit actions in eligible ordinary read-only cloud chats; actual composer writes/native fallback and passive lifecycle retain writable-chat gate. Read-only draft proposals are local output only. Ordinary long-lived group/channel auto-delete text may enter only explicitly selected plugin callback after native per-action warning/consent and expiry checks; visible history, media and passive callbacks still exclude TTL. No secret/protected/ephemeral expansion. See CURRENT_STATUS/DECISIONS_LOG for test evidence and limits.

## #279 candidate — scoped discussion-root access and TTL consent preference

Native confirmation policy adds a backward-compatible optional per-plugin TTL warning opt-out, explicit consent once, same eligible selected ordinary text only, current grants/action/account checks and existing reset behavior. Linked-discussion selected-message access admits the exact available current thread channelMessageId/effectiveMessageId, not arbitrary foreign peer IDs. Selected text with webpage preview is treated as text only. Existing protected/secret/ephemeral exclusions, history and composer boundaries remain intact. See CURRENT_STATUS/DECISIONS_LOG for limits and acceptance.

## #280 candidate — text and media access are independent

For explicit ordinary selected-message actions, text captions on supported image/file attachments are treated as text when non-expiring and otherwise eligible. Native permission filtering and worker callback sanitization remove mediaKind when media grants are missing, without discarding the caption. Existing media-only gate, exact discussion root scope, secret/protected/ephemeral exclusions, history scope and composer safety remain. See CURRENT_STATUS/DECISIONS_LOG for limits and tests.

## #281 candidate — GoldAPI 1.0 foundation

GoldAPI is a separate frozen JS namespace injected into the existing worker alongside GGAPI/GG; no new persistent engine. Versioned runtime discovery, separately granted DeepSeek AI wrapper through existing native validated broker, scoped literal search over permitted current snapshots and bounded document text/file helpers. Existing storage and native context restrictions are unchanged. No raw database, archive or session bridge. See [GOLDAPI_1_REFERENCE.md](./GOLDAPI_1_REFERENCE.md) and current status for implemented methods and limits.

## #282 candidate — foreground speech service

GoldAPI.speech adds an independent gold.speech grant, bounded system voice enumeration and on-device text-to-speech through AVSpeechSynthesizer. A native session owned by the current disposable run has a global single-session reservation, visible Stop control, context validity/foreground checks and finite duration. It does not own an always-on player, request microphone access or change application audio session category. Native audio and UI behavior pending acceptance; see current status and GoldAPI reference.

## #283 candidate — scoped personal services and private TTL text

GoldAPI 1.2.0 uses existing GoldgramPersonalUI and references-v1.json for selected ordinary non-expiring message bookmark references and current-peer metadata search; explicit confirmed add/remove, no message copying, no new database. Current user or selected actual user-author contact metadata and existing local alias/note only. Native-only scope descriptors removed from JS payload; separate grants, active context/account rechecks, no caller-controlled IDs. Ordinary nonempty cloud private-chat plain text with long unexpired server auto-delete now uses the existing explicit selected-message TTL consent gate; all other protection and snapshot exclusions remain. See status/reference for limitations and pending tests.

## #284 candidate — Personal Hotfix

GoldAPI 1.2.1 preserves #283 service signatures and existing references store. Adds a narrowly scoped native-only expiring reference descriptor for the already eligible ordinary private TTL text selection; no author scope, no message copy or archive lookup. Expiry rechecked before native confirmation and write. Built-in Personal Test 1.1 renders selectable lists and readable details through existing system UI. Explicit manager upgrade matches exact prior built-in source, retains ID/settings/storage/grants and resets consent. See status/reference for limitations.
