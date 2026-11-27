# Goldgram Plugin Engine 2.0 — утверждённый технический план P0

**Утверждён пользователем 25 ноября 2026.** После проверки #270 работаем по этому плану. Это детализация [PRIORITY_ROADMAP.md](./PRIORITY_ROADMAP.md), а не перечень уже реализованных функций. До приёмки движка не переключаться на AI Commander 3.0 или необязательные нативные функции Goldgram. Критические исправления, приватность, стабильность и CI остаются исключениями.

## 1. Базовое состояние
#267 подтвердил импорт JS и динамические настройки; #269 на iPhone подтвердил оригинальный AICC 2.1.8, его кнопку, запрос DeepSeek и ответ. Остальные команды, фактическая вставка, сохранение настроек и совместимость требуют отдельных проверок. #270 добавляет индивидуальные переключатели подтверждения запроса и предпросмотра. Состояние CI/устройства см. CURRENT_STATUS. Текущий runtime создаёт disposable WebKit Worker для действия и уничтожает его; выбирается первый активный плагин с плавающей кнопкой. Не считать ограниченный GGAPI полной совместимостью.

## 2. Целевая архитектура
- JavaScript Runtime: изолированные выполнения, ограниченный срок жизни, корректное асинхронное завершение, отмена и освобождение ресурсов.
- Permission Manager: разрешения и подтверждения на уровне аккаунта/плагина/версии; отзыв, проверка при каждой операции, безопасный режим.
- UI Engine: декларативные нативные компоненты, определяемые JS; регистрируемые кнопки, действия и экраны.
- Event Bus: типизированные события жизненного цикла, подписки, маршрутизация, освобождение обработчиков.
- Network Engine: ограниченные и явно разрешённые сетевые адаптеры.
- Storage Manager: изолированные настройки/данные, миграции и атомарное сохранение; секреты только в Keychain, без доступа JS к реальному ключу.
- Resource Manager: лимиты времени, запросов, объёмов данных, очередей и конкурентных операций; без постоянных фоновых JS-процессов.
- Diagnostics: ошибки, метрики, консоль и безопасный экспорт журналов без секретов и личной переписки.

## 3. Многоплагинность — ближайшая задача после #270
Реестр всех включённых плагинов вместо выбора первого. Составные идентификаторы pluginID/actionID, независимые кнопки и контекстные действия, стабильный порядок и управление видимостью; регистрация/удаление UI без конфликтов. Независимые очереди и контексты исполнения, корректное слияние изменений состояния без потерь, отмена только нужного запроса; запрет перезаписи изменившегося черновика. Выключение, удаление, обновление, смена аккаунта, уход из чата и safe mode очищают регистрации и отменяют затронутые операции. Нативный AI fallback не должен конфликтовать с JS. Не держать отдельный постоянно живущий Worker для каждого установленного плагина без необходимости. Тест: AICC плюс два независимых небольших плагина с одинаковыми локальными ID кнопок/действий, совместное включение, вызов, отключение, отказ одного плагина, параллельное выполнение, проверка состояния и изоляции на iPhone.

## 4. GGAPI и GoldAPI
Версионируемый каталог возможностей, документированные сигнатуры, разрешения и ошибки; runtime.hasPermission и feature discovery должны отражать реальные возможности, не фиктивные заглушки. Расширять GGAPI.chat/messages/ui/settings/storage/network/events/files/media/clipboard. GoldAPI.ai/speech/documents/search/favorites/contacts/runtime — собственные узкие сервисы по мере реализации. Доступ только к разрешённым текущим/выбранным данным; не предоставлять raw SQLite, Telegram session, произвольные нативные вызовы или обход ограничений доступа. Полная совместимость Ghostgram не обещана; проверять реальные плагины.

## 5. Сетевой движок
GET/POST для разрешённых адресов и методов, первым делом DeepSeek GET /models; хранение списка, обновление вручную/при устаревании и корректный fallback. Не объявлять модель новейшей без фактической проверки. SSE, потоковые события и итог, отмена, таймауты, ограниченные параллельные запросы и объём ответа, статистика; загрузка выбранных файлов и дополнительные провайдеры после проверки соответствующих возможностей. Разрешения на конкретный сервис/домен, запрет неожиданных redirects, локальных/внутренних адресов и передачи секретов сторонним сервисам. Пользователь управляет отправкой данных и подтверждениями, фоновые запросы не включать неявно. Секреты Keychain, JS получает только разрешённые операции. Учитывать ограничения API и стоимость, не гарантировать прекращение биллинга после локальной отмены.

## 6. UI Engine
Настройки и команды принадлежат JS, не хардкодить под AICC. Развить переключатели, списки, слайдеры, текстовые/многострочные поля, вкладки, вложенные разделы, карточки, графики, поиск, прогресс, контекстные меню и плавающие кнопки. Обновление схемы и состояния, валидация, локализация, доступность, безопасные callbacks и teardown. Длинные списки, клавиатура, тёмная тема и iPhone/iPad layout должны тестироваться.

## 7. Жизненный цикл и обновления
События регистрации, активации, действия, изменения настроек, смены контекста и деактивации; явные правила восстановления состояния disposable runtime. Импорт из файлов/буфера, редактор, hot reload JS без новой IPA для существующих API, миграция настроек и версионированный откат. В перспективе каталог GitHub с проверкой целостности/происхождения, совместимости и новых разрешений; пользователь выбирает установку, код не обновляется незаметно. Не переносить секреты в экспорт и репозиторий.

## 8. Диагностика
Журнал конкретного плагина: время старта/действия, сетевые статусы, отмена, ошибки, счётчики и доступные показатели ресурсов; безопасный экспорт. Остановить зависшее выполнение и защитить UI приложения. Не выдавать оценку памяти отдельного Worker за точное измерение, если iOS не предоставляет надёжную метрику.

## 9. Предварительная последовательность сборок
| Ориентир | Задача |
| --- | --- |
| #270 | Подтверждения — закончить CI и проверку на устройстве |
| #271 | Независимая работа нескольких плагинов |
| #272 | Универсальный сетевой API, список моделей |
| #273 | SSE/потоковая генерация, управление запросами |
| #274 | Расширенный UI Engine |
| #275 | События, жизненный цикл, регистрация команд |
| #276 | GGAPI: сообщения, файлы, медиа |
| #277 | Первая полноценная версия GoldAPI |
| #278 | Hot reload, управление версиями и откат |
| #279 | Диагностика и ресурсные лимиты |
| #280 | Комплексная проверка, SDK и документация |

Номера условные, могут сдвигаться или объединяться после тестов. Не начинать следующий крупный этап, если предыдущий требует исправления. Перед каждым этапом сверять HEAD, CI и подтверждённый статус устройства; точечные изменения, тесты и оптимизация тёплого кэша без отключения проверок. Цель сборки 15–20 минут, не гарантия.

## 10. Критерии приёмки
- Оригинальный AICC работает со всеми заявленными поддерживаемыми функциями, включая настройки из JS, профили, модель, команды и генерацию в черновике.
- Несколько независимых плагинов работают одновременно, без конфликтов регистрации и утечек состояния.
- UI определяется JS, поддерживает сложные формы и callbacks.
- Потоковые запросы, обнаружение моделей, безопасные сетевые адаптеры и отмена работают.
- Обновление JS без пересборки для существующих API, сохранение настроек, откат и безопасный режим.
- GGAPI/GoldAPI документированы, есть примеры, матрица совместимости и автоматические тесты.
- Нет регрессий Ghost, SQLite, Collector, Live Bridge, архива, медиапоиска и ручной отправки сообщений; соблюдены ограничения доступа, секреты и изоляция аккаунтов.
- Комплексные проверки на iPhone, а не только mock/CI. Стабильный baseline и явная приёмка пользователем.

После приёмки — две согласуемые линии: AI Commander 3.0 и другие самостоятельные плагины, а также нативные функции Goldgram. AI Commander 3.0: динамические модели, адаптивный выбор, кнопка AI 2.0, streaming, расширяемые профили, память, конструктор команд, документы/изображения/речь/веб при наличии разрешённых сервисов, расходы и новый JS-интерфейс. Это будущие задачи, не повод сейчас менять приоритет P0.


### #270 checkpoint — confirmed
CI green, user confirms both disabled confirmation dialogs no longer interrupt the workflow. Proceed to multi-plugin stage next; remaining lifecycle/persistence tests stay in regression matrix. No source changes at this checkpoint.


### #271 candidate — multi-plugin stage
Registry, independent controls/actions and bounded isolated execution implemented; A/B mock worker and Swift routing/merge/slots tests passed. CI and on-device acceptance pending, #270 fallback. Grouped layout, one floating button per plugin, global four-execution cap, no persistent queue. Next network stage only after validation.


### #271 accepted / #272 candidate
#271 green and device-confirmed by user; #272 implements scoped DeepSeek GET/POST, catalog cache/freshness, JS API and dynamic opt-in select. Existing AICC 2.1.8 unchanged. [CI #272](https://github.com/sviridovski/Telegram-iOS/actions/runs/45718823181) in_progress. Full device validation pending; next #273 streaming only after acceptance.


### #273 numbering adjustment
#272 failed twice in dependency checkout. #273 is a CI-only fix, retains Network Engine code, and is not the SSE stage. Proceed to SSE only after CI/device validation; subsequent build numbers shift.


### #273 accepted — Network Engine complete for tested flow
User confirms plugin catalog/generation work; screenshot confirms JS context menu registration. CI green. Next SSE/Streaming Engine (#274 target); individual actions and remaining negative-path tests remain in regression matrix.


### #274 candidate — Streaming Engine
User requested independent on/off controls for new features. Scoped opt-in SSE, optional live panel/indicator/partial result/statistics, legacy final response compatibility, worker progress callbacks and bounded cancellation implemented. Default off, original AICC JS unchanged. [CI #274](https://github.com/sviridovski/Telegram-iOS/actions/runs/45737637443) in_progress. Full iOS/device acceptance pending; #273 fallback. Next extended UI Engine only after validation.


### #274 accepted — Streaming Engine
CI green and user reports working streaming generation on device. Individual toggles, cancellation, partial answer and negative paths remain in regression matrix. Next extended UI Engine (#275 target); preserve user-controlled optional features and JS-owned settings. No new source build for this checkpoint.


### #275 candidate — configurable UI Engine
Native switches, numeric editors, searchable selections, optional grouped/settings schema and read-only UI, per-plugin action/button visibility/title, enhanced UI switch, explicit schema re-render and bundled UI test. [CI #275](https://github.com/sviridovski/Telegram-iOS/actions/runs/45751521153) in_progress. #274 fallback. Full UIKit/device verification and remaining advanced UI scope pending. Next P0 Event Bus after acceptance.

## #275 accepted — extended UI Engine checkpoint (2026-11-26)

User reports #275 works very well, sliders change the context menu, button editing works, and other tested functions work. This is user-reported device acceptance of the tested UI flows, not a separately instrumented pass of every acceptance-matrix case. CI [#275](https://github.com/sviridovski/Telegram-iOS/actions/runs/45751521153) remains green (all three jobs; 20m06s wall), feature HEAD `1699a18cbf304a3884f8b8a538cc8edfd0915f99`. #275 is now the current green/device-accepted recovery baseline. Remaining individual persistence, isolation, failure and regression tests stay in the matrix. Next P0 stage: Event Bus/lifecycle (target #276), typed scoped events, subscriptions/once/off and command registration, teardown and bounded disposable execution; exact implementation subject to source review. Preserve plugin-owned UI, optional controls, privacy, SQLite, Ghost, Collector, Live Bridge and cache/test configuration. No application code changes or new build for this checkpoint.

### #276 candidate — scoped Event Bus/lifecycle
Opt-in foreground chat.opened/closed, bounded per-execution on/once/off/local.emit, manual context-menu commands and native teardown. [CI #276](https://github.com/sviridovski/Telegram-iOS/actions/runs/45756006091) queued at first verification; #275 fallback. Full lifecycle parity, slash interception and durable background events not implemented. Verify CI and actual device; next P0 extended GGAPI only after acceptance.

## #276 accepted — lifecycle checkpoint (2026-11-26)

Following the prior 1/1 screenshot, user confirmed all works after being asked to verify the manual `/lifecycle` context-menu action and disabled chat event counters, and explicitly approved proceeding to #277. Treat those flows as user-reported working, not individually instrumented test results. #276 is current green/device-accepted recovery baseline (`ce7db08f07db254d132f88b99accaaee1233636a`; CI success, 31m11s). Restart persistence, rapid-navigation limits, account isolation, safe mode and earlier feature regressions remain in the test matrix.

### #277 target — extended GGAPI candidate
[CI #277](https://github.com/sviridovski/Telegram-iOS/actions/runs/45793342815) in_progress at verification; source 79e8a85b416b0c2048e39023ab834e664de849a6. Scoped visible-snapshot text history (not full server history), optional metadata-only media, bounded persistent logical text/JSON files in the existing plugin record. Test on iPhone before moving to further GGAPI/GoldAPI work. See CURRENT_STATUS and DECISIONS_LOG for acceptance and gaps.

## #277 CI and device checkpoint (2026-11-26)

[CI #277](https://github.com/sviridovski/Telegram-iOS/actions/runs/45793342815) succeeded (all three jobs, IPA artifact 15106681972, unexpired when checked); wall time 39m09s, source `79e8a85b416b0c2048e39023ab834e664de849a6`. User reports installing and completing all requested Data Test checks successfully. However, user reports shared plugin context actions missing in group chats and channels; personal messages and comments work. Screenshot shows ordinary text in a group with remaining auto-delete six days and no plugin actions. #277 remains latest green and installed baseline with extended GGAPI tested, but not full context-menu acceptance. No screenshot or private text published.

### #278 target — context menu regression before GoldAPI
[CI #278](https://github.com/sviridovski/Telegram-iOS/actions/runs/45803588004), source db6e30beea52703503994cc571272048803942b5. Separate read-only chat from writable composer, selected ordinary group TTL text with explicit native confirmation. Preserve private/protected/ephemeral boundaries. Verify device before resuming GoldAPI stage.

## #278 CI and partial device checkpoint (2026-11-26)

[CI #278](https://github.com/sviridovski/Telegram-iOS/actions/runs/45803588004) succeeded (all three jobs; IPA artifact 15111380378 unexpired when checked); wall time 36m54s, source `db6e30beea52703503994cc571272048803942b5`. User reports installing and shows the new selected TTL text consent alert in a group, confirming that the action is now accessible there. Requests an independent on/off toggle for this alert and reports missing plugin menu on the original channel post within its comments thread. No full acceptance of all channel/group or generation flows yet. Screenshots are evidence but not published.

### #279 — finish context-menu fixes before GoldAPI
[CI #279](https://github.com/sviridovski/Telegram-iOS/actions/runs/45811725164), source 0d047b339d9521f4c82b27635c98286bbb35ab2a. Per-plugin TTL warning toggle and exact current linked-discussion root ID; selected webpage preview text only. Device acceptance required before GoldAPI.

## #279 CI and partial device checkpoint (2026-11-26)

[CI #279](https://github.com/sviridovski/Telegram-iOS/actions/runs/45811725164) succeeded (all three jobs; IPA artifact 15116570980 unexpired when checked); wall time 35m39s, source `0d047b339d9521f4c82b27635c98286bbb35ab2a`. User installed #279 and confirmed that the warning no longer appears in the group with auto-delete, validating the tested opt-out path. User still reports missing AI Commander context actions on the news root inside its discussion; new screenshots show a publication with visible media plus text and an ordinary native menu without AI actions. Toggle re-enable and other regressions not explicitly retested. Do not publish screenshots or their private contents.

### #280 — caption/context fix before GoldAPI
[CI #280](https://github.com/sviridovski/Telegram-iOS/actions/runs/45873381350), source 699fc6667f77bb2f65c37a6326a30e2c1aceebf5. Selected caption text independent of media permission, native/worker metadata gating. Verify device before GoldAPI.

## #280 accepted — CI retry and device checkpoint (2026-11-27 local user date)

[CI #280](https://github.com/sviridovski/Telegram-iOS/actions/runs/45873381350) attempt 2 completed successfully on 2026-11-26 at 21:50:27 UTC. All three jobs report success; final IPA artifact 15156510182 and dSYM artifact 15155632437 present and unexpired when checked. Source HEAD remains `699fc6667f77bb2f65c37a6326a30e2c1aceebf5`; successful native and Mx artifacts from attempt 1 retained. No source fix was required for the cancelled packaging job. The exact reason for the first cancellation remains unknown.

User confirmed after installing #280: all works, context-menu issue finally resolved. Accept #280 as the new green/device-tested recovery baseline for the reported caption/discussion-root regression, retaining #279 confirmed TTL warning opt-out. This is user-reported acceptance, not independently instrumented or exhaustive regression/security testing. No further code, architecture, cache or build changes for this checkpoint. Resume approved roadmap with GoldAPI next, subject to user instruction; target next code build #281 (number not reserved). Existing SQLite, Ghost, Collector and Live Bridge constraints remain. 15–20 min CI target remains open; do not count elapsed time across the interrupted attempts as a successful single-build duration.
### #281 — first GoldAPI foundation candidate
[CI #281](https://github.com/sviridovski/Telegram-iOS/actions/runs/45918727516), source 62164bdf8df130c6efb06ea25d6e230e6198114c. Runtime/AI/visible snapshot search/text documents, independent grants and test plugin. See [GOLDAPI_1_REFERENCE.md](./GOLDAPI_1_REFERENCE.md). Speech, contacts, favorites, full archive search and rich document parsing remain planned rather than exposed. Device acceptance required; continue staged GoldAPI or next roadmap milestone after review.

## Proposed GoldAPI continuation after #281 (2026-11-27)

User asked whether the remaining GoldAPI services can be implemented after #281: speech, personal favorites, permitted contacts, expanded search and PDF/DOCX processing. Record all four as requested follow-up scope before Plugin Update Engine / SDK. Proposed grouping (assistant recommendation, not yet separately approved or committed to fixed build numbers):

- Target #282: GoldAPI.speech with on-device system TTS, explicit foreground play/stop, language/voice/rate, independent grant, bounded text, cancellation on context/account/background change; no microphone, external upload or always-on audio. Test availability of actual system voices and audio behavior.
- Target #283: GoldAPI.favorites and GoldAPI.contacts using narrowly scoped existing native services, separate opt-in grants, user-selected/current eligible message/contact, explicit confirmation for favorite writes/removals; preserve existing favorites storage and account isolation. No raw archive/SQLite, bulk address-book enumeration, hidden phone numbers or cross-account access. Verify exact native interfaces before implementation.
- Target #284: expanded GoldAPI.search via existing authorized native search, user-approved scopes, bounded results, cancellation and no read-state changes; separate document import/parse for user-selected PDF/DOCX via native file picker, size/page/text and archive decompression quotas, no arbitrary filesystem, no external upload unless separate explicit approved network action. PDF text layer and DOCX body text first; scanned PDF OCR, advanced formatting, images and document creation are not part of initial commitment. Split into additional builds if needed to keep risks manageable.

Each stage requires independent permission and sample plugin tests, regression of #280 menu/TTL and #281 services, CI and actual iPhone acceptance. Keep existing Ghost, SQLite/archive, Collector and Live Bridge untouched unless a narrowly scoped explicitly approved integration is necessary; no new database. CI 15–20 minute target remains open. #281 was still in progress when checked; no source changes or additional build launched for this plan. This is a proposed implementation sequence, not completed functionality.

## #281 accepted for tested flows — GoldAPI 1.0 checkpoint (2026-11-27)

[CI #281](https://github.com/sviridovski/Telegram-iOS/actions/runs/45918727516) attempt 1 succeeded: native, mx and build all green, 34m06s wall (00:46:48–01:20:54 UTC). Source `62164bdf8df130c6efb06ea25d6e230e6198114c` matches active branch HEAD; IPA artifact 15164980510 unexpired when checked.

User explicitly confirmed all nine checklist items on iPhone: installation/enabling of GoldAPI Test, capability discovery, writing the test document, reading/analyzing it, persistence after Swiftgram restart, Gold floating button in chat, GoldAPI text analysis in news context menu, existing AI Commander, and deleting the test document. Accept #281 as the latest green/device-tested recovery baseline for these flows. User expressly stated other tests are not confirmed. In particular, the optional real DeepSeek call via new GoldAPI.ai.complete, model discovery, SSE through the new wrapper, JSON import/export through the new wrapper, and exhaustive permission/safe-mode/isolation regressions remain unconfirmed on device. Existing AI Commander success is not proof of new GoldAPI.ai integration. Local 157/157 simulated worker assertions are prior evidence only.

Next proposed stage is GoldAPI.speech (target #282), followed by favorites/contacts and expanded search/PDF/DOCX as recorded above; no source or CI changes made at this checkpoint. Preserve #280 context fix and #281 confirmed functions. CI 15–20m target remains unmet. No build for documentation.
### #282 — Speech Engine candidate
[CI #282](https://github.com/sviridovski/Telegram-iOS/actions/runs/45943651626), source 2e5c81d86294ff471ada27ee9a20118a67459d59. GoldAPI 1.1.0 foreground system TTS/voices/stop, independent grant, bounded run lifetime and built-in sample. Verify real audio and cancellation before next favorites/contacts milestone.

## #282 accepted for tested flows — GoldAPI Speech / 1.1.0 checkpoint (2026-11-27)

[CI #282](https://github.com/sviridovski/Telegram-iOS/actions/runs/45943651626) attempt 1 succeeded: native, mx and build all green, wall time 26m40s (05:05:03–05:31:43 UTC). Source `2e5c81d86294ff471ada27ee9a20118a67459d59` matches feature branch HEAD; IPA artifact 15174268459 present and unexpired at verification. Compared with #281 (34m06s), wall time decreased by 7m26s; no cache/workflow change or causal attribution established. Target 15–20m remains open.

User explicitly confirmed nine iPhone checks: installed/enabled GoldAPI Speech Test, spoke test text, selected a different system voice, changed speech speed, stopped active playback, spoke a news item via context menu, TTS floating button spoke draft text, app background stopped audio, and existing AI Commander worked. Other checks explicitly unconfirmed. Accept #282 as latest green/device-tested recovery baseline for listed flows. In particular, account/chat-switch cancellation, permission revocation, safe-mode, competing audio/interruption handling, concurrency/timeout and programmatic stop are not separately confirmed on device. #281 optional new GoldAPI.ai real provider request, discovery/streaming and JSON wrapper tests remain pending. Prior 187/187 simulated worker checks are separate evidence, not exhaustive native tests.

Next stage: scoped GoldAPI.favorites and GoldAPI.contacts (target #283, number not reserved); inspect existing native interfaces and reuse existing storage, separate permission gates and explicit user-approved writes. Preserve accepted #280–282 behavior, SQLite, Ghost, Collector and Live Bridge. No code, architecture or workflow changes at this acceptance checkpoint; no CI dispatch for documentation.
### #283 — favorites and contacts / private TTL context candidate
[CI #283](https://github.com/sviridovski/Telegram-iOS/actions/runs/45949000625), source ffd4c60ce2fa5215d829db9b72f758624eab69b7. GoldAPI 1.2.0 integrates existing scoped personal references/cards with native confirmation, fixes private CloudUser long TTL selected-text menu. Verify device before expanded search/PDF/DOCX.
### #284 — Personal Hotfix candidate
[CI #284](https://github.com/sviridovski/Telegram-iOS/actions/runs/45959123469), source 08dda11bc5e43763904a29954c586508bad11f81. User-approved correction to #283: readable Personal Test 1.1, exact-source in-place upgrade, selected ordinary private TTL reference. Device acceptance before expanded search/PDF/DOCX, now target #285; later build numbers shift accordingly.

## #284 green / Personal 1.1 UI verified on device (2026-11-27)

[CI #284](https://github.com/sviridovski/Telegram-iOS/actions/runs/45959123469) completed successfully in 34m01s; source `08dda11bc5e43763904a29954c586508bad11f81`, IPA artifact 15181870986 unexpired at verification. First user video still showed old raw JSON format; assistant instructed explicit built-in update through manager. Second user video shows native favorites existing entries, Personal menu, count of one matching bookmark, selectable row, and formatted detail with title, folder, tags, date, note and reference type. Accept corrected Personal display for that tested flow; no raw JSON visible. Generic native output title "Goldgram AI" remains a cosmetic issue, not a blocker. No personal chat names, message contents or video uploaded to repository. Video does not demonstrate fresh creation/removal in a private TTL chat, expiry handling, contact card or AI regression; those remain unconfirmed. No code or CI changes. Next expanded search/PDF/DOCX after targeted acceptance, target #285. Preserve existing recovery versions and CI speed target.

## #284 accepted / #285 Search & Documents 2.0 candidate (2026-11-27)

User confirmed private TTL bookmark saving now works ("Да бро, все получается, переходи к 285") after #284 formatted Personal UI verification on video. Accept #284 as latest working recovery baseline for reported flows. CI #284 green, 34m01s, IPA 15181870986. No exhaustive expiry or optional real AI/network integration tests inferred.

[CI #285](https://github.com/sviridovski/Telegram-iOS/actions/runs/45966802832), source [2b33ec756b15def83dab2786e4e5f24b8610798f](https://github.com/sviridovski/Telegram-iOS/commit/2b33ec756b15def83dab2786e4e5f24b8610798f), direct parent #284; in progress at verification. GoldAPI 1.3.0, 20 service methods / 23 with runtime. Changed GoldgramPlugins.swift, GoldgramAuthorSearch.swift, ChatController.swift, new GoldgramPluginDocuments.swift and test_plugin_engine.py. No SQLite/archive, Ghost, Collector, Live Bridge, AICC JS, CI cache/workflow changes. Preserve #284 behavior and existing visible snapshot API.

- GoldAPI.search.history(query,{limit=8,since?,until?}) requires gold.search, new gold.search.history, chat.read and messages.read, explicit interactive run and current ordinary top-level cloud dialog scope. Native-only descriptor removed from JS payload; no caller peer IDs, no topic/linked discussion expansion, no archive or global search. Native confirmation shows exact query and warns that Telegram receives query and plugin receives results. Existing Telegram Engine searchMessages .peer only, one request per run, 20s timeout, first page up to 30 server candidates, max 12 returned ordinary plain/web-preview text matches, max 750 characters per result, deduplicated exact message IDs, optional positive Int32 Unix-seconds date bounds. Protected peers/messages, secret, expiring, ephemeral, restricted, spoiler, service/ad/sending/failed content filtered. No read receipt or send API introduced. Return items/id/text/timestamp, scope currentPeerHistory, complete false (bounded selection), serverCompleted and truncated. Cancellation on run invalidation; no persistent search state. No proof of complete history or remote availability.
- GoldAPI.documents.pickText() requires gold.documents and new gold.documents.import; explicit interactive native system picker, one user-selected file per run, local parsing on background queue, return only name/format/text/bytes/pageCount/truncated, no path or raw binary to JS, cancellation returns null. File <=8 MiB; max 48000 UTF-8 output bytes; PDFKit first 20 pages of unlocked text-layer PDF, no OCR or password entry; TXT/JSON UTF-8 (JSON syntax validation). DOCX reads word/document.xml only, conventional ZIP stored/raw-deflate, bounded central directory <=1024 entries, 512 KiB uncompressed main XML cap, no full unzip/disk extraction, CRC/size checks, reject encrypted/unsupported archive layouts, duplicate main XML, DTD/entities, disable external entities. Main body text/paragraphs/tabs/breaks only, not rich layout, images, headers, comments or full Word rendering. PDFKit internal resource limits not guaranteed by input cap; background parsing completion discarded on cancellation, not necessarily preemptible. No external AI request from test plugin; explicit separate existing AI permission/consent required for any later text transfer. Do not use sensitive files for tests.
- Built-in GoldAPI Search & Documents Test via Plugins > Установить тест поиска и документов. Enable, set query, tap Find in ordinary dialog containing older matching message outside visible snapshot, confirm and check bounded matches, cancel separately, test date bounds through API fixture. Settings action Открыть PDF / DOCX / TXT / JSON invokes file picker, shows text preview up to 3500 characters plus counts, explicit truncation indicator. Test each format, picker cancellation, scan-only PDF rejection, old Personal/AICC/speech and menu behavior. Scope/permission rejection and native teardown must be verified. Local V8 worker replay 249/249 assertions (228 prior +21 new). Added macOS CI native reader smoke fixtures to existing Python test: stored/deflated DOCX, DTD, oversized XML, CRC, missing/duplicate main part, TXT/JSON, UTF-8 truncation, synthetic PDF, Swift parse. Those native tests and iOS compilation pending; no local real native parser/device test. CI target 15–20m remains open; no cache optimization in #285.

Next after #285 acceptance: Plugin Update Engine (target #286), Diagnostics Engine, SDK, AI Commander 3.0. Numbers remain approximate. Finish any search/document regressions before further scope widening.

## After current plugin milestones

User's next priority is archive ingestion and discussion freshness stabilization, not further optional features. See PRIORITY_ROADMAP.md and CURRENT_STATUS.md (2026-11-27 post-plugin regression). Continue existing plugin sequence until accepted; then investigate independently reported import-on-Edited-entry and missing originals in comments, with evidence before changes.

## Plugin Update Engine 1.0 (#288 candidate)

Local manual import/paste into selected existing plugin, explicit version and permission review, preserved data and code-only rollback implemented as candidate. #287 preliminary commit superseded by #288 fixture/presentation correction. Verify CI and device acceptance before Diagnostics Engine. Remote update discovery, signed catalog and automatic data migrations remain outside this implementation; do not claim complete remote marketplace/update support. See CURRENT_STATUS.md for details.

## 2026-11-27 — #290 Plugin Update Engine core device acceptance

- User confirmed all three follow-up checks successful: retained label/counter/logical file after update to 2.0, version persistence after Swiftgram restart, rollback to 1.0 with retained data and renewed permission grant. Together with earlier installation/update success, accept #290 for reported core scenarios, promote to recovery checkpoint. No failures reported in these scenarios. Exact code HEAD f9f889dc93f1a836cbe7eb5c5cb4434d1c2bbe41, [CI #290](https://github.com/sviridovski/Telegram-iOS/actions/runs/46058439574) success reverified; previous verified IPA 15229194031, elapsed 37m30s. Do not claim unreported manual JS file/paste, cancellation, invalid-version/identity, optional permission additions, busy/safe-mode or actual Keychain secret preservation tests. Earlier #286 and other open tests remain open. Next Diagnostics Engine, then SDK and AI Commander 3.0, then Archive Reliability 2.0. No source change or new build; documentation only.
