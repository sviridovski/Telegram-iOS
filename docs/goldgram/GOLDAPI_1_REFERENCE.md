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

## Additions in GoldAPI 1.1.0 (#282 candidate)

Runtime apiVersion() now returns "1.1.0"; capabilities includes three new speech methods (12 service methods total). Prior methods retain signatures. Device acceptance pending.

### Speech (gold.speech)

- `await GoldAPI.speech.voices(language="") -> [{id,name,language}]`: system voice list filtered by exact language or prefix (e.g. ru), sorted and capped at 120. Explicit interactive action; no download/installation management.
- `await GoldAPI.speech.speak(text,{language="ru-RU",voiceId="",rate=1}={}) -> {status,started}`: <=1200 code points and <=4800 UTF-8 bytes, nonempty; rate 0.75..1.5 relative to system default, bounded language tag and voice ID, selected voice must match language. Empty voiceId selects system voice. Returns after end/stop/cancel/timeout, not when audio starts. Status ended means synthesizer stopped speaking, not proof that every word was played. One invocation per execution and one global session; max 120 seconds. Visible native Stop control. No automatic access to messages; pass explicit permitted text. No network.fetch required. Does not send or edit messages.
- `await GoldAPI.speech.stop() -> boolean`: stops own active execution only; false if idle. User can also tap native Stop. App background, invalid context or run cancellation stops speech; a destroyed worker may not receive the terminal reply. Not a persistent background audio engine.

Example: a context action with messages.read/ui.mutate and gold.speech grants can await GoldAPI.speech.speak(GGAPI.messages.getSelectedMessage().text,{language:"ru-RU"}). Handle null/empty text, errors and size limit. Actual voice catalog, audio behavior and UI require device verification.
