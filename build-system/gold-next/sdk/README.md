# Goldgram SDK 1.1.0

Target: GGAPI 5 (limited implementation), GoldAPI 1.4.0 candidate, previous runtime #292.

- starter.js: local settings and persistent counter; no chat or network permission.
- search.js: current snapshot, optional confirmed current-dialog history; no global search.
- documents.js: explicitly selected local file, count only; no network.
- ai.js: manually provided synthetic text, separate DeepSeek key managed in Keychain; explicit button; no chat permission or sending.
- contract.json: machine-readable GoldAPI service permission/scope catalog and host permission list. Runtime availability depends on granted permissions and execution context.

Import individual .js through Goldgram > Plugins > Import .js. Enable with reviewed permissions. Use synthetic data. The AI example makes a real, potentially billable provider request only when manually invoked with a configured key; model availability varies. No automatic send or hidden data transfer. Keep secrets out of JS and ordinary settings. Developer reference: goldgram-project-docs branch, docs/goldgram/SDK_DEVELOPER_GUIDE.md.

The existing test_plugin_engine.py reads these files and checks actual worker behavior with mock RPC. Never treat a mock as a real iOS or provider test. SDK evolves with the engine; update contract and tests when APIs change.

GoldAPI 1.4 adds thinking/reasoningEffort/timeoutMs options, sanitized usage and duration, explicit balance and local usage report. Existing examples retain minimum 1.3.0. No cost calculation yet.
