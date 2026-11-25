# GGAPI compatibility — #269 candidate

Supported manifest grants: ui.read, ui.mutate, chat.read, chat.write, messages.read, storage, events, network.fetch, settings.read; optional clipboard and console. Scoped subset, not full v5.1. proxy optional is not granted. Native broker only allows fixed DeepSeek HTTPS chat completions endpoint and explicit approval; JS receives opaque compatibility alias rather than Keychain key. Chat current/draft and visible/current/get/getSelectedMessage are scoped to authorized current chat and supplied snapshot, not arbitrary history. UI add/removeFloatingButton, add/removeMessageContextAction, select, showSheet and local toast/alert supported; setTyping never sends typing, header status represented by local busy button, legacy menu removal has no persistent menu to remove. Settings addSection, define, get/setPlugin and events, isolated storage, JSON pick/share, clipboard proposal supported. No arbitrary network, full history, proxy, rich text/spoiler entities, MTProto hooks, low-level APIs or background processing. No guarantee of other Ghostgram plugin compatibility. Original 2.1.8 JS mock tests verified 57 settings and seven context actions; device tests pending.


## #270 confirmation preferences (candidate)
Engine management UI only: per-plugin/account switches for repeated DeepSeek requests on user-invoked chat actions and draft preview. Defaults confirm; explicit opt-out; reset on code changes or re-enable. Settings actions still confirm network; no automatic send, arbitrary URLs, clipboard/file bypass or JS permission mutation. Full iOS/device validation pending.


## #271 multi-plugin candidate

All enabled eligible plugins can register their individual floating control and context actions. Composite native identity does not change plugin-local IDs. Per-plugin state, independent execution, hide button without removing context actions, safe mode and cancellation. Max four simultaneous workers, one per account/plugin; shared draft guards and modal confirmation constraints. GGAPI method set otherwise unchanged. CI/device tests pending.

## #272 provider catalog API (candidate)

Requires `network.fetch`. Supported exact routes are GET `https://api.deepseek.com/models` (no body) and POST `https://api.deepseek.com/chat/completions` (existing scoped schema). No arbitrary URLs, redirects or custom authorization. The worker receives only a managed alias, never the native key.

- `GGAPI.network.models()`: copy of cached `{models, updatedAt, stale}`, updatedAt in UNIX seconds; missing returns empty/stale.
- `await GGAPI.network.refreshModels(force=false)`: return fresh cached list or retrieve through interactive broker. Force true explicitly refreshes. Rejection leaves cached snapshot unchanged. Call on user-invoked settings/floating/context action; not automatically on plugin.start.
- `GGAPI.network.fetch("https://api.deepseek.com/models",{method:"GET"})`: request, response object with status/ok/text/json; sanitized list. No request body, no messages.
- Plugin-owned select item may include `modelSource:"deepseek"`; still use a plugin-owned key/default/options and read the setting normally. Picker shows actual cached models or declared fallback and allows explicit manual ID; selection invokes existing settings.changed callback. Do not hardcode normalized model IDs if dynamic choice desired.
- Native catalog available for any enabled plugin with network.fetch. Opens stale catalog refresh (24h), no background poll. Legacy AICC select is unchanged. [Example](examples/model_catalog.js). Full iOS and live provider validation pending.
