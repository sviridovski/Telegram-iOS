# Gold Roadmap

This roadmap belongs to the `gold` branch.

## Rule zero: performance first

Feature work starts only after the performance foundation is mature enough.

Primary targets:
- Reduce foreground and idle energy use.
- Reduce steady-state RAM.
- Maximize warm-resume survival under iOS memory pressure.
- Stress-test repeated ChatGPT ↔ Swiftgram switching.
- Stress-test coexistence with heavy games.
- Avoid unnecessary timers, polling, duplicate refreshes and background assertions.
- Preserve push, calls, message sync, uploads/downloads and TGExtra.
- One atom = one focused change = one commit = one build = one real-device test.

> iOS ultimately decides jetsam/termination. “Survive heavy games” is an optimization target, not a guarantee.

---

## Phase 0 — Performance foundation (must be completed first)

- [x] Atom #1 — task-aware background work.
- [ ] Atom #2 — safe RAM/cache release audit.
- [ ] Atom #3 — coalesce duplicate non-message refreshes.
- [ ] Atom #4 — lazy-load TGExtra and optional subsystems.
- [ ] Atom #5 — media prefetch policy for background / Low Power Mode / thermal pressure.
- [ ] Atom #6 — thermal-state-aware throttling for nonessential work.
- [ ] Atom #7 — optional Battery+ profile.
- [ ] Atom #8 — lightweight event-based diagnostics, no production polling.
- [ ] Atom #9 — CI regression guards for timers/background work/TGExtra packaging.
- [ ] Atom #10 — map Telegram update/difference replay paths after resume.

Acceptance goals:
- Lower heat during app switching.
- Lower RAM after backgrounding without breaking warm resume.
- No production memory polling.
- No artificial keepalive whose only purpose is defeating iOS suspension.
- No regression in messaging, notifications, calls or media transfer.
- Compare each atom with the untouched golden baseline.

---

## Phase 1 — Deleted / edited message history

- Save deleted messages.
- Save own messages deleted “for everyone”.
- Save disappearing messages where available before deletion.
- Archive deleted media.
- Show edited messages inline.
- Separate deletion/edit histories.
- Group by personal chats / groups / channels / comments.
- Support bots.
- Support deleted/edited channel posts.
- Adjustable opacity for deleted/local-edit history.
- Exclusions by chat / group / folder.
- Optional long-press history.
- Retention / cache policy.
- Correct behavior after long suspension by handling Telegram difference/update replay rather than forcing permanent background execution.

---

## Phase 2 — Ghost Mode / privacy

- Master Ghost Mode.
- Do not send read receipts.
- Do not mark stories viewed.
- Do not send online presence.
- Do not send typing / recording / activity indicators.
- Automatic offline behavior.
- Read-on-actions exception.
- Per-chat / group / folder exclusions.
- Fine-grained activity settings.
- Timed stealth session.
- Optional send delay while staying offline.

---

## Phase 3 — Translation and message utilities

- Independent app UI language.
- Translation provider selection.
- Translate chats/messages.
- Translate before sending.
- Outgoing translation language.
- Reply as quote.
- Custom recent reactions.
- Local edit.
- Bookmark in long-press menu.
- Mark all read locally / on server.
- Auto word replacement.
- Optional anti-search text transform.
- Optional novelty text transforms.

---

## Phase 4 — Misc client utilities

- Client-side content-forward/save restriction handling where technically local.
- Optional source attribution when making a copy.
- Local retention controls for ephemeral media where feasible.
- Screenshot behavior controls where client-side.
- Sponsored-message filtering where client-side.
- Avoid Telegram proxy when system VPN is active.
- Bot-content compatibility helpers.
- Send gallery video as video-message where supported.
- Anti-spoiler.
- Poll-results helper where technically possible without faking server state.
- Anti-caps formatter.
- Camera-switch animation controls.
- Do not pause other audio while recording where safe.
- Optional transcription workflow.
- Hide messages from blocked users in public chats/groups.
- Anonymous sticker-send metadata behavior where technically possible.
- Search-history retention controls.
- Hide greeting sticker.
- GIF chat/profile backgrounds.
- “Remove via …” attribution controls.
- Audio equalizer.

---

## Phase 5 — Local-premium-style client features

Only genuinely client-side features.
No attempt to create server-side Premium, Stars, paid reactions, gifts or other server-validated entitlements.

- Client-only visual/UX premium-style features.
- Clear local-only labeling.
- No fake server balances or server entitlement claims.

---

## Phase 6 — Customization

- Custom fonts / import font.
- Exact last-seen display where available.
- Connection/update text controls.
- Telegram transcription mode selection.
- Disable voice autoplay.
- Hide emoji status.
- Disable blur on selection.
- Message-background blur controls.
- Auto blur color, size and intensity.
- GIF chat background.
- Video-message masks.
- Bubble editor / hide bubble tail.
- Auto formatting.
- Typing animation customization.
- Message gradients.
- Custom top bar: username / avatar / pinned.
- Double tap copy.
- Triple tap delete shortcut.
- Delete-for-me / delete-for-everyone shortcuts with safeguards.
- Auto-mute new channels.
- Checkmark color.
- Hide channel comments / view counter.
- Hide message time / edited status.
- Profile-item visibility controls.
- Avatar/story-ring customization.
- Hide/customize search bar.
- Square avatars / round forum avatars.
- Chat-row size.
- Account-switch button in header.
- Bottom bar / folder bar height.
- Global-container search.
- Quick bound buttons.
- AMOLED pure black / AMOLED keyboard.
- Hide cell separators.
- Sender avatar in chat list.
- Optional snow effect.
- Download progress in chat list/folders.
- Hide message preview.
- Tab-bar organizer.
- Input-bar size/position.
- Hide/add settings tabs.
- Optimized Liquid Glass.
- iPhone-style Liquid Glass.
- Glass tint/intensity/corners/blur/shadow/glare.
- Old pre-Liquid-Glass interface mode.

---

## Phase 7 — Icon packs and badges

- Alternate icon packs.
- Import custom icon packs.
- Restart helper after icon changes.
- Custom badge / Dynamic Island style badge.
- Badge editor with image/text/layers/background.
- Import badge from file/link.

---

## Phase 8 — Feed

Disabled by default because it can materially increase CPU/GPU/network/RAM use.

- Optional vertical media feed.
- Sources: recommendations / own chats / chosen channels.
- Video / GIF / video-messages / photos.
- Viewed/unread filters.
- Length filters.
- Shuffle.
- Autoplay / loop / sound defaults.
- Auto-next.
- Gesture controls.
- Privacy controls for viewed/read state where technically supported.
- Local viewing history.
- Strict prefetch/cache budget.

---

## Phase 9 — Security / private workspace

- App passcode.
- Face ID / Touch ID on account switch.
- Password lock for selected chats.
- Sensitive-chat auto-lock.
- Secret biometric folder.
- Call settings.
- Optional local call recording only where lawful and with explicit user controls.
- Optional local microphone inclusion/exclusion in recordings.

---

## Phase 10 — Voice and camera effects

Fully lazy-loaded and off by default.

- Voice changer.
- Anonymous / female / male / child / robot / custom presets.
- Custom voice editor.
- Camera/video-message masks.
- Anonymous combined face+voice mode.
- Mask catalog/cache limits.
- On-device processing where possible.

---

## Phase 11 — Device / location presentation

- Client-side device-model/system-version presentation controls.
- Presets and custom values.
- App-local location override where feasible.
- Optional walking-route simulation for testing.
- Keep isolated from core messaging.

---

## Phase 12 — Export / import / diagnostics

Treat session material as highly sensitive.

- Full-account chat export.
- Telegram Desktop-style HTML/result.json export.
- Export media/files.
- Face ID/passcode before export.
- Settings export/import.
- Separate configs per account.
- RAM display.
- Safe manual/automatic cache cleanup.
- Event-based diagnostics.
- Session import only for the user’s own sessions with strict local handling.
- Never log/upload auth keys or session secrets.

---

## Phase 13 — Plugins / GGAPI-like platform

- Plugin manager.
- Import plugin.
- Create plugin template.
- Plugin settings.
- Local documentation.
- Dev hot reload.
- Minimal capability API.
- Context-menu extension API.
- Selected-message access API.
- Draft insertion API.
- Local storage API.
- HTTP/network API with explicit permission.
- AI CommandCenter integration.
- Lazy-load plugins so disabled plugins consume effectively no runtime resources.

---

## Phase 14 — Low-priority / experimental

- Music status.
- App icon customization.
- Client identity display selector.
- Profile hyperlink presentation controls.
- Watermark on photos.
- Local profile presentation experiments.
- Other cosmetic/novelty features only while the performance baseline stays intact.

---

## Development discipline

For every feature after Phase 0:
1. One narrowly scoped atom.
2. One commit.
3. Behind a setting and default-off unless it is a safe core fix.
4. Event-driven hooks instead of polling whenever possible.
5. Lazy-load optional engines/frameworks.
6. Explicit cache limits/retention.
7. Verify background/foreground lifecycle.
8. CI build.
9. Real-device test.
10. Compare RAM, heat and warm-resume behavior with the previous Gold build.
11. Revert immediately if an atom harms the performance baseline.

**Performance always has priority over feature count.**
