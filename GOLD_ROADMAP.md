## 2026-10-26 Goldgram #113 — BG RPC trace (app commit b6bb0412)
- [App commit #113](https://github.com/sviridovski/Telegram-iOS/commit/b6bb0412c2ab959e0a347212369b5bea8104a573) created from green #112; [Actions run](https://github.com/sviridovski/Telegram-iOS/actions/runs/40253260921) initially in progress; recheck real conclusion.
- Diagnostic atom only: observe inner Postbox, MTProto readiness, real RPC subscription, errors/retries, raw typed response final/PTS/timeout, associated-data resolution and replay. Existing 24s BG limit, normal retryRequest, SQLite/Mx remain.
- New on-device issue: sometimes “Обновление…” persists after 1.5h minimized until relaunch. UI is ambiguous: transport status .updating OR global stateManager.isUpdating. Do not assume BG channel poll itself causes it; next evidence should separate foreground updates.getDifference lifecycle from transport. See detailed #113 section in GOLD_CURRENT_HANDOFF.md.
- Deferred separate atom: fix 7-edit diagnostics by edit event observed_at and discussion/thread scope, then controlled edit test. Ghostgram/VPS alternate remains deferred.

## CURRENT HANDOFF — 2026-10-18, #90 GREEN/device findings -> #91 notification-service capture, durable originals, totals


- #94 CI UPDATE: step9 COMPLETED SUCCESS, job117630331640: all12 Python checks, production timer guard, extracted notification consent/512-entry/4MiB handoff unit, actual async Swift SQLite writer + original JSON C bridge + exact production totals SQL + actual selected-account totals callback (2 edited/2 deleted), real Postbox codec, event policy/grouping and iOS SQLite store typecheck all PASSED. This confirms the correlated-ordering correction. Step10 Mx compilation IN PROGRESS. Full Swiftgram/Core/NotificationService build, IPA and device still pending; do not call full #94 GREEN yet.

### #93 confirmed SQLite scope defect / #94 correction

- #93 run39111813653 / job117629361156 FAILED step9, now with the actual SQLite error: production totals query preparation fails `no such column: m.is_deleted`. Both notification handoff fixture and truthful original C bridge passed. The defect is the correlated OUTER `m.is_deleted` reference in the ORDER BY of the latest-revision subquery, originally added in #89; local Python SQLite accepts this but Apple's CI SQLite rejects it. It also affects the shared archive messages query, not just the new totals.
- Removed the outer-reference condition: order by the LOCAL revision content being a missing-content sentinel, then local version_index. Actual received content remains preferred over placeholders for deleted AND edited records. No originals/events are manufactured. All12 Python suites pass after fix.
- Current follow-up **28fbd317c06a7870c99e38007a534d6d9dfd2870**, local8ad2871a, reviewed/API tree **b7b44d1f200783e5f6f5c06ff9f5f2fdfc1aa2a4** equal. **#94 run39112134878**, https://github.com/sviridovski/Telegram-iOS/actions/runs/39112134878 . Still the #91 functional atom, with CI corrections documented. Pending macOS runtime gate, full app/extension compile and IPA; do not call GREEN yet.

### #92 runtime finding / #93 diagnostics

- #92 run39111215466 / job117627566674 FAILED step9. Production notification consent/outbox unit fixture PASSED (including Codable handoff and bounds); actual original bridge tests PASSED (truthful original, unknown-original rejection, peer-kind isolation, embedded NUL/Unicode). Actual selected-account totals query callback then failed its `status == ok` precondition at fixture line79; original assertion did not print returned status. Full Mx/Core/UI/extension compile not reached. Do NOT call totals working yet.
- Initial suspicion about escaped SQL interpolation was incorrect: inspected actual byte sequence and SQL is correctly interpolated; separate Python execution is valid. No SQL change was made from that suspicion. Need actual callback status to determine the failing path.
- Diagnostic follow-up **f718b1377070110ac64427f8dcc59d3149bff177**, local79cda858, tree **a2ab0ceacaa56ce00832ce6e993da7800df11164** equal. #93 run39111813653 / job117629361156. Makes countsSQL internal so runtime fixture can run the exact production query directly, adds SQLite/status assertion diagnostics, and reduces excessive fake-cache JSON serialization while separately proving512-entry and4MiB limits. This is same #91 functional atom; do not claim a count fix until diagnosed and tested.

### #91 CI correction — same functional atom, #92

- #91 run39110988355 / job117626897175 FAILED step9 before Mx/host: extracted notification handoff unit fixture had a top-level `let pending` whose inferred type is private GoldgramPendingEvents; Swift required matching visibility. All12 Python suites and existing production timer-retention fixture passed before this error; new writer/totals fixture and full host were NOT reached. This was a test harness error introduced here, not a device result.
- Corrected only the fixture constant to `private let pending`. Follow-up **6111b28e44c86e1247b2182770f8a3af4ffec9d5**, local ae0e7b45, reviewed/API tree **e808a42591f104fbfede9c278a953304f2582abe** equal. #92 CI launched; functional app code remains the #91 atom above. Do not call #91 GREEN or issue device instructions for a nonexistent #91 IPA.


- User installed #90; screenshots IMG_0850/51 show known authors but missing original, plus first received edit in gray. Requests stronger background capture, research Swiftgram/forums/iOS settings, separate overall deleted and edited message counts in Privacy & Functions; one atom. New preference: after EACH natural-language assistant message suggest an improvement. Keep responses concise, Russian, bro. Attachments are available inline/scratch; do not read via Library. #90 full CI 39092253501 / 117571285484 CONFIRMED SUCCESS including Core/UI host/IPA; device findings still matter.
- #91 code **22a7a1d2a7f1b53b212ccb294300cc9374af5b31**, local bc4697f371567e73087df099c9891d2a4e7810fc; reviewed/API tree **1d7afcc9755e623f81e0c74f7b130b2e289c0c05** exactly equal. 12 files, 334 insertions / 48 deletions. CI launched; do not call GREEN until full completion.
- Root gap found in current source: standaloneStateManager used by NotificationService had NO Postbox StoreMessage preprocessor. Mx is intentionally host-only and its SQLite writer/defaults are not loaded by the extension. Main Account preprocessor alone cannot capture extension writes while host is suspended. Added the same preprocessor before standalone account managers/network are created. NotificationService direct deleteMessage notification now calls public goldgramRetainDeletion before deleting unretained IDs; replay missing-row edits/global-ID resolution use transaction-local capture permission too.
- Account-local consent + cutoff persist in Postbox itemcache -103 (explicit host setting, account ID, signed Int32 cutoff). Extension defaults OFF until the host has synchronized permission; it follows this shared setting instead of its own unrelated UserDefaults. Host sync runs on capture writes and every monitor tick (~15 sec while service active). Extension gets no arbitrary permission from a push. Existing normal Cloud/secret/scheduled namespace boundaries remain. Settings change can take until next active sync tick to propagate; do not promise instant extension toggle changes.
- Extension captures actually received original/edited message snapshots in existing -100/-101 stores, creates native inline history, and saves actual observation/edit/delete payloads into Postbox -104. Handoff bounded at512 entries /4MiB, dropping old observation-only payloads first; no empty deletion-receipt payloads. Host drains on its initial/15-second service tick, validates account, sends existing idempotent writer payloads, waits through new C flush barrier, THEN removes accepted durable entries. A writer failure conservatively keeps handoff data for retry; failure flag lasts for process lifetime. Queue overflow can still drop older events; this is bounded best effort, not unlimited guaranteed capture. Clear Logs removes -104 as well. This does NOT wake the extension itself or guarantee APNs delivery; it fixes capture when iOS already grants execution.
- Original recovery: independent Postbox baseline ring can evict a previously observed original while SQLite still has it. New goldgram_read_original_v1 reads only exact account/kind/peer/message with original_observed=1 and original_text non-NULL. Returned JSON strdup buffer freed by Core (preserves Unicode/newlines/NUL). Inline history can recover this truthful baseline on further receipt or archive navigation (current row AND reinserted snapshot). No author/original inferred from neighboring messages, first edited text or notification summary. If original never arrived, it stays explicitly unavailable. Full older media bytes/formatting entities cannot be reconstructed from a text-only original bridge.
- Foreground/background monitoring: bounded watch now covers up to8 recent actual personal/basic-group/supergroup/channel dialogs instead of4 linked discussion groups only, with 24h target age. Seed last100 bodies once per newly active subscription/wake. Cloud channels use stock reference-counted polledChannel and server timeout/pts-gap handling; personal/basic groups use normal account updates plus wake seed. No forced joins, read acknowledgements, media downloads or indefinite keepalive. User may still need to open desired discussion once; only accessible/received targets are eligible. More active channels add some network work; RAM/thermal profiling remains a later atom.
- Separate total EDITED and DELETED message counts added to Privacy & Functions footer, selected authenticated account only. Counts reuse unpaged production messagesSQL eligibility/body filters; count each message once per category, including both categories if edited then deleted. Repeated revisions are not counted as separate messages, empty receipts/untouched originals are excluded. Refresh on folder appearance and debounced archive event notification. Main-writer async commit posts event-only change notification; observations do not spam menu refresh. No schema upgrade.
- Research: Apple docs + Apple Developer Forums confirm Background App Refresh disabled by Low Power Mode and background push delivery not guaranteed, execution bounded. Sources https://developer.apple.com/documentation/uikit/uiapplication/backgroundrefreshstatus ; https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app ; https://developer.apple.com/forums/thread/827460 ; https://developer.apple.com/forums/thread/837675 . Suggested user settings: Settings > General > Background App Refresh enabled for Swiftgram; Low Power Mode OFF; notifications and signed push-capable provisioning working. This does not provide continuous execution while suspended. No fake audio/location or entitlement spoofing added.
- Local validation: all12 Python suites PASS; checked prepare_mx.py against a CLEAN pinned Mx 23c9803 checkout PASS; git diff --check PASS. Extended actual async Swift writer/reader fixture tests original lookup certainty, namespace isolation, embedded NUL/Unicode and real selected-account totals (2 edited,2 deleted despite extra empty receipt/baselines). Added run_notification_handoff.py compiling extracted production settings/enqueue functions against an encoded cache fake (default OFF, account isolation, host->extension consent, size/count bound, event preservation). Existing actual Postbox codec, timer retention unit, policy/grouping and iOS SQLite typecheck remain. These are not full end-to-end NotificationService/device tests; only macOS CI can compile Swift here.
- Next: inspect #91 validation gate then host/extension/IPA. If red, fix SAME functional atom and record exact failure. After GREEN install over #90, capture ON and foreground for >=15sec (sync consent), receive a NEW original from another client, background, edit twice/delete and reopen: verify original+numbered gray versions, dim retained tombstone, counters. Exercise real push delivery with host suspended; inspect silent/muted channel limitations separately. If unknown original was genuinely never delivered, do not claim recoverable. Existing #90 repeated timer/validation protection and explicit Clear Logs must remain. Proposed next improvement: small optional status indicating last capture / whether original was received, to distinguish delivery gaps from archival bugs; not implemented in #91.

---

## CURRENT HANDOFF — 2026-10-18, #89 GREEN/device findings -> #90 retained timer history, receipt filtering, background windows

- User installed #89. New findings: timer-deleted group message briefly appears after archive jump then disappears; many ID-only deletion receipts clutter lists; requests best possible capture while backgrounded and retention of ordinary personal/group auto-delete messages, one atom. Video and IMG_0846/47/48 inspected from scratch; do not upload attachments to Library. #89 full CI 39080839872 / 117537263266 confirmed SUCCESS, including actual Swift writer, codec, Core/UI host and IPA. Functional device findings remain separate from build success.
- #90 app commit **dde5aebcb50174208accba69b5b73f43de4103fc**, https://github.com/sviridovski/Telegram-iOS/actions/runs/39092253501, job **117571285484**, initially IN PROGRESS. Local commit be87ae95eb75c80849c81f5af6b93ffce0e345ee; reviewed/API tree **dd8757947a7e2aa22b2287cf29ac5cbcf63d3ba4** exactly equal. 11 files, 206 insertions / 21 deletions. No claim of full #90 GREEN or on-device verification at submission.
- CI update: #90 step9 COMPLETED SUCCESS (job 117571285484): all12 Python suites, the new production retention/validation guard unit fixture compiled and ran, actual asynchronous Swift SQLite writer, actual Postbox codec, policy/grouping fixtures and iOS SQLite store typecheck passed. Step10 Mx build IN PROGRESS at handoff. Full Core/UI host, IPA packaging and on-device behavior remain UNVERIFIED.
- Concrete disappearance path: HistoryViewStateValidation channel and reply-thread validators used stock deletion when the retained local message was absent from server getMessages. Retained Cloud-tagged messages now count as valid independently of channel pts, avoiding repeated invalidation/refetch. Both deletion callbacks preserve a retained row (also covering requests started before tagging) or retain the locally known message before verified deletion. Tag-only channel validation also skips an already retained row. Failed exact-ID confirmation or absent inputChannel now yields NO confirmed deletion; transport failure must not delete a local row or fabricate an archive deletion.
- Added goldgramPreserveRetained before the capture toggle/writer gate and before both timer branches: existing tombstones survive even after capture is disabled, stale autoremove/autoclear attributes and timestamp tags 0/1 are cleared. Restore normalizes already-tagged rows and missing-row snapshots too. Incoming tagged rows cannot reintroduce timers. Cloud min-available-range deletions now always pass each local row through retention, including with capture OFF; ordinary uncaptured rows still delete. No global interception of explicit Transaction.deleteMessages: Clear Logs can still remove retained copies. Secret chats and scheduled/local message namespaces remain excluded; this atom preserves ordinary Cloud auto-delete messages, not unseen content or one-time media recovery.
- Both production archive SQL queries filter empty/whitespace/missing-content sentinel bodies BEFORE GROUP BY/LIMIT/OFFSET. Receipt-only folders, counts and entries disappear without erasing diagnostic records. Any real original/revision or media summary remains eligible, including messages whose sender is unknown; old sentinel revisions cannot hide earlier real content. Unknown author is never guessed. Existing data become filtered on the next query without schema change or mandatory Clear Logs.
- Background: discussion monitor lifetime now follows selected account service-master AND Postbox master ownership rather than foreground boolean. It remains active during native background execution and push wake windows, stops with service ownership/time loss/account switch, and reseeds when resumed. On actual foreground->background transition with capture ON, reuse SharedWakeupManager's existing expiring explicit task (20 seconds), with native expiration cleanup. Normal personal/group/channel updates still use existing account managers and shared capture boundary. Existing max4 recent discussion subscriptions / native server-timeout polledChannel / 100-message seed remain; no extra joins/read acknowledgements/silent audio keepalive. iOS can suspend an app still visible in the switcher; Apple does not guarantee push delivery or continuous background runtime. Sources: https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time and https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app . Never promise all unseen edits/deletions while suspended.
- Local validation: all12 Python suites PASS, git diff --check PASS. Added production-SQL fixtures for blank/sentinel receipts, entirely empty folders, exact counts/paging, known text with missing author, media-only, original-only and older real revisions. Updated lifecycle/source-boundary checks. Added run_retention_guard.py to macOS step9: extracts actual production retention helper and HistoryState enum, compiles them with a small fake transaction to exercise repeated expiry/navigation/new pts, ordinary timers, scheduled exclusion and explicit cleanup. This is a unit fixture, NOT full Postbox integration. Actual async SQLite writer, real Postbox codec, policy/grouping and iOS store typecheck remain. Local host has no Swift compiler; new Swift fixture and full app compilation need CI.
- Next: inspect step9, then complete host/IPA. If red, repair this same functional atom and accurately record the failure. After GREEN install over #89 with capture ON; receive fresh messages in personal/group/channel, enable ordinary auto-delete, let expire, jump from archive, wait through history reload, leave/reopen/restart, verify dim retained bubble and media remain. Test capture OFF after retention, Clear Logs, empty-folder filtering and account isolation. Background: receive/edit/delete during initial expiring window, later push wake and foreground resync; never claim runtime during suspension. Missing content that never reached this client cannot be recovered from a deletion ID; it is now hidden. Precise historical comment-parent navigation, media not downloaded before deletion, RAM/thermal tuning and export remain deferred.

---

## CURRENT HANDOFF — 2026-10-18, #88 device findings -> #89 received-body persistence + foreground discussion monitoring

- User installed #88 and left Swiftgram foreground for three hours. Inline IMG_0840(1), IMG_0842, IMG_0843, IMG_0844 show many DELETION-only receipts for Comments Pozdnyakov with unknown author/sent time/body, plus an edited hope entry whose latest text and sender WERE received but original was not. Do not claim a SQLite message row proves its body arrived: native ID-only deletions also create rows. Do not invent author/original from surrounding messages. #88 full CI 39003209081 / 117310284386 confirmed SUCCESS; device launch confirmed by user. Functional capture still incomplete.
- #89 app commit **2e86953b603621d23a6779ccb3752638b65b622c**, reviewed/API tree **b10397be796e2f7fe5aa3f156cbdf6eedacb3d4e**, local a5c24629. CI **39080839872**, job **117537263266**, https://github.com/sviridovski/Telegram-iOS/actions/runs/39080839872 . Initially RUNNING checkout; full native build/IPA and device behavior UNVERIFIED. One authorized application CI commit, no extra branch push/rebuild.
- Concrete #88 source holes: native EditMessage replay called Transaction.updateMessage even when no native row exists. Postbox never invokes that update closure for absent IDs, so the shared #88 preprocessor cannot see that received edit. #89 inserts the full received cloud edit at its actual ID, location Random, when missing; existing-row mutation behavior unchanged. Snapshot ring is bounded to5000 and full updates are not equivalent to long-term SQLite content: #89 also writes changed full snapshots as observation eventKind=0 through the account-specific FIFO writer. Event0 stores actual received text/media summary, sender kind/ID, sent/thread/edit times and original certainty; NEVER inserts an event or exposes ordinary historical observations as edits. Unedited content can be an observed baseline; already edited first version is never called original. Legacy original callbacks are bypassed while native capture is available, avoiding duplicate/racing provenance writers.
- Another real writer bug: native deletion with retained=false could append the unavailable-content sentinel AFTER real SQLite revisions, making the UI show no content even though an earlier version was saved. #89 retains last real SQLite body/sender/time on an ID-only deletion. Existing affected #88 rows are recovered READ-ONLY: reader prefers a real saved revision over an unavailable sentinel for deleted records; no event/revision history is erased. This can recover only bodies actually still present in SQLite. Metadata COALESCE remains scoped to account+peer-kind+peer+message.
- Primary official research: https://core.telegram.org/api/updates section Subscribing to updates of channels/supergroups (lines336-347 at research time) explicitly says passive updates may stop or become fewer, getChannelDifference periodic subscription is needed, and accessible public/nonmember groups can receive passive updates while short polling continues. Server timeout/pts handling matters; app merely being foreground does not subscribe every linked discussion. https://core.telegram.org/method/updates.getChannelDifference and https://core.telegram.org/constructor/updateDeleteChannelMessages also checked. No guesses about joining private groups or recovering deleted bodies from an ID.
- #89 adds bounded discussion monitoring while MAIN APP + SELECTED ACCOUNT + FOREGROUND only. Account-local Codable item-cache -102 stores up to FOUR accessible group targets, last24h; references from an opened reply thread, cached verified linked discussion, or received group deletion. Broadcast->discussion recursion verifies actual group. Metadata list writes throttled60s. A15s LOCAL list/settings refresh maintains subscriptions, not15s network history polling. Each new subscription seeds latest100 accessible messages ONCE with messages.getHistory, merges real peers before message insertion, then reuses AccountViewTracker.polledChannel (existing reference counts, server timeout, pts gaps/retries). No read markers, joins, media downloads, broad discovery or changed online/ghost presence. Subscriptions/seed requests/timer disposed on app background or selected-account change; capture toggle disables subscriptions at next local refresh. This actively maintains a small monitoring set beyond the currently displayed chat. Limits and background behavior must be communicated honestly, not marketed as capture of every chat.
- ReplyThreadHistory now merges peers BEFORE adding discussion seed messages, so the common capture sees real group/user metadata. Opening a reply thread records its group target even if no new message arrives. Account initializer/common write boundary from #88 stays in place.
- UI now displays the actual first-known/current edited text as main body if original missing, with an explicit original-not-received note. A deleted receipt without body is clearly labelled Only deletion notification received. Local saved-record fallback distinguishes saved text without a native jump copy from truly ID-only receipt; no generic claim that every deleted fallback lacks text.
- Local PASS: all12 Python suites and git diff --check. Expanded actual-reader SQLite regression verifies recovery of earlier text hidden by a #88 sentinel; expanded source-contract test covers missing-row EditMessage insertion, observation persistence and bounded foreground lifecycle. New macOS CI Swift runtime fixture compiles the ACTUAL production GoldgramHistoryStore and calls its C writer on its actual asynchronous queue/real SQLite: observations don't create edit events; duplicate observation doesn't duplicate revisions; receive-original/edit/ID-only-delete retains actual original/latest/sender/time; unknown-original known edit stays unknown-original; receipt-only creates no invented author. Production iOS file protection unchanged (#if os(iOS)); macOS fixture uses empty file attributes. Existing actual production Postbox codec, Swift policy, grouping, and iOS SQLite typecheck remain. Full Core/UI compilation and on-device capture still pending at submission; do not conflate source-contract checks with full Postbox integration.
- Next after validation: install over #88; capture toggle ON; open desired comments once (register group), then leave app foreground, send a fresh message from another client, edit twice, delete. Check author/sent time/actual text, inline gray edits, deleted dim bubble, and jump. Monitor at most4 discussions; switch account/background and confirm observer stops. Existing empty receipts with no earlier stored body/author stay unknown. Very fast deletions before first delivery, inaccessible discussions, unseen intermediate edits, evicted/unreceived media bytes and precise historical parent-post navigation remain limitations. RAM/thermal tuning/export remain deferred; active monitoring adds bounded network work only foreground.

---

## CURRENT HANDOFF — 2026-10-17, #87 GREEN/device findings -> #88 common write boundary, sender preservation, first edit rendering

- Verified complete #87 CI (38995184124), job 117286064473, SUCCESS including host/IPA and codec runtime. User installed and app now opens, but reports a Den edited entry jumps to a normal edited bubble without gray revision, plus many Unknown author entries while app stays foreground. Inline screenshots show Den as Original unknown + current edit and separate DELETED discussion entries with no content/sender/sent timestamp. Do not conflate deletion-only receipts with edited messages or infer authors from nearby messages.
- User explicitly asked deep source investigation AND internet research. Official Telegram sources read: https://core.telegram.org/constructor/updateDeleteChannelMessages and https://core.telegram.org/api/updates . Deletion update has channel_id + message IDs + pts/count, no sender/text. Open foreground app is not evidence that every message body was actually received before deletion. This does NOT excuse our source gaps: reply-discussion fetching (ReplyThreadHistory.swift:181/713) and chat-list hole filling (Holes.swift:1211/1212) used transaction.addMessages outside the earlier Goldgram call-site list. Existing first-observed edited messages were also stored with a local attribute whose revisions list was EMPTY, so renderer hid it even though the archive had current text.
- #88 **e9f2fed6767dd43fe98fae1fcc8a3ff93aad7784**, https://github.com/sviridovski/Telegram-iOS/actions/runs/39003209081, initially QUEUED. Local 54c1ae2b; reviewed/API tree **f25dae01c4fcbe8eb783f9240203460dc80378e9**, exactly equal; 16 files, 151 insertions / 41 deletions. One functional atom. Do not call GREEN or device-verified yet.
- Postbox now has one account-instance StoreMessage preprocessor, installed at the beginning of authorized Account.init BEFORE NetworkStatsContext/other managers can enqueue message work. Installation uses the same impl queue as transactions; callback captures immutable authenticated peerId, never global last-user cache/account object. Both public Transaction.addMessages and updateMessage run it BEFORE actual native insert/replacement. Transaction reentry guard resets with defer. Existing partial manual replay/history/exact-ID prep calls were removed, so no duplicate capture. Every API caller using these common public methods, including discussion/chat-list/search/associated-message paths, is covered without maintaining a list of fetch functions. Direct internal media/flag mutations and secret/local namespaces are not claimed to be content edits.
- Local archive maintenance uses explicit preprocess:false when restoring retained snapshots/tagging local deletions, hydrating missing inline attributes and stripping them during Clear Logs. This avoids treating cleanup as another server edit, re-adding just-cleared history or blocking deletion tags. Tagged deleted incoming messages are passed through; existing tombstones remain protected. The new callback itself only reads messages and writes item-cache snapshots, never recursively replaces native messages.
- Snapshots now save even when native peer type has not been resolved yet, preserving first content/author ID before a subsequent peer merge. Edit events still require a VERIFIED peer type (no guessed channel/group classification) and the existing visible-edit/cutoff/content policy. Last captured snapshot is authoritative previous content even if a bypassing old native loader already overwrote the live row; preserves batch/recovery ordering. Older edit-dated payloads cannot replace a newer captured snapshot. No observation-only historic backfill reintroduced; old edit-date cutoff remains.
- Author ID is preserved if an incoming partial StoreMessage omits it. Native deletion resolves sender from live message OR independent snapshot author before writing the receipt. Snapshot conversion also keeps prior author when native rendered Message.author is nil due to missing peer object. New OPTIONAL authorName stores real cached first/last name or actual channel/group title, never a fabricated identity. Existing snapshots decode with nil authorName; actual Postbox codec fixture now tests both named/nil records. Metadata resolver looks up snapshot author ID in native peers, then stored name, then existing verified sender/source fallbacks, and can recover sent time from snapshot. No SQLite schema change.
- First observed recent edit with unknown original now has one actual gray revision beneath explicit Original was not received label. Known original keeps its white baseline + all gray numbered revisions. Decoder normalizes #87's old unknown-original + zero-revision attribute on load, so already saved Den-like records can display the known edit without fabricating original text or creating a new event. Archive jump hydrates an overwritten/missing local history attribute from snapshot ONLY when its text matches live message text. Empty captions/media summaries retain existing handling. Deletion rows in mixed archive now show saved content/unavailable content directly and no longer call it Revision or Original unknown, making the event type clearer.
- Local PASS: 12 Python suites including new SOURCE-CONTRACT regression for common write boundary/account queue/reentry and maintenance bypasses; git diff --check. Actual Swift policy fixture adds unknown-first-edit normalization and preservation of known/multiple/first-known versions. Actual production snapshot/real Postbox codec runtime fixture covers optional authorName. Both execute in macOS validation CI; full Postbox/Core/UI compiler and runtime/device checks still pending. Do not describe the source-contract check as a full live Postbox integration test.
- Observed #88 validation step 9 completed SUCCESS: all 12 Python suites, actual Swift grouping/policy fixtures including unknown-first-edit normalization, real Postbox codec round-trip including authorName/nil and high/all flag bits, and actual iOS SQLite store typecheck PASS. Step 10 Mx build IN PROGRESS; full Postbox/Core/UI host, IPA and device still UNVERIFIED.
- Next: finish #88 full host/package; early validation already confirmed PASS. If red, read first failed step, repair SAME atom. After GREEN install over #87; verify Den-like already saved edit now shows gray version + honest missing-original label; receive a NEW message in personal/group/discussion, edit twice, then delete remotely, verify sender/sent time/original/revisions/retention and jump. Exercise chat-list preview and discussion opening, metadata-only refresh, history reload, Clear Logs and account switch. Existing ID-only tombstones with NO stored content/author cannot be attributed retroactively; no mass fetch/polling, automatic chat joins or guessed author lookup was added. Snapshot quota/media-byte limits still apply. Native exact historical parent-post threading, RAM/thermal and exports remain deferred.

---

## CURRENT HANDOFF — 2026-10-17, #86 test harness dependencies -> #87 (same startup correction)

- #86 (38994842548), job 117285013365, FAILED validation step 9 BEFORE Mx/host. Existing Python suites and Swift grouping passed, but the new runtime fixture compiler could not find mdb_cmp_memn and postboxLog. These are real Postbox support functions, not an app compiler error or a result of running the startup regression yet. No IPA produced. This fixture wiring error was mine; do not call #86 successful.
- Exact native source owners verified: mdb_cmp_memn is defined in Postbox/Sources/ValueBoxKey.swift; postboxLog is in Postbox/Sources/PostboxLogging.swift. #87 adds BOTH unmodified production files to the standalone codec fixture compile. No stub/mocked functions, no changes to #86 application fix or #85 features. One runner file changed (2 insertions, 1 deletion).
- #87 code **85421b6b6e84c434b234b9f997232da3e5647f2f**, https://github.com/sviridovski/Telegram-iOS/actions/runs/38995184124, job 117286064473. Local a603f47c, reviewed/remote tree **336fe573e7e91b62d512895328130407ba212d8a**. Full app code is the #86 signed-bit-pattern codec correction below; no new functional atom.
- Observed #87 validation step 9 completed SUCCESS: all Python suites, actual Swift grouping/policy executables, actual iOS SQLite store typecheck, and NEW real Postbox codec runtime fixture PASS. The runner requires the old unsigned-zero snapshot representation to terminate with SIGILL/SIGTRAP and the fixed production record to round-trip every field and all zero/high/all-bit masks. This executed successfully on macOS CI, not merely a compile. Step 10 Mx build was IN PROGRESS; full native host, package/symbol checks and iPhone launch remain UNVERIFIED. Local runner Python syntax and git diff --check also PASS.
- Next: complete full host/IPA checks; codec runtime is already confirmed PASS. After GREEN install #87 OVER #85 and verify repeated launch/catch-up with capture ON before resuming inline history/deletion device tests. No forced reinstall or log deletion. Source analysis plus observed black-launch-to-home video is not a symbolicated device crash log. All #85 feature limits and #86 root-cause details below still apply.

---

## CURRENT HANDOFF — 2026-10-17, #85 GREEN but startup crash -> #86 Postbox codec correction

- Verified full Actions #85 (38980680964), job 117240571423, completed SUCCESS including native host/IPA. User installed #85 and reports immediate exit. Local 5-second screen recording was inspected via extracted frames: black launch screen then return to SpringBoard. Video has no symbolicated crash stack; do not claim device stack verification.
- Found a deterministic fatal path in the new startup/sync snapshot writer: GoldgramSnapshot declared flags/tags/globalTags/localTags UInt32 and passed it to CodableEntry. Actual Postbox _AdaptedPostboxEncoder.KeyedContainer supports Int32/Int64 but not UInt32; the generic Codable fallback reaches an unsupported scalar/container preconditionFailure. Even zero flag values trap. Native preparation snapshots the first cloud message during launch catch-up when capture is ON. Compile/typecheck/SQL tests did not exercise this runtime path; #85 green was not runtime acceptance.
- #86 code **23cda71f665f31b192936bae2be9228d178608f5**, https://github.com/sviridovski/Telegram-iOS/actions/runs/38994842548, initially IN PROGRESS; job 117285013365. Local df16e328, reviewed/remote tree **140f76aae8525cd8513484675e071043cb2933cc**. Correction only, no new functionality.
- Production snapshot wire record moved into Foundation-only GoldgramSnapshotRecord.swift. Four masks serialize as Int32(bitPattern:) and restore UInt32(bitPattern:), preserving ALL bits (including bit 30 tombstone and high/sign bit). Forward message reference stores signed peer/namespace/message primitives; native conversion keeps the same forward metadata. Native conversion delegates to the record initializer across files. No changes to SQLite schema/content or forced app/account data deletion. The old UInt32 format could not complete its first snapshot write through this codec, so no successful old binary snapshot migration is asserted or needed.
- New CI runtime regression runs REAL repository Postbox Coding.swift + all actual encoder/decoder adapter sources and actual MurMurHash32 Objective-C implementation, plus the exact production snapshot record. It first expects the old UInt32=0 path to terminate with SIGILL/SIGTRAP (suppresses core dump/backtrace), then executes fixed binary encode/decode and checks every field via sorted JSON equality and all four raw flag masks. Cases include 0, 1, bit30, bit31, UInt32.max, nil/present forward metadata, large IDs, Unicode text and embedded binary media/attribute data. JSON is used only for equality, never as a replacement storage codec. Runner is run_postbox_snapshot_codec.py, fixture test_snapshot_codec.swift; added to validation step 9 before Mx/host builds.
- Local PASS: all 11 existing Python suites, Python runner syntax compilation, git diff --check. New real Swift runtime fixture must run on macOS CI (no local Swift compiler). Initial #86 job was checking out; runtime test, full native build, package/symbol checks and iPhone launch remain UNVERIFIED. Do not call the startup fixed on device or #86 GREEN yet.
- Next: inspect #86 actual validation result, then full host. If red, fix the first actual failing step only, same correction. After GREEN install OVER #85, launch with capture still ON, reopen/restart and verify sync, then resume #85 device scenarios: old-history scrolling excluded; native edited original+gray numbered versions; deletion retention/media and archive jumps; Clear Logs. Do not ask user to reinstall/delete chats/logs preemptively. No further functional atom before runtime acceptance. All #85 unseen-content/offline-intermediate/media-byte limitations remain.

---

## CURRENT HANDOFF — 2026-10-17 Moscow, #84 GREEN/device findings -> #85 one unified correction

- Verified Actions #84 (38935241309), job 117088978290, completed SUCCESS including native host, injection, symbol checks, IPA upload. User installed and reports: Deleted Messages entries exist but tap errors, occasional edited-entry tap errors, old 2025 edited history appears just from scrolling, and wants original + numbered gray revisions inline in the native bubble. Inline screenshots visible; scratch attachment copies unavailable. Do not read them via Library. User explicitly requests ALL FOUR fixes in ONE functional atom.
- #85 code **7ad3be98ae08583541d12cb0de7589e3a534c0df**, https://github.com/sviridovski/Telegram-iOS/actions/runs/38980680964, initially IN PROGRESS. Reviewed local tree **f8d09930c3bad97efd67b293699bd90f1ab3521b** equals API tree, 18 files, 436 insertions / 94 deletions. Local commit 8da276b1. Full compilation, package/symbol checks and device behavior still UNVERIFIED; do not call GREEN or fully working yet.
- Causes confirmed: #83's observation-only recovery accepted any visible edited history item, even unchanged and years old. Archive screen itself refused all deleted rows without retained=true, so a deletion receipt with no received content immediately raised the generic jump error. Remaining C callback path only confirmed request acceptance, not content availability or completed native navigation, and did not sequence UIKit sheet dismissal with the host navigation.
- Native edit policy now uses a per-account persistent corrected-logger start time (GoldgramNativeHistorySinceV2.<account>). Server edit date must be positive, visible, >= start, >= prior edit date, and actual text/entities/stable-media identity must change if a previous version exists. Same-version replay creates nothing. Observation-only recovery is REMOVED. An old sent date does not block a genuinely NEW edit. Unknown first originals are not fabricated; only an explicit recent visible edit can be recorded unknown. First start is initialized on initial native preparation; this is not a claim to recover edits before that activation or every intermediate edit while offline.
- New accepted edit source goldgram_native_live_v2. Reader hides old goldgram_native_v1 edit backfill, including historical unknown-original rows, without deleting SQLite content. Credible earlier non-native legacy edits with known differing originals remain readable. Deletions keep existing source/receipt behavior; schema stays v2.
- GoldgramMessageHistory.swift adds a registered local Postbox MessageAttribute: baseline, certainty, baseline entities, all captured revision texts and edit dates. Current server message.text/entities remain the latest actual values for normal operations. Native text/caption renderer uses baseline at top and gray (0.55 alpha) numbered paragraphs below, with 12-point indent: Изменение 1, Изменение 2, etc. Missing original is labelled Первая сохранённая версия; never invented. Empty final captions still produce a text content node. Translation/pending media edits/message-options presentation keep stock behavior; history selection does not attach latest-server entity offsets or allow quoting a mismatched presentation range. Existing deleted dim/trash behavior remains. This is not pixel-exact Ghostgram replication or reconstruction of unreceived original media versions.
- Independent full StoreMessage snapshots serialize native media/attributes, sender, flags/tags, grouping/thread and forward info into account-local Postbox item-cache collections -100/-101. Verified stock Core uses 0...55 and application collections start +64. Ordinary baselines use a 5000-slot ring; actual captured edit/deletion snapshots are pinned separately until Clear Logs. Global-ID fallback maps only true user/basic-group namespaces, never a guessed channel. Native deletion first restores a missing live row from a previously received exact snapshot, then tags/retains it and backs up already available media. Tagged tombstones survive duplicate incoming payloads even with new capture OFF. Hooked history replay and exact-ID TelegramEngine LoadMessagesIfNecessary now prepare before insertion after peer merge. No background fetch/polling/network media acquisition added.
- New archive jump uses existing account-gated ObjC native metadata service with prepare_jump/open_message actions. It verifies exact account/peer/message, restores full local snapshots and retained media; live missing edited messages can make one exact-ID Telegram engine load on user tap. UIKit archive/menu dismisses BEFORE native navigateToChat. Does not depend on the old C registration or retained flag alone. If real content is absent/private/deleted before receipt, show a scrollable saved local record with an honest explanation instead of the old generic jump-failure alert. Account switch fails closed. Native forum/comment-specific historical parent-post threading is still not added; targets actual saved peer/message.
- Clear Logs now enumerates native edits plus all deletion events, removes only tagged deleted native records, strips local history attributes from ordinary live messages, clears both snapshot collections and retained media, and resets the account edit cutoff. Ordinary server message text/media are left intact. Unreceived content from the user's old empty tombstones cannot be recreated retrospectively; partially downloaded/previously evicted media bytes remain unavailable. Only complete local media at deletion uses the existing retained-media backup.
- Local PASS: all 11 Python suites and git diff --check. Existing shipped reader regression now additionally rejects old native backfill; valid fixtures use live_v2. Actual Swift policy fixture extended for old-history cutoff, new edit of old message, stale edit-date response, A->B->B->C->A replay/revert sequence. It runs in CI, not locally (no Swift compiler here). Full Core snapshot serialization and actual UIKit rendering are compiled in host CI; no claim of a local device/runtime test.
- Next: inspect #85 CI. If red, read first actual failed step/log and repair this SAME atom, no new functionality. After GREEN: keep capture ON; receive new text/photo/video and delete remotely, tap Deleted Messages -> named source -> actual retained native bubble, restart and repeat; edit one message twice and verify original+two indented gray versions in chat; repeat/refetch must not append duplicates; scroll 2025 history and ensure no imported edits. Test new edits to old messages, unknown-original label, account switch, Clear Logs and cache cleanup. Empty preexisting tombstones should explain missing content without promising a native jump. User has no spare account/friends; actual live channel/discussion changes are valid tests. RAM/thermal, exact parent-post association, export/import and wider retention policy remain deferred.

---

## CURRENT HANDOFF — 2026-10-16, #83 host compiler failure -> #84 binding correction

- User reports #83 RED. Verified Actions 38857348647, job 116831692833: validation step 9 SUCCESS (11 Python suites, actual Swift grouping/native-policy executables, iOS SQLite store typecheck), Mx build SUCCESS, injector installation SUCCESS; Build clean Swiftgram FAILED. No IPA produced.
- Exact first compiler failure: AccountStateManagementUtils.swift:4503 invalid redeclaration of `messages`. New AddMessages native preparation introduced a `let messages` in the same switch-case scope as the existing `var messages = messages`. Subsequent Incoming/Unsent/copyProtection type inference errors occur downstream in that case. No other Swift error appeared in the captured log; full compilation may expose later issues.
- #84 correction uses ONE mutable prepared `messages` binding at case entry and removes the redundant later declaration. Native preparation still happens before Postbox insertion; existing typing-draft custom stable ID mutation remains in place. Exactly one source file changed, no new functionality.
- Code f39e48d2904a54eade73b50ddfbf705c52748347; reviewed/remote tree b7c9e953d860ecd0efdab26ea9febde4b3378854. Actions #84 https://github.com/sviridovski/Telegram-iOS/actions/runs/38935241309 launched (initially QUEUED). All 11 local Python suites and git diff --check PASS. These checks do not substitute for TelegramCore/TelegramUI compilation; full CI, symbol/package checks and device behavior remain UNVERIFIED.
- Continue the SAME #83 native history atom. Do not add functionality before CI and user acceptance. If #84 fails, inspect its actual first failed step/log. All #83 event/media limits and proposed device tests below remain applicable. Do not call #84 GREEN or installable until its full run succeeds.

---

## CURRENT HANDOFF — 2026-10-16, #82 GREEN/device regression report -> #83 unified native event atom

- Verified Actions #82 (38835596892) completed SUCCESS. User installed code with names/authors visible, but reports deletion archive absent, intermittent edited archive despite MX pencil, and false edited entry opening a post without a visible edit. Inline screenshots compare another client retaining deleted media and this client's unknown-original entry. Attached scratch copies unavailable; images were visible inline. Do not treat #82 as event-capture acceptance.
- User explicitly requests **ALL fixes in ONE functional atom**: reliable edits/deletions, dedicated Deleted Messages subfolder in Privacy & Functions, real channel/chat grouping, deletion time, navigation to retained native message/media with dimmed deletion presentation. This supersedes earlier instructions to split these particular fixes into separate atoms.
- Root causes from source: MX neutralizes deletion IDs before authenticated TelegramCore update processing; no SQLite deletion writer existed. Old Goldgram edit hooks ran before Postbox comparison and missed history-load paths/unknown transient peer classifications, while treating generic edit update payloads (even no visible edit date) as edits.
- **#83** code **af58a2a87ffad905db5d617b70de8e3125d57fb3**, https://github.com/sviridovski/Telegram-iOS/actions/runs/38857348647, **IN PROGRESS**. One code commit, 22 files; reviewed tree 1af93d3736c8d1cd89fc24e42b36a6804c30dd2a exactly matches API tree. Full compilation and real-device results still unverified. No further functionality before CI + device test.
- New TelegramCore State/GoldgramNativeHistory.swift uses authenticated accountPeerId, native transaction peer type and exact message ID; C JSON callback goldgram_capture_event_v1 into serialized SQLite writer. Native callback lookup retries rather than permanently caching a missing injection. Both raw MX and parsed MX deletion neutralizers are bypassed ONLY when capture toggle is enabled and goldgram_native_history_host_v1 is available. Old MX behavior remains when native capture is off/unavailable. While capture is on, new native retention owns cloud deletions instead of the old MX Anti-Revoke neutralizer.
- Event processing is now before actual Postbox changes: replay AddMessages/EditMessage, both scoped and account-global delete operations; loaded history in Holes.swift after peer merge; normal cloud auto-removal timer (authenticated account ID passed from Account.swift); server min-available/history range removal. Global delete IDs resolve through transaction.messageIdsForGlobalIds; unknown IDs remain unresolved, never assigned to guessed chats/channels. Local/secret namespaces follow stock handling. Bulk min-available handling scans that affected peer on its transaction, never the render thread.
- Real edit policy requires a positive visible EditedMessageAttribute and actual text/entity/stable-media identity change when previous version exists. Webpage metadata/view/reaction refreshes are excluded as media changes. Unknown prior version is allowed only with an explicit visible edit attribute. Already visibly edited native messages missed via another path can be recovered idempotently as known-version observations; repeated same known version creates no new native event. Legacy unproven/unknown-original events are hidden unless an original, positive server edit time and differing saved text prove a change; existing storage is not blindly erased.
- Deleted native records retain full Postbox message/media references at their original account/peer/message ID and chronological position, with durable local tag bit 30 (stock Core currently uses local bits 0/1). Later repeated history/edit payloads preserve tombstones. Native bubble rendering dims retained messages, adds trash marker, resets recycled ordinary nodes; mixed media albums dim their deleted content nodes. Archive navigation permits proven native retained deletions and restores available retained media before native jump. This uses the existing native message navigator, not a newly guessed parent-post association.
- Already COMPLETE downloaded media and webpage image/file previews get a separate account-scoped retained-media copy, using hard link with copy fallback on a serial utility queue and temporary MediaBox keepResource pins. No media download/exfiltration/polling is added. Missing cache resources can be restored from these copies on archive jump or rendering retained native bubbles. This does NOT reconstruct content never received, partially downloaded full videos, evicted bytes that were gone before capture, or content removed by another client's separate archive. Full message records live in Postbox; there is no independent serialized message export/reinstall restore.
- Dedicated fifth MISC/Privacy & Functions subfolder **Удалённые сообщения** opens category 3: deleted-only across personal/basic-group/supergroup/channel, canonical channel+verified linked discussion grouping, latest deletion receipt ordering and dates. Detail shows sender/sent time and **Удаление замечено** time (Telegram delete updates generally have no authoritative per-message server deletion timestamp). Media-only entries use media descriptions instead of being rejected for empty text. Linked-channel grouping is current cached association, not a claimed historical per-comment parent-post mapping.
- SQLite stays schema v2. New writer records edit/delete sources and first deletion receipt idempotently, preserves originals, namespaces and existing sender/time fields, retains unknown global deletes separately. Deleted-only reader includes native retained flag + receipt time and keeps raw-row paging. Clear Logs additionally purges ONLY corresponding locally tagged native deleted records and retained-media copies through account-gated native batches; ordinary live Telegram messages are excluded. Account switch during purge can report incomplete cleanup rather than target another account.
- Local PASS: 11 Python suites (including executing shipped native writer SQL/parameter order and strict reader against false-edit/deleted-media duplicate-ID cases), complete prepare_mx.py on exact pinned MX source and generated fifth-folder/both-neutralizer gates, git diff --check. CI also compiles/runs actual Swift grouping + native event-policy fixtures, early type-checks the actual iOS SQLite store, builds Mx and full native host, and checks exported native host/writer symbols in packaged IPA. Observed #83 CI step 9 completed SUCCESS: all Python suites, actual Swift grouping fixture, actual native event-policy fixture and real iOS SQLite store type-check PASS. Mx compilation was IN PROGRESS; full native host, packaging, exported-symbol check and device behavior remain UNVERIFIED.
- Device test after GREEN: keep Goldgram capture toggle (currently labelled Originals in SQLite) ON; receive a NEW ordinary text/photo/video then delete it remotely or observe auto-removal, open Deleted Messages -> actual peer name/receipt time -> jump to native dimmed retained content; restart/reopen. Edit text/caption twice and test history catch-up; unchanged metadata and unedited neighboring post must remain absent. Existing false legacy entries should hide; old deletion events already swallowed by #82 are not automatically migrated from unscoped legacy MX markers. Test account switching, media cache cleanup/restoration, mixed albums and Clear Logs. User has no spare account/friends; real channel/discussion events are valid tests. Precise original news-post/comment threading, export/import, retention quotas and remaining RAM/thermal work remain deferred.

---

## CURRENT HANDOFF — 2026-10-16, #81 host compiler error -> #82 EnginePeer fix in CI

- User reports #81 red. Verified Actions #81 (38777652225), job 116569357514: Python/Swift grouping validation PASS, **Mx compilation PASS**, injector installation PASS, **Build clean Swiftgram FAILED**. No IPA uploaded.
- Exact compiler error: SharedAccountContext.swift:93:54, value of type 'any Peer' has no member 'compactDisplayTitle'. This is the new GoldgramNativeArchiveMetadata resolver; two sender-label accesses have the same type mistake. #81 fixed the #80 C-header failure; that previous failure is no longer active.
- Verified current source definitions before fixing: EnginePeer.init(_ peer: Peer) is public in TelegramCore/Sources/TelegramEngine/Peers/Peer.swift:591; compactDisplayTitle is public extension EnginePeer in LocalizedPeerData/Sources/PeerTitle.swift:7. TelegramUI/BUILD already declares LocalizedPeerData dependency.
- **#82 correction** code **0494e7dde285edc1070a012e405a45f8a7b72820**, https://github.com/sviridovski/Telegram-iOS/actions/runs/38835596892, **IN PROGRESS**. Exactly one source file changed: all three raw Peer title accesses now use EnginePeer(peer/author).compactDisplayTitle; explicit import LocalizedPeerData added. Reviewed tree 0ad36208bf4d93e7896eebefdaf46254bfcf8e80 matches remote commit. No new functionality, UI logic, DB, dependencies, bundle IDs, capture or media retention changes.
- All 9 local Python suites PASS and git diff --check PASS. Existing actual Swift grouping and Mx compiler were already green in #81. Full #82 host compilation/device acceptance still pending; do not call GREEN or installable yet.
- Next: verify #82 CI; if red inspect only its actual failed compiler/build step. After GREEN, user tests named folders, verified channel/discussion grouping, author/time and jumps. Inline dimmed deleted messages/media remain requested NEXT, not implemented in this correction. Do not advance another functional atom before device acceptance.

---

## CURRENT HANDOFF — 2026-10-15, #80 compiler fix -> #81; inline deleted history requested next

- **#80 RED**: job 116562539429, Mx step 10. All 9 Python suites AND actual Swift grouping executable passed. Swift Clang module import then failed at tgapiC/include/Tweak.h:7:35: pointer missing nullability type specifier, and GoldgramArchiveScreen.swift import tgapiC consequently failed. Adding explicit nullability for the new function exposed incomplete annotations on existing decompressGzip. No host build or IPA produced.
- **#81 correction ONLY**: commit **a42ebfe0fe9b7ef654b67715ccd2959491e1915b**, https://github.com/sviridovski/Telegram-iOS/actions/runs/38777652225, **IN PROGRESS**. prepare_mx.py now explicitly marks existing decompressGzip return/input _Null_unspecified (preserves previous unspecified contract) alongside the new fully annotated metadata resolver. Same reviewed local tree 00436e1c1c3ca5a43b94914c33cd579fa02d9ebb. Pinned MX preparation and all 9 local suites rerun PASS. Full Mx/host CI pending; no GREEN/device claim.
- **User's next desired behavior:** when another user deletes a normal message/comment/photo/video in a personal chat, group or channel, keep it at its chronological location in the ordinary chat so scrolling shows it, dimmed with a clear Deleted label. Goldgram archive should be optional, not the only way to see retained content. Explain feasibility and limits; user has not tested #80/81, so do not mix this feature into the compiler repair.
- Inspected pinned MX: TLParser.swift updateDeleteMessages/updateDeleteChannelMessages -> neutralizeDeletions; Hooks.xm raw deletion neutralization; UIHooks.xm currently renders a red trash marker for isDeleted, not general dimming of saved bubbles. This is an existing starting point, not proof that all media or all catch-up cases are retained correctly.
- Next inline feature plan after #81 GREEN/device acceptance: account/kind/peer/message-scoped local deletion markers, retain a full local message record in normal timeline, dim + Deleted state without losing authors/timestamps/native interaction; validate foreground and catch-up, scrolling/reuse, relaunch and account changes. For photos/videos, separately retain only files already received/downloaded, prevent normal media-cache eviction of explicitly retained files, define disk quota/cleanup. A thumbnail is not a downloaded full video. Text-only SQLite history cannot restore media or messages never received. No promise to reconstruct server-deleted unseen content or keep iOS process continuously awake. Historical parent-post mapping and inline edits remain distinct pending tasks.

---

## CURRENT HANDOFF — 2026-10-15, #79 GREEN + device verified; #80 named archive folders in CI

- User installed #79 and explicitly reports all good. GitHub Actions #79 (38720104041) verified **completed SUCCESS**. Event-only archive filter and root clear action are accepted on device; no further #79 regression assumed.
- User's next scope: real channel/chat names, grouping publications + edited discussion entries under their source channel name, sender names and original send date/time. Energy/RAM remains deferred.
- **#80** code **d3147e5d67b8cf37350d311b27ab4e3651110d11**, https://github.com/sviridovski/Telegram-iOS/actions/runs/38775670614, **IN PROGRESS at handoff**. Local reviewed tree 398c1da132ca70a499a03a27a0d710515b1f78c8 exactly matches API commit tree. No full compilation/device acceptance yet.
- Host adds @objc GoldgramNativeArchiveMetadata.resolve:completion: in SharedAccountContext.swift: main-thread account/record ownership gate, one bounded off-main read-only Postbox transaction per <=50 identities, completion ownership recheck, peer.compactDisplayTitle, actual local Message.author or saved sender_kind/sender_id fallback, timestamp backfill only from actual Message.timestamp. No text bodies cross the identity-only request. Uses exact Postbox getPeerCachedData(peerId:) API. Pinned Mx calls it through a runtime-only C/ObjC block bridge (tgapiC), with a single 5-second fallback for stalled metadata. No TelegramUI/Core hard link in Mx, no network requests or polling.
- Grouping: root dialogs sorted by visible name, canonical peer IDs distinguish homonymous channels. Channels queries include supergroups but UI admits only broadcast peers or groups with verified CachedChannelData.linkedDiscussionPeerId -> actual broadcast peer. Opposite cached link, when explicitly known, must agree. Channel + its current discussion merge under the channel name; known companion is included even if its event row is on a later index page. Combined event-only SQLite query binds each source (<=2) and preserves per-row peer kind/id/message ID, send-time ordering and raw-row pagination. Groups without a verified link keep their own name under Groups. This reflects CURRENT cached channel/discussion association, not historical per-comment proof of the original news post.
- Archive message cards show sender, original SEND date/time in device locale/timezone (never last_seen_at as send time), original/unknown-original, dimmed latest revision, edit/delete status, and actual source chat. Old saved rows get live metadata lookup too. If name/author/time unavailable, truthful ID/unknown fallback remains. No invented human author for anonymous channel posts. Each tap uses that row's original peer/message IDs; deleted entries keep existing warning.
- Changes do not add new delete-event capture, historical per-post comment mapping, persistence of name snapshots, retention, or inline chat-bubble rendering. Those remain separate future work; don't claim every old deleted item has recoverable author/name. Existing capture, schema v2, old MX hooks/settings, Help gesture, root clear and bundle/push IDs preserved.
- Verification PASS locally: 9 Python SQLite/browser/native navigation suites, new combined query fixture (same message IDs in distinct sources, unrelated peer/account isolation, real event-only filter, sender/time fields and paging), complete prepare_mx.py on exact pinned MX source, git diff --check. CI additionally compiles/runs actual GoldgramArchiveGrouping.swift fixture for sort, homonyms, cross-page merge and group-only scope. Both Mx and full host compilation must still pass.
- Next: inspect actual #80 CI. If red, inspect only first failed step/compiler error and repair this same atom. If GREEN, user tests old/new names, channel folder with publication + discussion entries, sender/time, unchanged neighbors absent, native jumps, account switching and clear logs. Do not start another functionality atom until user validates. Precise comment -> original news post link and inline confirmed original/dimmed edit remain pending.

---

## CURRENT HANDOFF — 2026-10-15, #78 device navigation verified; event filter + clear logs in CI #79

- User verified #78 navigation works. New regression report: archive includes ordinary unedited group messages (screenshots: peer 1428816434, message 397130). Root cause is the #75/76 reader predicate allowing any original_text for public peers, not false edit events in the writer.
- App commit **714390587c189bfb2532fa4ef7164aedd9b723bb** (same tree as local 5ab916b) on gold-next removes the original-only branch from BOTH dialogsSQL and messagesSQL. All categories now require edit/deletion events or a deletion tombstone; baseline originals remain stored for later comparison. Existing unedited rows become hidden without deleting real history. No schema or host hook changes.
- Added root-menu **Очистить логи** (8th row after 7 existing folders), explicit confirmation, clears all SQLite dialogs/messages/revisions/events and unresolved deletions for the bound active account; retains settings/schema, Telegram messages and independent old MX defaults. Runs on the same FIFO storage queue as writes/reads; transaction rollback on error. Subsequent capture remains enabled if previously enabled. This is logical history deletion, not a secure-erasure guarantee.
- Checks PASS: all 8 Python SQLite/browser/navigation suites, exact pinned MX prepare pipeline and generated root/action/category routing, git diff --check. Regression fixtures cover unchanged neighbors/dialogs, event-only counts, peer/account isolation, tombstones, transaction/cascade/rollback, retention preservation and writes after clear. Full iOS compilation and device testing NOT performed.
- **Actions #79** run ID **38720104041**, https://github.com/sviridovski/Telegram-iOS/actions/runs/38720104041 — **IN PROGRESS** at handoff. Full compilation and device acceptance still pending.
- User explicitly authorized publication: **«Разрешаю»**. Code sent through connected GitHub to **gold-next**, commit 714390587c189bfb2532fa4ef7164aedd9b723bb. Direct CLI push lacked credentials; remote API tree exactly matches the reviewed local tree 2304fe16e0279bf498b32574754629719cf57831. No CI success claimed.

- Next: obtain actual workflow run_number, verify compiler/build, then user tests unchanged messages absent, real edited rows present/tappable and clear action empties local archive. Names/authors, verified source-channel/comment mapping and inline original/dimmed edits remain future tasks. RAM/thermal work stays deferred.

---

## CURRENT HANDOFF — 2026-10-15, #77 device verified / #78 native archive navigation in CI

- **#77** `f2b9fcd9907475c7a5c4de97dbcb7b09d9004142`, Actions [#77](https://github.com/sviridovski/Telegram-iOS/actions/runs/38680046444): **CI completed success**. User installed #77 and sent screenshots: discussion group `1412957693` had two original-only observed texts; group `1306751210` displayed two entries **“Оригинал неизвестен”** with dimmed **“Редакция: …”**, showing some real public edit readback, plus two original messages. **Do not infer original pre-edit text for the two unknowns.** Device UI works but not yet names/authors, linked parent news post or navigation.
- **User's urgent complaint after #77:** peers remain `Диалог #rawID`, comments give no author, tapping archived text does nothing, unrelated discussion-group messages aren't grouped under original source channel posts. This was NOT implemented by #77, which was edit capture only. No changes to actual Telegram bubble rendering yet.
- **#78 functional atom (native existing-message jump only)** code `114edc346a462e3687a15d3a4fa7d2e5257b850d`, [Actions #78, run ID `38692442585`](https://github.com/sviridovski/Telegram-iOS/actions/runs/38692442585), **IN PROGRESS when documented**. `GoldgramArchiveScreen.swift` makes archived message cells tappable/disclosure, calls `GoldgramArchiveReader.navigateToMessage`. Mx C runtime bridge `goldgram_register_native_navigation_v1` accepts an optional native function pointer; trusted `SharedAccountContextImpl` registers and forwards only for the active authenticated account to existing `navigateToChat(accountId:peerId:messageId:)`, using correct CloudUser/CloudGroup/CloudChannel namespaces and Cloud message IDs. Account switch revokes the host handle; Mx checks selected account and IDs; main-thread only; failure shows a warning. Existing SQLite edits, schema, MX Anti-Edit, user settings, capture and bundle IDs untouched. Added `test_sqlite_native_jump.py` to CI. **Only valid native peer/message jump is intended; linking a discussion comment to the ROOT BROADCAST POST is NOT done, nor guaranteed to open deleted/inaccessible messages.** Do not claim working device navigation before tested.
- **NEXT REQUIRED in separate future atoms, after #78 GREEN + user iPhone acceptance:** authoritative peer names grouped by real Telegram channel/group, sender display names for archived text via trusted current-account Postbox (currently only `senderId` captured; no sender name; some channel sender unknown). Then capture/store verified linked discussion root/channel post and implement post/comment navigation where this mapping exists; never invent parent association from timestamps. Finally localized in-chat rendering “confirmed original” and dimmed latest edit without modifying server messages or old Mx pencil until tested.
- Deferred later: RAM, performance, GLEGram/Ghostgram IPA comparison, thermal metrics — user requested postpone. **Keep one functional atom → one green CI → iPhone test → next.**

---

## ACTIVE HANDOFF — 2026-10-15, #76 iPhone SQLite verified / #77 public edits in CI

- User installed #76 and sent real screenshots (07:01) of Goldgram → **Группы и чаты** listing three separate discussion-group IDs (each "Сохранённых изменений: 1") and a readable archived comment inside peer `1412957693`, message `35432717`. **This proves live public capture/readback works**, but the label "изменений" is misleading for original-only public observations. Channel-post capture still needs explicit device confirmation; no demonstrated edit version or channel association. User specifically requests grouping by actual **channel name**, linking each discussion comment to its news post, tapping to native message/thread, plus confirmed original and dimmed edit below instead of MX pencil. Do NOT claim these are implemented.
- **#77 functional atom:** code `f2b9fcd9907475c7a5c4de97dbcb7b09d9004142`, [CI #77](https://github.com/sviridovski/Telegram-iOS/actions/runs/38680046444) **QUEUED when documented**. Generalizes existing SQLite edit/revision/event SQL with `peerKind: Int32 = 0` to preserve private ABI, uses correct account/kind/peer/message composite keys, event keys include kind and duplicate/revert logic remains unchanged. Adds `goldgram_archive_public_edit_v1` C callback and host hooks for accepted `updateEditChannelMessage` in channels/supergroups and `updateEditMessage` for group updates. Only opt-in real text edits, not generic message resends. Archive UI already shows `latestText` as subdued detail when changed. The old personal writer and old MX UI are untouched. Modified `GoldgramHistoryStore.swift`, `AccountStateManagementUtils.swift`, `test_sqlite_edits.py`, new `test_sqlite_public_edits.py` and CI workflow.
- **PENDING AFTER #77 FULL CI GREEN + user device validation:** (a) peer name resolution for existing captured peers as well as new ones (native Telegram/Postbox authoritative, no guessed names), sort/group news by broadcast channel and discussions by real verified linked channel where known, and make event count label accurate; (b) account-safe navigation from archive record to exact native message/thread; if deleted/unavailable, truthful fallback; (c) observe reply/thread/linked channel root metadata before associating comments with source posts; no invented associations; (d) localized inline presentation of confirmed original with latest edit dimmed below in actual Telegram chat bubble (not just archive), without mutating remote/Postbox content. Implement as separate tested atoms, not all in one commit.
- User had previously deferred memory/thermal benchmarking of MX and GLEGram comparison until the archive workflow is usable. Keep that plan deferred; no changes to performance features in #77.
- Next right now: inspect only #77 CI; if red, fix this atom and rerun; do not begin names/navigation code before the user verifies #77 on iPhone.

---

## 2026-10-15 — #76 GREEN, comments behavior, RAM audit deferred

- **Gold Next #76:** code commit `825bdbb4c3275d96ed859eeff702a93f5e032308`, [GitHub Actions #76](https://github.com/sviridovski/Telegram-iOS/actions/runs/38671084000), status **completed / success**. This confirms CI only; user installation and content readback of fresh posts/comments have not yet been confirmed.
- **Comment scope:** #75–76 captures live observed text messages both from broadcast channels (`TelegramChannel.info.broadcast`, `peer_kind=3`) and linked discussion supergroups (`TelegramChannel.info.group`, `peer_kind=2`), with basic groups `peer_kind=1`. So text comments appearing as messages in a linked discussion group should be captured and displayed in **«Группы и чаты»**, whereas channel posts appear in **«Каналы»**. Capture is opt-in and conditional on accepted live update/known peer type. Comments **are not yet linked to their parent channel post**; no trustworthy parent ID mapping or jump-to-exact-comment implemented, no historical backfill or public-channel edit capture. Do not tell user comments will appear underneath each channel post.
- **USER-REQUESTED DEFERRED PERFORMANCE FOLLOW-UP (NOT CURRENT ATOM):** after history / archive capture works, compare memory usage and thermal/CPU overhead attributable to Mx/Goldgram hooks, especially message scrolling, repeated chat switching, warm resume, memory pressure and background re-entry. Compare actual behavior against user's GLEGram reference if feasible using the two IPA files and profiling; separate compressed/uncompressed size from RAM and thermal data. Consider symbol stripping only as a measurement experiment; do not change MX, optimizations or dependencies until user requests this later.
- Next step: install and test #76 with SQLite switch ON; wait for **new** text publication on subscribed channel and **new** comment in linked discussion while Swiftgram is running, then verify proper numeric dialog IDs and texts in respective Goldgram folders. If empty, diagnose only this atom before adding navigation/parent association.

---

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
