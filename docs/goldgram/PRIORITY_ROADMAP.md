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

Read this roadmap at the start of future project chats along with the three canonical project docs. The user explicitly approved engine-first priority. Update milestones and decisions after each verified stage; never trigger an IPA build for documentation-only changes.


### #269 device checkpoint / #270 usability step
Original AICC request and generated response confirmed by user on iPhone. #270 candidate adds native engine-level per-plugin request/preview confirmation preferences with explicit scoped opt-out, reset and manual sending preserved. Verify on device before continuing broader GGAPI/multi-plugin work. This is part of Stage A, not engine acceptance.


## Approved detailed execution plan

**Подробный утверждённый технический план:** [PLUGIN_ENGINE_2_ROADMAP.md](./PLUGIN_ENGINE_2_ROADMAP.md). После проверки #270 следующий этап — многоплагинность (ориентир #271), затем сетевой API, SSE, UI, lifecycle, GGAPI/GoldAPI, обновления, диагностика и SDK. Номера ориентировочные; критерии приёмки обязательны.
