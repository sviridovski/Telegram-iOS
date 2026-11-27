# GoldAPI 1.0.0 — developer reference (#281 candidate)

Status: implemented candidate, CI and device testing pending. Injected as the GoldAPI argument alongside unchanged GGAPI/GG in each disposable plugin execution. Methods not documented here are not implemented. Underlying GGAPI access does not require the new GoldAPI grants. No auto-send, raw SQLite, arbitrary file paths, or Telegram session access.

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
