# Goldgram Plugins 1.0 — #267 candidate

Open Goldgram → Плагины. Install the bundled test plugin or paste/import a trusted UTF-8 .js file (max 512 KiB). Imported plugins start disabled. Open plugin, approve supported permissions, then Run/refresh settings. No automatic startup execution; safe mode blocks runs. Edit code and reapprove, or roll back one code version. Settings stay local per account. Do not paste credentials or API keys into general plugin settings.

Supported declared permissions: settings.read, events, ui.read (local output), storage, console. Required unsupported grants block enabling. Settings addSection/define, getPlugin/setPlugin; toggle, text, textarea, select, slider/stepper (numeric input), button. Events: plugin.start, settings.changed, settings.action. Local storage get/set/getJSON/setJSON/remove. GGAPI.log/console and toast/alert local output. Runtime apiVersion 1, features localOnly. Full Ghostgram API, chat hooks, networking, timers, Keychain, AI not implemented. Only run trusted code; sandbox not security-audited.

See examples/hello_world.js. Test import, edit, settings persistence and callback, safe mode, rollback. Full iOS validation pending.
