# PRIORITY ROADMAP — universal Goldgram Plugin Engine

**Priority P0 — user-approved 2026-11-25.** Finish and stabilize a powerful, reusable plugin platform BEFORE resuming optional standalone plugin features or unrelated native Goldgram enhancements. AI Command Center 2.1.8 is the first reference/acceptance plugin, not the architecture's special case. Critical bug, security, privacy, compatibility and CI fixes remain permitted during this phase. Do not treat this roadmap as implemented functionality.

## Stage A — engine first
1. Verify #269 on iPhone with the unchanged imported original AI Commander: plugin-declared 57 settings, eight standard and three custom profiles, model selection, prompts, seven menu actions, draggable AI button, account-specific settings and actual DeepSeek request. Copy a news item/comment into the composer, tap AI, use the plugin-selected profile/model/prompt, preview and insert the answer in the original draft. Manual sending only.
2. Build a reusable, versioned GGAPI compatibility layer and GoldAPI; inventory methods, signatures, capabilities and permissions, test real plugins, document supported and unsupported behavior. No fake grants, successful no-op claims, or unconditional promise of full Ghostgram compatibility.
3. Generalize declarative UI, plugin-owned controls/settings, callback lifecycle, scoped chat/comment access, approved network services, account isolation and secure credential handling. Support independent plugins, multiple registered buttons/actions, collision handling and teardown; preserve app stability. Dynamic model selection via provider model discovery where supported, with user approval and current provider verification, not hardcoded latest-model claims.
4. Improve paste/file import, editor, hot reload without IPA for supported APIs, version rollback, safe mode, useful console/errors, limits/timeouts/cancellation, resource monitoring and permission review. No uncontrolled background work or raw Telegram sessions/archive/credentials exposed. Keep Ghost, SQLite, independent Collector and Live Bridge behavior unchanged; preserve access restrictions and explicit external-data approval.
5. Publish SDK/reference, permission and compatibility matrix, sample plugins and repeatable tests. Test at least the original AICC and independent small plugins exercising distinct APIs, simultaneous activation, persistence, reload/rollback, failure/cancellation, account and chat isolation, and regression of existing Goldgram. Check actual iOS device behavior, not just mocked JS or green CI. Optimize warm-cache builds toward 15–20 minutes without disabling checks.
6. Exit gate: agree with user that the reusable engine meets these acceptance criteria, known limitations are documented, and stable baseline is confirmed. No rigid build-number promises.

## Stage B — after engine acceptance
Resume both development tracks, choosing next features with the user:
- Independent plugin development: AI Commander 3.0, Voice AI, Smart Translator, News Analyzer, AntiScam Pro, Chat Analytics, Smart Digest, AI Search; examples, not automatic commitments. Plugin code/config updates should avoid full IPA rebuilds whenever existing native API suffices.
- Native Goldgram feature improvements: archive, media, search, UX and other agreed additions. Public Discussion Reader remains a deferred idea for genuinely public content via official widget, respecting access boundaries.
- Expand native APIs when justified by reusable requirements, with scoped permissions, tests and docs.

Start new project chats with [START_HERE.md](./START_HERE.md), then consult this roadmap and relevant canonical sections when needed. Refresh START_HERE together with affected records after meaningful project changes. The user explicitly approved engine-first priority. Update milestones and decisions after each verified stage; never trigger an IPA build for documentation-only changes.


### #269 device checkpoint / #270 usability step
Original AICC request and generated response confirmed by user on iPhone. #270 candidate adds native engine-level per-plugin request/preview confirmation preferences with explicit scoped opt-out, reset and manual sending preserved. Verify on device before continuing broader GGAPI/multi-plugin work. This is part of Stage A, not engine acceptance.


## Approved detailed execution plan

**Подробный утверждённый технический план:** [PLUGIN_ENGINE_2_ROADMAP.md](./PLUGIN_ENGINE_2_ROADMAP.md). После проверки #270 следующий этап — многоплагинность (ориентир #271), затем сетевой API, SSE, UI, lifecycle, GGAPI/GoldAPI, обновления, диагностика и SDK. Номера ориентировочные; критерии приёмки обязательны.


### #270 checkpoint — confirmed
CI green, user confirms both disabled confirmation dialogs no longer interrupt the workflow. Proceed to multi-plugin stage next; remaining lifecycle/persistence tests stay in regression matrix. No source changes at this checkpoint.


### #271 candidate — multi-plugin stage
Registry, independent controls/actions and bounded isolated execution implemented; A/B mock worker and Swift routing/merge/slots tests passed. CI and on-device acceptance pending, #270 fallback. Grouped layout, one floating button per plugin, global four-execution cap, no persistent queue. Next network stage only after validation.


### #271 accepted / #272 candidate
#271 green and device-confirmed by user; #272 implements scoped DeepSeek GET/POST, catalog cache/freshness, JS API and dynamic opt-in select. Existing AICC 2.1.8 unchanged. [CI #272](https://github.com/sviridovski/Telegram-iOS/actions/runs/45718823181) in_progress. Full device validation pending; next #273 streaming only after acceptance.


### #274 candidate — Streaming Engine
User requested independent on/off controls for new features. Scoped opt-in SSE, optional live panel/indicator/partial result/statistics, legacy final response compatibility, worker progress callbacks and bounded cancellation implemented. Default off, original AICC JS unchanged. [CI #274](https://github.com/sviridovski/Telegram-iOS/actions/runs/45737637443) in_progress. Full iOS/device acceptance pending; #273 fallback. Next extended UI Engine only after validation.


### #275 candidate — configurable UI Engine
Native switches, numeric editors, searchable selections, optional grouped/settings schema and read-only UI, per-plugin action/button visibility/title, enhanced UI switch, explicit schema re-render and bundled UI test. [CI #275](https://github.com/sviridovski/Telegram-iOS/actions/runs/45751521153) in_progress. #274 fallback. Full UIKit/device verification and remaining advanced UI scope pending. Next P0 Event Bus after acceptance.

## #275 accepted — extended UI Engine checkpoint (2026-11-26)

User reports #275 works very well, sliders change the context menu, button editing works, and other tested functions work. This is user-reported device acceptance of the tested UI flows, not a separately instrumented pass of every acceptance-matrix case. CI [#275](https://github.com/sviridovski/Telegram-iOS/actions/runs/45751521153) remains green (all three jobs; 20m06s wall), feature HEAD `1699a18cbf304a3884f8b8a538cc8edfd0915f99`. #275 is now the current green/device-accepted recovery baseline. Remaining individual persistence, isolation, failure and regression tests stay in the matrix. Next P0 stage: Event Bus/lifecycle (target #276), typed scoped events, subscriptions/once/off and command registration, teardown and bounded disposable execution; exact implementation subject to source review. Preserve plugin-owned UI, optional controls, privacy, SQLite, Ghost, Collector, Live Bridge and cache/test configuration. No application code changes or new build for this checkpoint.

### #276 candidate — scoped Event Bus/lifecycle
Opt-in foreground chat.opened/closed, bounded per-execution on/once/off/local.emit, manual context-menu commands and native teardown. [CI #276](https://github.com/sviridovski/Telegram-iOS/actions/runs/45756006091) queued at first verification; #275 fallback. Full lifecycle parity, slash interception and durable background events not implemented. Verify CI and actual device; next P0 extended GGAPI only after acceptance.

## Post-plugin priority — archive ingestion and discussion freshness regression (2026-11-27)

User explicitly requested that after the planned plugin milestones, work return to edited/deleted message reliability. Reported observations: edited list refresh/import appears to start only when user enters the Edited section; opening news discussions beforehand can show "оригинал не получен"; even after edited entries have arrived, a substantial number of comments still show missing originals. User reports iPhone 8 internet and VPN enabled. Device-reported symptoms only; no current collector database, logs, network trace, exact deployed script versions or cursor evidence inspected in this checkpoint. Do not infer a root cause, or claim that enabled VPN proves healthy event delivery. #285 CI was in progress at verification; no change to current plugin roadmap or source.

After completing and accepting the currently planned plugin sequence (including AI Commander 3.0, unless user changes priority), make archive ingestion/freshness the first native stabilization milestone, before optional additional native features. Investigation plan:
- Verify actual installed Collector/Supervisor and Live Bridge versions/config and health, using existing authorized diagnostic interfaces. Distinguish source capture, transport, validated import, committed edit/delete cursors, identity matching and UI invalidation. Check why entering Edited appears necessary; review foreground/start/resume triggers and existing notification path without relying on list-controller lifetime. Verify no read-state changes, unnecessary polling, or background execution guarantees beyond iOS limits.
- Use synthetic ordinary non-expiring unprotected messages in a controlled test dialog/discussion to isolate delivery vs display failures, compare collector and main-phone SQLite records and event order with account/peer/message identity, edit/delete batch cursor and commit outcome. Avoid logging private message text, secrets, session data or personal IDs in public docs. Confirm only legitimate existing archive scope; do not expand capture of secret, protected, disappearing/view-once or otherwise excluded content or bypass access boundaries. Preserve Ghost, independent Collector, Live Bridge and existing SQLite; no reset or second database. No speculative transport switch or modification until evidence.
- Check live update of an already-open discussion after successful authorized import, without opening archive list or restarting. Exercise startup/resume, reconnect, local/remote route if applicable, duplicate replay and interruption, existing originals vs unknown originals. For unavailable originals, distinguish pending synchronization from genuinely absent data; never fabricate original text or promise reconstruction if no valid retained source exists. Preserve already-known real originals and accurate revision ordering, deduplication and cursor-after-commit guarantees. Test deleted list freshness within existing authorized scope as well; user has not separately demonstrated a deleted-list defect.
- Acceptance: ordinary test results update in archive and corresponding open chat/discussion without manually entering Edited; missing-original classifications explained by traceable pipeline state, no false completeness claims; no regressions in privacy, account isolation, storage integrity, battery/network use, or accepted plugin behavior. Keep CI 15–20 min goal. No implementation or device tests performed for this newly reported issue yet.

## Approved AI Search sequence (2026-11-28)

User approved the proposed tiled AI Search plan. Foundation 1.0 (#300 candidate) is the native query-only planner and reviewed filters; Foundation 2.0 adds bounded multi-term search, dedup and results UI; then AI Intelligence scoped context/documents, Archive Reliability 2.0, and Semantic Search only after archive reliability with explicit eligible selected excerpts. Preserve existing ordinary search and privacy; no bulk archive transfer or global JS bridge. Verify each stage before moving on. See AI_COMMANDER_3_PLAN.md and START_HERE.md for status.
