# Goldgram — Deferred Always-On Telegram Monitoring and Secure Sync

**Status:** DEFERRED / IDEA ONLY. **Recorded:** 2026-10-20. **User decision:** keep for the future **only if the iOS-native capture strategy and Ghostgram comparison do not provide sufficient reliability**. No code changes, deployments, credentials, account authorizations, subscriptions, or setup are approved by this document.

## Goal and scope

The user's primary target is **original and edited/deleted comments beneath posts in followed Telegram channels**, including comments from other people while Goldgram/Swiftgram on iOS is suspended. The user currently follows channels and enters comments via each post; the user does *not* necessarily belong to each linked discussion group. Posts themselves, personal chats and other groups can be considered later but are not the priority.

The user has directly observed:
- When Swiftgram is on screen, confirmed originals and subsequent edits are often captured.
- When Swiftgram is minimized, Goldgram often stores only the later edited text and marks the original unavailable.
- Ghostgram reportedly performs better in similar scenarios, but its internal mechanism remains unverified.
- In #101/#102 diagnostic screenshots for affected messages, SQLite had **no confirmed original**, Postbox saw an edited version, and SQL original retrieval missed. These observations do not prove that the initial message was delivered to any Goldgram component in the background.
- Existing attempts #95–102 improved native/notification capture; do not treat green CI alone as a verified original.

## Gate: when to consider this fallback

Do NOT begin server work until (1) #103 or a successor reliably diagnoses extension/notification delivery; (2) targeted linked-discussion observation and safe, bounded updates on iOS have been evaluated; (3) Ghostgram research and direct A/B testing have investigated how it preserves originals, especially while suspended; and (4) the user explicitly elects this approach after reviewing security, cost and operational requirements.

The primary project remains **local-first**. No unrelated replacement of Goldgram or deletion of its archive.

## Proposed architecture, if explicitly approved later

1. **Separate authenticated Telegram observer:** A user-owned, always-running machine (desktop or VPS) hosts a second official Telegram client session for the **same account**, built using an appropriate library such as TDLib or Telethon. The client processes genuinely received updates while online. Never obtain the user's current mobile session file or embed OTP/password/API credentials in source, CI, logs or chat.
2. **Linked discussion monitoring:** Resolve each selected channel's linked discussion group from authoritative Telegram metadata. For *accessible* groups, test authorized MTProto update subscriptions and their renewal/state cursor; confirm whether a non-member can actually receive comments. Public accessibility and updates are not guaranteed for every group; private groups require legitimate membership/permissions. Implement a small opt-in whitelist; no aggressive scraping, flood-wait circumvention or claims of universal access.
3. **On-server durable event history:** Store only messages within approved scopes, with an authenticated Telegram account/session identifier, peer namespace/kind + peer ID + message ID, stable event ID, event type (confirmed first body, observed edit, observed delete), trusted server timestamps where available, arrival time, optional thread/root-post IDs, media identifiers, and provenance. Immutable actual original is recorded only if observed **before it was edited**, never inferred from a later snapshot. Persist events transactionally with replay-resume cursors, deduplication and crash recovery.
4. **Private sync API:** Goldgram pulls incremental events from the user's own HTTPS endpoint when active, using cursor-based synchronization, strict account binding, authentication (rotatable scoped tokens or an equivalent secure pairing scheme), TLS, encryption at rest, and revocable device access. Do not upload the local phone archive by default. Prefer a small authenticated read-only pull design over a permanently connected iPhone socket.
5. **Merge into Goldgram's EXISTING SQLite archive:** Goldgram already has `messages`, `revisions`, and `events`, including source/provenance and associated peer/type/ID fields. Design a **separate validated import adapter**, not a second database. Import must be idempotent and account-scoped; preserve existing revisions, sender metadata and deleted state. A belated verified original may backfill a missing baseline but **must never roll back the newest edited text** or fabricate edits, authors, times or originals. Explicitly distinguish phone-captured vs server-captured original, and retain source audit metadata.
6. **UI:** Proposed opt-in “Облачный мониторинг” settings (server paired/offline/last sync/cursor, enabled channel discussions, errors, source provenance) and **one merged archive** with the same discussion/post navigation and history grouping already built. Do not expose archived content outside the user's authenticated client.

Conceptual data flow:

```text
Telegram updates received by a persistent second session
  -> monitored linked discussion groups (explicit allowlist)
  -> original/edit/delete evidence recorded in a private server store
  -> authenticated cursor-based HTTPS pull when Goldgram opens
  -> validated, idempotent import into existing Goldgram SQLite
  -> one local history view, with explicit capture provenance
```

## Major limitations and safety

- **Cannot reconstruct a genuine pre-edit original that no observer captured.** The service only improves uptime and observation chances.
- Whether the separate account session can monitor comments without group membership must be **empirically tested for each relevant group type**; user only follows channel posts today.
- Telegram privacy/access restrictions, flood limits, server outages, dropped connections and edit races still exist. Avoid promising 100% completeness.
- VPS runs an active Telegram account session and can see content in monitored scopes; theft of host/session/storage is a significant risk. Use OS hardening, restricted service user, encrypted storage, backups/retention limits, MFA where applicable, rotation and explicit account-session revocation instructions. Consider a trusted always-on home computer before VPS.
- No automatic sharing of session files or personal data with third parties. No public API endpoints disclosing message content. Default to least privilege, strict auditability and opt-in deletion/retention.
- Ongoing hosting/maintenance costs and energy costs must be explained before consent.
- No background-jailbreak hacks or forcing iOS to run continuously; the whole point of the proposed observer is independent uptime outside iOS.

## Future proof-of-concept (ONLY after user approval)

- **Phase A:** On a user-owned test machine, authenticate a **separate** Telegram session and monitor **one selected public channel + one accessible linked discussion**. Verify group access and document Telegram update types and renewal behavior; never assume a non-member receives all updates.
- **Phase B:** With consenting test participants or non-sensitive test content, observe an original, edit twice, delete, process reconnect and a forced server restart. Record actual missed events and fidelity; ensure every original is genuinely observed.
- **Phase C:** Define versioned, minimal JSON event schema, authentication model, cursor/resume and import boundaries. Test with synthetic sample events before touching real user archives.
- **Phase D:** Add opt-in Goldgram importer for the existing SQLite schema, explicit source labelling and one-way merge guards; validate safe backfill, duplicate handling, account switches and historical preservation.
- **Phase E:** Only if the real test meets accuracy/security/battery requirements, extend to a small explicit allowlist of discussions and operationalize backups, alerts, consent and deletion.

## Acceptance criteria before production

- Real-world A/B replay (Goldgram-only vs server observer vs Ghostgram where lawful/available), including app foreground, background and offline; do not compare different messages/timings as if equivalent.
- Document measured percentage of genuine originals/edits/deletes captured, latency, correctness of links to discussion/root post, and missed-event causes.
- No insertion of invented originals; no broken or cross-account SQLite merges; no duplicate events after retry/reconnect.
- Explicit consent and safe disable/unpair/revoke/purge procedures, reasonable cost, and demonstrated security.
- No regression in iPhone responsiveness or battery use; sync only on user-approved opportunities.

## Current next action (2026-10-20)

**None on this fallback.** Continue #103 diagnostic investigation for notification-extension traces and further **iOS-side** strategies; investigate Ghostgram. Reopen this file only upon explicit user request that normal approaches are inadequate.

Related project context: [GOLD_CURRENT_HANDOFF.md](GOLD_CURRENT_HANDOFF.md), [GOLDGRAM_HISTORY_SQLITE_PLAN.md](GOLDGRAM_HISTORY_SQLITE_PLAN.md), [GOLD_ROADMAP.md](GOLD_ROADMAP.md).
