# GoldAPI 1.0.0 — developer reference (#281 tested checkpoint)

Status: #281 CI green; user confirms nine device checklist items, including runtime discovery, local documents, restart persistence, chat button, selected news text analysis and existing AI Commander. New GoldAPI.ai real provider request and other unlisted checks remain unconfirmed. Injected as the GoldAPI argument alongside unchanged GGAPI/GG in each disposable plugin execution. Methods not documented here are not implemented. Underlying GGAPI access does not require the new GoldAPI grants. No auto-send, raw SQLite, arbitrary file paths, or Telegram session access.

## Runtime

- `GoldAPI.runtime.apiVersion() -> "1.0.0"`
- `GoldAPI.runtime.has(name) -> boolean`: implemented, granted and locally available in current execution, not a guarantee of provider/UI success.
- `GoldAPI.runtime.capabilities() -> [{name,scope,permissions,granted,available}]`: nine implemented service methods; unknown names return false from has. No extra permission.

## AI (gold.ai + network.fetch)

- `await GoldAPI.ai.complete({model,prompt,text,maxTokens?,temperature?},onProgress?) -> {text,partial,finishReason}`. Explicit model ID, prompt and text; no automatic chat inclusion. Prompt <=16000 UTF-8 bytes, text <=28000, total serialized body <=48000; maxTokens 1..2048 (default 900), temperature 0..2. Requires plugin credential and explicit action; existing native broker checks endpoint, request, confirmation, quotas, streaming settings and cancellation. Only DeepSeek POST /chat/completions. No direct insertion or send. Streaming callback requires existing per-plugin streaming opt-in. Local cancellation does not guarantee billing stops.
- `GoldAPI.ai.models() -> {models,updatedAt,stale}`: existing local model catalog, unavailable in passive lifecycle callbacks.
- `await GoldAPI.ai.refreshModels(force=false)`: existing cached/refresh model discovery; explicit action and credential required, existing provider consent applies.

## Search (gold.search + chat.read + messages.read)

`GoldAPI.search.messages(query,{limit=16,includeSelected=true}={}) -> {items,matched,scope:"visibleSnapshot",complete:false}`. Literal case-insensitive search over <=36 current ordinary text snapshot rows plus permitted selected text, deduplicated by ID. Returned items {id,text,source} in reverse snapshot order (selected last added then shown first when matched); limit 1..36. Query <=512 bytes, nonempty; unknown options rejected. No server pagination, other chat IDs, archive, hidden/protected content or background access. Explicit action with scoped current peer required.

## Documents (gold.documents; storage also required for files)

- `GoldAPI.documents.analyze(text) -> {characters,bytes,words,lines}`: max 65536 UTF-8 bytes; characters = Unicode code points; words = whitespace-separated tokens, not linguistic word segmentation; line endings CRLF/CR/LF; empty text has zero lines.
- `GoldAPI.documents.saveText(name,text) -> {name}`; `GoldAPI.documents.readText(name) -> string|null`: .txt flat names, existing plugin-specific logical file quota 16 files/64 KiB aggregate including names. Existing native atomic validated merge persists after successful execution. Not arbitrary filesystem or secret storage.
- `await GoldAPI.documents.pickJSON() -> {value}|null`: existing system picker for JSON <=64 KiB.
- `await GoldAPI.documents.shareJSON(name) -> boolean`: existing valid plugin-local JSON file through system share UI; no silent export. Use GGAPI.files.writeJSON to create JSON.

All document methods require explicit action. Delete using existing GGAPI.files.remove.

## Example

```js
// @name GoldAPI example
// @permission.ui.read required
// @permission.ui.mutate required
// @permission.chat.read required
// @permission.messages.read required
// @permission.gold.search required
GGAPI.ui.addFloatingButton({id:"search",title:"Find"},()=>{
  const result=GoldAPI.search.messages("тест",{limit:10});
  GGAPI.ui.showSheet({title:"Search",text:result.items.map(x=>x.text).join("\\n")});
});
```

Native failures and absent methods reject/throw; do not interpret runtime availability as proof that the network or picker is currently usable. Catch expected failures. Existing generic worker error remains for uncaught errors. Future speech, favorites, contacts, rich document parsing and wider search need separate implementation and acceptance.

## Additions in GoldAPI 1.1.0 (#282 tested checkpoint)

Runtime apiVersion() now returns "1.1.0"; capabilities includes three new speech methods (12 service methods total). Prior methods retain signatures. CI green and nine speech device checks accepted (test speech, voice/rate, native Stop, news/draft actions, background stop and existing AI Commander); unlisted edge cases remain pending.

### Speech (gold.speech)

- `await GoldAPI.speech.voices(language="") -> [{id,name,language}]`: system voice list filtered by exact language or prefix (e.g. ru), sorted and capped at 120. Explicit interactive action; no download/installation management.
- `await GoldAPI.speech.speak(text,{language="ru-RU",voiceId="",rate=1}={}) -> {status,started}`: <=1200 code points and <=4800 UTF-8 bytes, nonempty; rate 0.75..1.5 relative to system default, bounded language tag and voice ID, selected voice must match language. Empty voiceId selects system voice. Returns after end/stop/cancel/timeout, not when audio starts. Status ended means synthesizer stopped speaking, not proof that every word was played. One invocation per execution and one global session; max 120 seconds. Visible native Stop control. No automatic access to messages; pass explicit permitted text. No network.fetch required. Does not send or edit messages.
- `await GoldAPI.speech.stop() -> boolean`: stops own active execution only; false if idle. User can also tap native Stop. App background, invalid context or run cancellation stops speech; a destroyed worker may not receive the terminal reply. Not a persistent background audio engine.

Example: a context action with messages.read/ui.mutate and gold.speech grants can await GoldAPI.speech.speak(GGAPI.messages.getSelectedMessage().text,{language:"ru-RU"}). Handle null/empty text, errors and size limit. Basic voice catalog, speech, stop and background cancellation verified by user on iPhone; other audio/context edge cases remain unconfirmed.

## Additions in GoldAPI 1.2.0 (#283 candidate)

Runtime apiVersion() returns "1.2.0"; 18 service methods in capabilities, 21 including runtime. Explicit interactive actions only; native availability flags are not proof of current store or UI health. Previous methods retained. Device validation pending.

### Favorites (gold.favorites + chat.read; messages.read for selected methods)

- `await GoldAPI.favorites.search(query="",limit=16) -> {items,matched,scope:"currentPeer",complete}`: query <=800 UTF-8 bytes; limit 1..30; case-insensitive matching title/folder/note/tags in current peer across its threads. Results contain title, folder, tags, note, date (ms), archive flag, no message bodies. No archive query, cross-peer search or external request.
- `await GoldAPI.favorites.selected() -> object|null`: metadata for the existing reference of the exact eligible selected ordinary non-expiring message, null if not saved.
- `await GoldAPI.favorites.addSelected({folder="",tags=[],note=""}={}) -> "saved"|"alreadySaved"|"cancelled"`: explicit native confirmation; folder <=80 code points/320 bytes, up to 12 tags <=40 code points/160 bytes each, note <=1000 code points/4000 bytes. Native model validation also applies. Existing reference unchanged; newly added reference has archive false. No message body or arbitrary draft/AI response saved. No archive lookup for new bookmark.
- `await GoldAPI.favorites.removeSelected() -> "removed"|"notFound"|"cancelled"`: confirmed exact reference removal, no original or archive deletion. One prompted write per execution, state rechecked before mutation. Both mutations reject on store failure or stale reference. Timed, protected, secret and ephemeral selected messages excluded.

### Contacts (gold.contacts + chat.read; messages.read for selected)

- `await GoldAPI.contacts.current() -> {name,username,card}|null`: current rendered CloudUser only.
- `await GoldAPI.contacts.selected() -> {name,username,card}|null`: actual CloudUser author of selected eligible ordinary non-expiring message only. The card, if present, contains title/alias/note from existing local personal card; otherwise null. Username may be empty. No phone, arbitrary contact IDs, bulk list, contact mutation or inferred anonymous author. Missing context may reject via runtime availability.

Use GoldAPI.runtime.has(method) to check local scope/grants; catch native errors. These are scoped adapters over existing personal references/card metadata, not unrestricted database or profile APIs. No automatic network transfer; any external AI request remains subject to its separate grant and approval policy.

## GoldAPI 1.2.1 patch (#284 candidate)

Runtime returns "1.2.1", 18 service methods unchanged. Narrow exception to #283 selected favorite methods: ordinary private CloudUser plain nonempty text with already authorized long TTL (>=3600s), known unexpired countdown, no media and all existing protection gates. Native expiry checked again before confirmation and save. New reference is archive false, no body copy, no archive lookup. Original may become unavailable after auto-delete; no extension of original lifetime. Author/contact selection is not expanded for timed content. Mandatory native write/remove confirmation retained. Built-in Personal Test 1.1 uses existing GGAPI.ui.select/showSheet for readable list and details. Explicit upgrade via manager row for exact unmodified v1.0 source; retains UUID/settings/storage/grants and resets confirmation preference. No full plugin update engine yet. CI/device pending.

#284 verification: CI green; Personal 1.1 list/count/readable detail confirmed by user video. New private TTL reference write and other unlisted native flows still need device confirmation.

## GoldAPI 1.3.0 (#285 candidate)

runtime.apiVersion() returns "1.3.0"; 20 service methods, 23 including runtime. #284 UI and reported TTL bookmark saving accepted. Existing methods retained. New API and native fixtures pending CI/device verification.

### `await GoldAPI.search.history(query,{limit=8,since?,until?}={})`

Requires gold.search, gold.search.history, chat.read, messages.read. Explicit interactive action in current eligible top-level ordinary cloud dialog, not a thread/topic, no arbitrary peer ID. Nonempty query <=512 UTF-8 bytes; limit integer 1..12, optional since/until positive Unix seconds <=2147483647, since <= until. User must confirm exact Telegram query and disclosure of results to plugin. One search per run; 20s request timeout; up to first 30 native candidates. Returns {items:[{id,text,timestamp}],scope:"currentPeerHistory",complete:false,serverCompleted,truncated}; text capped at 750 characters, literal case-insensitive match among eligible returned ordinary text. Expiring/protected/secret/restricted/ephemeral/spoiler/service content excluded. serverCompleted reflects Telegram response only, not all possible matches; truncated is a bound flag. No pagination/global/archive search. User cancel/native error rejects. Use existing snapshot method for linked discussions. No new mark-read operation.

### `await GoldAPI.documents.pickText()`

Requires gold.documents and gold.documents.import. Native file picker, explicit action, one file per run, returns {name,format,text,bytes,pageCount,truncated} or null for picker cancellation. PDF/DOCX/TXT/JSON, <=8 MiB file, <=48000 UTF-8 text bytes, PDF max first 20 pages (pageCount total, 0 for non-PDF), DOCX main XML <=512 KiB, conventional unencrypted ZIP only, body text not full formatting; UTF-8 TXT/JSON, JSON syntax validated. No OCR, password unlocking, arbitrary path, raw file or silent network upload. Text-empty scans reject; malformed or unsupported files reject. PDFKit internal processing cost not fully bounded by file cap. Text preview in built-in test max 3500 characters. Further AI calls require separately granted existing AI/network controls and consent. Cancellation discards late parsed output; background parse may finish internally. No new file persistence unless plugin explicitly uses existing storage APIs.

## Current SDK 1.0 reference (#292 candidate)

See [SDK_DEVELOPER_GUIDE.md](./SDK_DEVELOPER_GUIDE.md) for current GGAPI surface, manifest, lifecycle, permission and resource contracts, and executable examples. GoldAPI remains 1.3.0 with 20 service methods. #286 search/document core scenarios accepted, #290 update/restart/rollback accepted, #291 diagnostics accepted by general device report. Earlier candidate labels above are historical; unreported edge cases and actual GoldAPI.ai provider calls remain open. SDK adds no runtime methods; authoritative executable contract is [contract.json](https://github.com/sviridovski/Telegram-iOS/blob/6adc8db8e378e2aa9e4216efc9c40c6936c756a2/build-system/gold-next/sdk/contract.json). CI pending. Continue versioned extensions as plugin development requires.

#292 SDK CI success and installation confirmed on 2026-11-28. GoldAPI runtime unchanged; individual device template tests pending. See CURRENT_STATUS.md.

## GoldAPI 1.4.0 — #293 candidate, AI Engine 2.0 foundation

- 22 service methods, 25 incl runtime; GGAPI runtime stays 5. Manifest hostVersion 1.4.0, previous minimum 1.3.0 still compatible. SDK contract 1.1.0, previous templates kept at minimum 1.3.0. Two new native tokens gold.ai.balance and gold.ai.usage. No change to previous grant behavior or chat scope.
- `await GoldAPI.ai.complete({model,prompt,text,maxTokens?,temperature?,thinking?,reasoningEffort?,timeoutMs?},onProgress?)`: existing arguments unchanged, thinking boolean -> {type:enabled/disabled}; reasoningEffort low/high/max only, reject combination thinking false + effort; omitted retains provider defaults. timeoutMs integer 1000..240000, default 75000; original worker deadline remains 300s. Existing maxTokens, body and consent limits unchanged. Native broker still allowlists options and DeepSeek endpoint; native SSE opt-in/Stop policy unchanged. Result additive `{text,partial,finishReason,usage,model,durationMs}`: usage dictionary of known validated prompt_tokens, completion_tokens, total_tokens, prompt_cache_hit_tokens, prompt_cache_miss_tokens and optional reasoning_tokens from completion_tokens_details (flattened in SSE); null if missing or partial. Model validated returned provider ID or null (not guessed), durationMs monotonic elapsed starting actual request launch, not approval time, or null if unavailable. Not exact time-to-first-token. Reasoning tokens subset of completion tokens, do not add again. No reasoning text returned by typed API. Native nonstreaming legacy transport still returns existing raw provider body to callers as before; no expansion in response access. No retries added.
- `await GoldAPI.ai.balance()`: gold.ai + network.fetch + gold.ai.balance; explicit interactive run with managed key, exact GET https://api.deepseek.com/user/balance, no args/body, no arbitrary route via GGAPI.network.fetch. Native confirmation mandatory even if existing chat confirmation bypass enabled, key/context recheck; 15s default/30s max, existing 3 requests/run shared quota. Validate <=16KiB parsed balance, boolean is_available, one/two unique CNY/USD records, decimal strings (bounded digits, signed), drop extra fields. Return {is_available,balance_infos:[{currency,total_balance,granted_balance,topped_up_balance}],updatedAt} with timestamp seconds. Account-wide balance for credential, not per-plugin usage. No cache or background refresh, no payment. HTTP error rejects, no guessed values. Official https://api-docs.deepseek.com/api/get-user-balance/ and https://api-docs.deepseek.com/api/create-chat-completion/ verified 2026-11-28.
- `await GoldAPI.ai.usage()`: gold.ai + network.fetch + gold.ai.usage; explicit interactive local read, no provider request/key required to read own retained metadata. Returns {scope:"localPluginRetainedRequests",capacity:128,requests,requestsWithUsage,totals,outcomes,records,cost:null}. Records chronological {timestamp seconds,durationMs,outcome completed/failed/cancelled/partial,usage:{known token fields},model?,httpStatus?}. Only actual launched chat-completion calls through GoldgramPluginNetwork (legacy network.fetch + typed API, stream/nonstream); models/balance, refused/unsent calls and reserve native AI excluded. Per account + plugin UUID UserDefaults ledger Data Codable max128 rows/128KiB, no raw content, credentials, user/chat identifiers in report. Persists across restart and code update; deletion clears ledger. Not full account billing; old rows evicted, crash/kill in-flight not guaranteed, failed/partial/cancelled/invalid context may lack actual usage/model/status, no zero cost inference; broker success means provider response, not UI/draft or billing proof. No aggregate across plugins, daily/monthly retention or tariffs/budget/clear UI yet; next Usage & Balance phase. `cost:null` intentionally unavailable. Existing streamUsage preference/cache unaffected except optional reasoning/model metadata added. Balance new route only on explicit granted RPC, never generic network endpoint expansion.
