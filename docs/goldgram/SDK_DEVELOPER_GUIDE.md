# Goldgram SDK 1.0.0 — руководство разработчика

Дата: 28.11.2026. SDK #292 CI success, установлен пользователем; проверка шаблонов на устройстве открыта. Runtime принят на #291. GGAPI apiVersion() = 5 (ограниченная совместимость, не весь Ghostgram), GoldAPI apiVersion() = 1.3.0. Источник истины: GoldgramPlugins.swift и реальные CI/device tests. Не считать документацию обещанием новых API. Движок продолжает развиваться вместе с плагинами.

## 1. Быстрый старт

Исполняемые примеры и машиночитаемый контракт: [SDK source](https://github.com/sviridovski/Telegram-iOS/tree/6adc8db8e378e2aa9e4216efc9c40c6936c756a2/build-system/gold-next/sdk). Скачайте нужный .js, в Goldgram > Plugins выберите импорт .js из файлов, включите плагин и просмотрите разрешения. Для обновления установленного плагина используйте его карточку > Обновление плагина, а не повторную установку. 

| Файл | Назначение | Проверка |
| --- | --- | --- |
| starter.js | Локальная метка, счётчик, настройки и storage | Изменить метку, увеличить счётчик, повторно открыть |
| search.js | Find SDK, текущий снимок и по переключателю подтверждённая история | Тестовый обычный чат, запрос, отдельно server history |
| documents.js | Выбрать PDF/DOCX/TXT/JSON, показать счётчики | Несекретный файл, отмена |
| ai.js | Вручную заданные промпт и текст; Keychain, отдельная кнопка генерации | Сначала без ключа; затем по желанию тестовый запрос с ключом, возможна тарификация |
| contract.json | 20 GoldAPI methods, scopes, permissions, host grants | CI сравнивает с runtime, версиями и нативным списком |

## 2. Манифест и версии

```js
// @name My plugin
// @author My author
// @version 1.0.0
// @requiresGoldAPI 1.3.0
// @permission.settings.read required
// @permission.events required
// @permission.ui.read required
GGAPI.settings.addSection({title:"Example",items:[{type:"button",key:"hello",title:"Hello"}]});
GGAPI.events.on("settings.action",p=>{if(p.key==="hello")GGAPI.ui.showSheet({title:"Example",text:"Hello"});});
```

Header comments parsed from first 100 lines until first non-comment nonempty line; required/optional or legacy comma-separated @permissions. Explicit name/author identity and numeric 1–3 component strictly increasing version for manual update, optional minimum GoldAPI checked by engine. Required unknown permissions block enabling/updating; supported optional permissions offered by existing grant UI (not granular per optional grant picker). Runtime.hasPermission tests grant, not complete availability. Update and rollback preserve UUID/storage/settings/logical files/Keychain namespace; clear executable registrations, grants, confirmation bypass, lifecycle subscription/opt-in. Explicit re-enable needed. Single previous code version, not data rollback; keep data schema backward compatible. Same metadata is not proof of provenance. No remote marketplace/signature or automatic migration runner.

## 3. Lifecycle and UI

Disposable WebKit Worker, source evaluated fresh each execution, globals not persistent. Register settings/handlers/buttons on top level. No network, message mutation or heavy work on load. Native events plugin.start, settings.changed, settings.action, floating.tap, context.tap, chat.opened, chat.closed; latter two passive, separate opt-in and grants, no RPC/output. Floating/context callbacks via registered functions; context action receives {message}, settings handler receives {key,value,pluginId}. Local events via local.* only, bounded dispatch. Catch expected failures. Await async operations, avoid unbounded loops/promises; app/context changes cancel execution. Native save after validated success may fail independently of worker completion.

| GGAPI group | Actual methods / caveats |
| --- | --- |
| runtime | apiVersion(), features(), pluginId(), hasPermission(name), grants(). Feature flags not proof of service success. |
| settings | addSection({title,group?,footer?,items}), define alias, clearSections(), getPlugin(key,fallback), setPlugin(key,value); settings.read. UI types toggle, text, textarea, select, slider, stepper, button, info, card, progress. apiKey text item becomes native secret field; read yields managed alias, never real key. |
| storage | get/set/getJSON/setJSON/remove, storage grant. JSON serializable values, no secrets. |
| events | on/once/off/emit, events grant. Local emission only, native events cannot be forged through emit. |
| ui/app | showSheet({title,text}), showToast(text), app.alert(title,text), app.toast(text), restartHint: ui.read; add/removeFloatingButton, add/removeMessageContextAction, select(title,choices): ui.mutate; actual chat context actions require messages.read, runtime scope. Header badge and removeChatMenuButton are compatibility no-ops, not real feature support. |
| chat | currentPeerId/currentChatInfo/draftText with chat.read; setDraftText/insertText with chat.write + available writable draft, existing native validation/preview. setTyping compatibility no-op (ui.mutate). No send API. |
| messages | visible/current/get/getSelectedMessage/fetch/getMessages with messages.read; history/getHistory(peerId,{limit,beforeId}) also chat.read, only current snapshot. No arbitrary peer access, complete:false. |
| commands | register(names,fn,options), unregister(token), list; chat.write + messages.read + ui.mutate. Context menu commands, not global slash interception. |
| media | selected/forMessage/info/visible, media.read + messages.read + chat.read, permitted metadata only, no download. |
| clipboard | setText(text), clipboard grant, native result output; no read API. |
| network | fetch(url,opt), stream(url,opt,onProgress), models(), refreshModels(force); network.fetch, managed key, native broker allowlist DeepSeek /models GET and /chat/completions POST only, confirmation per existing policy. No arbitrary hosts, proxy or raw credentials. |
| files | writeText/readText/writeJSON/readJSON/list/exists/stat/remove/pick/share; storage grant, nonpassive; picker/share interactive, flat logical names, bounded plugin-owned files. No filesystem bridge. |
| console/log | console.log/info/warn/error, GGAPI.log; local raw console separate from sanitized diagnostics. Never log secrets or private content. |

## 4. Permission matrix — 20 native tokens

| Token | Purpose |
| --- | --- |
| settings.read | Declarative settings read/write |
| events | Event subscriptions and local emissions |
| console | Recognized token; existing local logging is not gated by this token |
| ui.read | Display sheet/toast |
| ui.mutate | Register buttons/actions, selection UI |
| storage | Local plugin values and logical files |
| chat.read | Scoped current chat/draft metadata |
| chat.write | Draft proposal only, not send |
| messages.read | Eligible visible/selected messages |
| media.read | Eligible media metadata, other grants also required |
| clipboard | Propose clipboard output |
| network.fetch | Restricted native DeepSeek broker |
| gold.ai | GoldAPI AI methods, requires network.fetch |
| gold.search | GoldAPI search, requires chat.read/messages.read |
| gold.search.history | Confirmed current-peer history, additional to gold.search |
| gold.documents | Local text analysis, additional storage for logical files |
| gold.documents.import | Explicit document picker, additional to gold.documents |
| gold.speech | On-device speech, explicit interactive action |
| gold.favorites | Scoped personal references, chat.read and selected messages.read |
| gold.contacts | Scoped contact card, chat.read and selected messages.read |

## 5. GoldAPI 1.3.0: 20 service methods

Use GoldAPI.runtime.has("service.method") and capabilities() for scope + grants + availability; runtime.apiVersion() for version. Detailed signatures and return types in [GOLDAPI_1_REFERENCE.md](./GOLDAPI_1_REFERENCE.md). All service methods except cached ai.models require explicit interactive execution. Availability can still change.

| Methods | Permissions | Scope |
| --- | --- | --- |
| ai.complete, ai.models, ai.refreshModels | gold.ai + network.fetch | explicit DeepSeek / cache |
| search.messages | gold.search + chat.read + messages.read | bounded visible snapshot |
| search.history | above + gold.search.history | confirmed top-level current ordinary dialog |
| documents.analyze | gold.documents | supplied text |
| documents.saveText, readText, pickJSON, shareJSON | gold.documents + storage | plugin files / explicit JSON picker/share |
| documents.pickText | gold.documents + gold.documents.import | user-selected PDF/DOCX/TXT/JSON |
| speech.voices, speak, stop | gold.speech | foreground system speech |
| favorites.search | gold.favorites + chat.read | current peer reference metadata |
| favorites.selected, addSelected, removeSelected | above + messages.read | exact selected reference; mutation confirmed |
| contacts.current | gold.contacts + chat.read | current CloudUser |
| contacts.selected | above + messages.read | selected ordinary CloudUser author |

## 6. Resource limits and privacy

512 KiB JS UTF-8, 24 plugins per account state, 26 MiB encoded state; up to 4 concurrent workers, one per account/plugin. Start/change/passive timeout 8s, interactive native broker path up to 300s; network max 3 requests per run. Settings max 16 sections ×96 items, unique keys; settings/storage max 128 values, per value 8192 bytes, aggregate 64 KiB; files max 16, total 64 KiB incl names. Worker output cap 220000 JS chars and native message cap 256 KiB; native validation may reject earlier. Draft max 4096 JS code units, sheet/clipboard text max 16000. Snapshot max 36 rows; native history max 12 results from up to 30 candidates, 20s timeout, one confirmed search. Document max 8 MiB input, 48000 UTF-8 bytes extracted, PDF first 20 pages, no OCR. Speech max 1200 code points/4800 bytes, 120s, one global foreground session. No raw archive/SQLite, secret sessions, unrestricted profile/history, silent external transfer, auto-send or arbitrary filesystem. Do not put key/token/password in code/settings/storage/files/logs; managed key via native UI only. Respect protected/ephemeral/secret/excluded content and existing Ghost rules. Do not expand scope through IDs or fake context. Use explicit user actions, consent, scoped data, manual sending.

## 7. Diagnostics and compatibility

Detail > Диагностика: last 32 runs per plugin, 256 total, session memory only, typed outcome, event, elapsed, RPC/error counts, broker network attempts/status. Manual export and clear, no raw messages/prompts/keys/URLs/identifiers. Completed worker != successful downstream save or insertion. No exact per-worker CPU/RAM. Use synthetic input; do not share raw console containing personal data.

Test with test_plugin_engine.py in existing CI, worker mock and native fixtures; for actual device validate install/grants, settings, explicit action, cancel/error, restart/update/rollback, no unintended network, safe-mode and isolation. Mock provider not real provider. #292 300/300 V8 mock assertions with accelerated timers; actual CI success, SDK device examples pending. Full GoldAPI.ai provider call, optional history/picker boundaries, previous unreported scenarios remain open. No claim of full Ghostgram compatibility.

## 8. Extending SDK and engine

For each new plugin inspect exact existing source/API first. If missing capability is justified, define minimal native scope, grants, lifecycle, limits, cancellation and privacy; preserve existing method signatures or increment version explicitly. Update native supported grants, worker discovery, contract.json, this guide, GOLDAPI reference, tests and START_HERE as appropriate. Add positive and denied/absent-context fixtures, verify real iPhone when needed. Never silently broaden existing permissions. No rebuild purely for docs. SDK and engine evolve continuously with real plugin development; next AI Commander 3.0, then Archive Reliability 2.0 according to current plan.


## 2026-11-28 — #292 SDK CI green and installation confirmed

- Verified exact HEAD 6adc8db8e378e2aa9e4216efc9c40c6936c756a2, [CI #292](https://github.com/sviridovski/Telegram-iOS/actions/runs/46083992903) completed success; native/mx/build all success; created 2026-11-27 23:42:37 UTC, updated 23:52:45 UTC, elapsed 10m08s. IPA 15238940725 present and unexpired at verification. User reported "я установил 292". Record installation only; do not infer SDK template device acceptance. Runtime unchanged from #291. #291 remains accepted recovery checkpoint. #292 substantially faster than #291 but no native code changed; no general 15–20m native build guarantee, no cache/workflow changes. CI goal remains open for native changes.
- Suggested device checks: import individual SDK JS files, Starter label/count, Search Find SDK current chat (confirmed history separately), Documents user-selected harmless file, AI explicit generation with managed key on synthetic text (optional real potentially billable provider request). No new app UI from SDK commit. Template device results remain open; all earlier unreported checks remain open. Next AI Commander 3.0 after SDK acceptance; engine/SDK ongoing. No source changes or new build launched; docs only.

## SDK 1.1.0 / GoldAPI 1.4.0 candidate (#293)


## GoldAPI 1.4.0 — #293 candidate, AI Engine 2.0 foundation

- 22 service methods, 25 incl runtime; GGAPI runtime stays 5. Manifest hostVersion 1.4.0, previous minimum 1.3.0 still compatible. SDK contract 1.1.0, previous templates kept at minimum 1.3.0. Two new native tokens gold.ai.balance and gold.ai.usage. No change to previous grant behavior or chat scope.
- `await GoldAPI.ai.complete({model,prompt,text,maxTokens?,temperature?,thinking?,reasoningEffort?,timeoutMs?},onProgress?)`: existing arguments unchanged, thinking boolean -> {type:enabled/disabled}; reasoningEffort low/high/max only, reject combination thinking false + effort; omitted retains provider defaults. timeoutMs integer 1000..240000, default 75000; original worker deadline remains 300s. Existing maxTokens, body and consent limits unchanged. Native broker still allowlists options and DeepSeek endpoint; native SSE opt-in/Stop policy unchanged. Result additive `{text,partial,finishReason,usage,model,durationMs}`: usage dictionary of known validated prompt_tokens, completion_tokens, total_tokens, prompt_cache_hit_tokens, prompt_cache_miss_tokens and optional reasoning_tokens from completion_tokens_details (flattened in SSE); null if missing or partial. Model validated returned provider ID or null (not guessed), durationMs monotonic elapsed starting actual request launch, not approval time, or null if unavailable. Not exact time-to-first-token. Reasoning tokens subset of completion tokens, do not add again. No reasoning text returned by typed API. Native nonstreaming legacy transport still returns existing raw provider body to callers as before; no expansion in response access. No retries added.
- `await GoldAPI.ai.balance()`: gold.ai + network.fetch + gold.ai.balance; explicit interactive run with managed key, exact GET https://api.deepseek.com/user/balance, no args/body, no arbitrary route via GGAPI.network.fetch. Native confirmation mandatory even if existing chat confirmation bypass enabled, key/context recheck; 15s default/30s max, existing 3 requests/run shared quota. Validate <=16KiB parsed balance, boolean is_available, one/two unique CNY/USD records, decimal strings (bounded digits, signed), drop extra fields. Return {is_available,balance_infos:[{currency,total_balance,granted_balance,topped_up_balance}],updatedAt} with timestamp seconds. Account-wide balance for credential, not per-plugin usage. No cache or background refresh, no payment. HTTP error rejects, no guessed values. Official https://api-docs.deepseek.com/api/get-user-balance/ and https://api-docs.deepseek.com/api/create-chat-completion/ verified 2026-11-28.
- `await GoldAPI.ai.usage()`: gold.ai + network.fetch + gold.ai.usage; explicit interactive local read, no provider request/key required to read own retained metadata. Returns {scope:"localPluginRetainedRequests",capacity:128,requests,requestsWithUsage,totals,outcomes,records,cost:null}. Records chronological {timestamp seconds,durationMs,outcome completed/failed/cancelled/partial,usage:{known token fields},model?,httpStatus?}. Only actual launched chat-completion calls through GoldgramPluginNetwork (legacy network.fetch + typed API, stream/nonstream); models/balance, refused/unsent calls and reserve native AI excluded. Per account + plugin UUID UserDefaults ledger Data Codable max128 rows/128KiB, no raw content, credentials, user/chat identifiers in report. Persists across restart and code update; deletion clears ledger. Not full account billing; old rows evicted, crash/kill in-flight not guaranteed, failed/partial/cancelled/invalid context may lack actual usage/model/status, no zero cost inference; broker success means provider response, not UI/draft or billing proof. No aggregate across plugins, daily/monthly retention or tariffs/budget/clear UI yet; next Usage & Balance phase. `cost:null` intentionally unavailable. Existing streamUsage preference/cache unaffected except optional reasoning/model metadata added. Balance new route only on explicit granted RPC, never generic network endpoint expansion.
