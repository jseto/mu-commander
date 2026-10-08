# Design: Telegram reply persistence with draft previews (upstream pi-telegram)

## Summary

Assistant replies delivered to Telegram were observed **appearing in the chat
and then disappearing a few seconds later**, with no replacement message and
no bridge diagnostic (2026-10-03, profile `mucommander`, chat 8836657563).

Root cause: the bridge streams answers as **ephemeral drafts**
(`sendRichMessageDraft` / `sendMessageDraft`, "temporary 30-second preview"
per the Bot API) and persists them only through a serialized *publication
queue*. On 2026-10-03 at 15:08:58 +07 one publication task never settled; the
queue has no timeout or watchdog, so **every subsequent assistant message
(active-turn finals and local projections) queued behind it forever**, while
draft frames — sent outside the queue — kept appearing and expiring. The user
therefore saw full replies stream in and vanish, and the bridge recorded
**nothing at all** after 15:04:48 until the runtime was reloaded. `/reload` at
16:50:47 reset the queue and assistant persistence resumed.

This folder is the requirements/design side of an upstream fix for
`@llblab/pi-telegram` 0.51.6 (latest as of 2026-10-03). No code in this
repository can fix the bridge; no fix has been applied. Investigation report:
`tmp/pi-sub/reports/research-telegram-vanish.md`.

## Symptom chain

1. A Telegram turn streams its answer as `sendRichMessageDraft` frames. Drafts
   are **not messages**: they exist only while updated and are dropped within
   ~30 s ([Bot API `sendMessageDraft`](https://core.telegram.org/bots/api#sendmessagedraft):
   *"the streamed draft is ephemeral and acts as a temporary 30-second preview
   — once the output is finalized, you must call sendMessage with the complete
   message to persist it"*).
2. At turn end the queue's `deliverActiveTurn` must persist the answer
   (`sendRichMessage`/`sendMessage`). The persistence step sits behind
   `finalizeMarkdownPreview`, which awaits the in-flight draft flush
   (`lib/preview.ts:259-272` — `const inFlight = state?.flushPromise ??
   state?.precedingFlush; await inFlight?.catch(...)`).
3. The delivery path is guarded by many **silent early returns** (session /
   transport inactive, suppressed-as-already-published, empty plan) and the
   whole chain runs inside a serialized publication queue with **no
   publication-wide timeout** — the package documents this explicitly
   (`docs/outbound.md:27`: *"There is no independent hard cap on pending
   publications and no publication-wide timeout … a programmatic
   handler/provider that never settles can hold this instance's output
   indefinitely"*; implementation: `lib/activity.ts:759-800` publication
   runtime).
4. So one never-settling await inside a publication task wedges **all**
   subsequent assistant output. Drafts keep working because preview flushes do
   not go through the publication queue; they are simply never persisted, and
   they expire client-side ~30 s later. That is exactly "appears, then
   disappears".

## Evidence (2026-10-03, all times +07)

### 1. The shared per-chat message-id sequence proves which bot messages never persisted

Telegram message ids are shared by both sides of a private chat, so gaps not
filled by an inbound user message were bot messages. The journaled updates
(`~/.pi/agent/tmp/telegram/inbox.mucommander.json.segments/`) give:

| id | time | side | content |
|---|---|---|---|
| 660 | ~15:04:47 | bot | reply ("child spawned"); last healthy Telegram final, voice diagnostic logged 15:04:48 |
| 661 | 15:07:51 | user | "What are the conclusions of research-home-mu-commander" |
| **662** | 15:10:58 | user | "Your answers vanish again" — **reply to 661 (produced 15:08:57) never took an id** |
| **663** | 15:17:43 | user | `/merge` — **replies produced 15:09:31 and 15:13:59 never took an id** |
| 664 | 15:17:44 | bot | merge menu (command response — persisted during the outage) |
| 665 | 16:49:15 | user | "Hi" |
| **666** | 16:50:21 | user | "Just vanished now" — **reply to 665 never took an id** (live reproduction) |
| 667 | 16:50:47 | user | `/reload` |
| 668 | ~16:50:48 | bot | "🔄 Reloading Pi resources…" (command response) |
| **669** | 16:53:00 | user | "Your last message arrived truncated at 'key repo' and then vanished" — **reply produced 16:51:28 never took an id** |
| 670, 671 | ~16:54-16:55 | bot | assistant replies — **persistence resumed after the reload** |
| 672 | 16:55:48 | user | "Hi" |

No assistant message was persisted for **1 h 42 m** (15:08:58 → 16:50:47),
while command responses (664, 668) still went out.

### 2. The diagnostic fingerprint

Between the 12:27:10 runtime start and the wedge, every Telegram-originated
turn with final text recorded exactly one `delivery / voice-artifacts` event
right after its final send: 13:38:48, 14:27:48, 14:31:03, 14:33:15, 14:41:13,
15:02:50, 15:04:48 (`logs.mucommander.jsonl`). The replies that vanished
(15:08:57, 16:49:2x) are exactly the turns **missing** that event — and no
`final-text`, `preview`, `proactive-push`, `agent-end-background-delivery` or
any other event was recorded for them either. `logs.mucommander.jsonl` mtime
stayed at 15:04:48 while `state.mucommander.json` snapshots kept being written:
`recordRuntimeEvent` was never called again until recovery.

The event is also a false positive (below), so its presence/absence is a
reliable "the final-text stage ran / did not run" marker.

### 3. The `voice-artifacts` failure is spurious

`createTelegramOutboundReplyArtifactSender` throws *"Failed to send voice
reply: every voice synthesis provider failed."* whenever nothing was
delivered — including when the plan contains **no voice artifacts at all**
(`lib/outbound.ts:924`), and `queue.js` calls it unconditionally for every
plan (`lib/queue.ts:2144`). Executing the installed function directly with
`{ markdown: "hello" }` throws that message. So all 27 recorded
"voice synthesis provider failed" events across profiles are false alarms for
plain text replies; `voice.replyMode: "manual"` was never violated. This
answers the "why is voice attempted at all?" anomaly and removes the voice
path from the vanish story (it runs *after* the text is sent and never deletes
anything).

### 4. Recovery by runtime reset

`/reload` (16:50:47) is handled by `pi-telegram-commands` (replies
"🔄 Reloading Pi resources…", then `ctx.reload()`); a reload fires the
bridge's `session_shutdown`/`session_start`, which resets the publication
runtime (`lib/bindings.ts` `publication.reset()`, `assistantOutputRuntime.start()`,
`previewRuntime.invalidate()`). Assistant persistence resumed immediately
(670/671). The 16:51:28 reply that straddled the reload still failed — the
turn's former session context is stale after a reload.

### 5. Chunked send / edit-shrink / delete audit (the "truncated" observation)

The user reported the vanished message had first appeared *truncated*. Reviewed
and ruled out as a delivered-then-deleted permanent message:

- Assistant final sends (`sendTelegramNativeMarkdownReply`,
  `lib/replies.ts`; `sendTelegramRenderedChunks`) send chunks sequentially and
  **never delete or shrink an already-sent chunk**. A mid-sequence failure
  leaves earlier chunks visible and records `final-text`; it produces
  *truncated permanent messages*, not vanishing ones.
- `editView` shrink / `deleteMessage` (`lib/delivery.ts`, editView ~line 602,
  delete ~652/681) belongs to the public Delivery API and only operates on
  handles returned by `sendTelegramView`. The only consumers on this machine
  are the merge menu (`~/.pi/agent/pi-telegram-commands/extensions/index.ts:119`)
  and devserver views (`~/.pi/agent/extensions/devserver.ts:79`); neither
  targets an assistant reply.
- Other `deleteMessage` call sites — menu cleanup (`lib/commands.ts:1586`),
  guest attachment staging (`lib/outbound-attachments.ts:781`),
  workspace/topic deletion (`lib/extension.ts:1975`; Threaded Mode disabled
  here) — cannot remove a classic-mode assistant reply.

The "truncated" appearance is the **last draft frame frozen mid-sentence**:
`onMessageEnd` seals the preview and cancels the trailing flush timer
(`lib/preview.ts:226`, `lib/bindings.ts` `previewRuntime.seal()`), so the last
frame the client shows can stop anywhere (here: the main session's text
"…is its key repro; its theory so far…", which the user quoted as "key repo").
That frozen draft then expired/cleared — a draft, not a deleted message.

## Hypothesis verdicts

- **H1 — preview lifecycle / skipped final send: CONFIRMED.** The persisted
  message is missing for the affected turns; the failure is silent, and the
  draft (which kept streaming) is what vanished.
- **H2 — multi-profile contention: RULED OUT for this incident.** The four
  profiles use four distinct bot tokens; the mucommander instance held the
  lock (`active here`), polling healthy, no leader/follower transitions in the
  window. (Stale session/transport authority remains a *trigger* class for
  silent skips, but not this wedge.)
- **H3 — voice-artifact path deleting/replacing the text: REFUTED.** Covered
  above; the voice path runs after the text send, deletes nothing, and its
  failure events are false positives.
- **H4 — chunk-shrink `deleteMessage` / edit-shrink: RULED OUT** for the
  assistant reply path (audit above). Note: a late draft frame *after* a
  successful persistence could still downgrade a message client-side (REQ-6);
  no such ordering was found in 0.51.6 (`prepareDelivery` seals the state
  before the finalizer runs and awaiting clients see the permanent send last),
  but it is worth a regression test upstream.

## Defects to fix upstream (0.51.6)

1. **Publication queue has no timeout/watchdog** (`lib/activity.ts` reserve/
   tail; documented in `docs/outbound.md:27`). One never-settling task wedges
   all assistant output indefinitely, silently. → Bound each task; on expiry
   record a diagnostic and advance the queue.
2. **Finalizer awaits an unbounded flush promise** (`lib/preview.ts:264-269`).
   → Bound the wait; on timeout clear the preview and send the final text.
3. **Silent delivery skips** — `if (!isDeliveryActive()) return;` and the
   already-published suppression (`dist/lib/queue.js:985/993/…`,
   `lib/bindings.ts:1158`) record nothing. → Record a `delivery` event with
   the reason.
4. **Spurious voice-artifacts throw** (`lib/outbound.ts:924` +
   `lib/queue.ts:2144`). → Return early when the plan has no voice artifacts.
5. **Fallback HTTPS transport has no timeout** (`lib/telegram-api.ts:1219-1258`
   — `requestHttps` with no socket/response timeout). → Add
   `AbortSignal.timeout`/socket timeouts so a black-holed request cannot hang
   a publication forever.

## Proposed upstream fix (order of value)

1. Early return in the artifact sender when `voiceReplies` is empty
   (one-line; removes 27 misleading events/day and restores diagnostic
   signal).
2. Watchdog around the publication task (e.g. 60-90 s): on timeout record the
   phase that was active and resolve the queue so later replies flow.
3. Bounded `await inFlight` in the preview finalizer, with fallback:
   clear the draft, then `sendMarkdownReply` regardless.
4. A runtime event for every silent delivery skip (reason + turn/chat).
5. `AbortSignal.timeout` on `telegramHttpsFetch`.
6. Regression tests for REQ-1…REQ-7 (draft → persist invariant, stall →
   recovery, no-voice → no failure event, late draft → persisted message
   survives).

## Local mitigations (recommended; not applied — investigation only)

- **Reload to recover:** `/reload` from Telegram (or `/telegram-disconnect` +
  `/telegram-connect`) resets the wedged publication queue; observed recovery
  at 16:50:47.
- **Disable draft previews** in `~/.pi/agent/telegram.json`
  (`"assistant": { "draftPreviews": false }`): removes the "appears then
  vanishes" symptom (a lost reply becomes plainly absent). Cost: no streaming
  previews. This does not fix the underlying stall.
- **Upgrade** when an upstream release fixes REQ-1…REQ-7; 0.51.6 is the
  current latest and contains all defects.

## Verification

- Requirements above are the acceptance criteria for the upstream fix.
- REQ-5 is reproducible with one call against the installed package
  (`createTelegramOutboundReplyArtifactSender` with `{markdown:"hello"}`
  throws); the queue/vanishing behavior was verified from the live journals
  (message-id gaps) and the missing diagnostic fingerprint.
- This repository adds no executable code; the suite is unaffected.

## Code audit (independent pass)

- **Overview:** the artifact is documentation plus requirements; no product
  code changed in this repository. The design places the fix behind the
  correct seam — the bridge's publication/delivery layer — and explicitly
  declines to invent a local workaround that would hide the defect
  (`draftPreviews: false` is presented as symptom relief with its cost).
- **Files:** new `specs/telegram-reply-persistence/telegram-reply-persistence.feature`
  and this document; investigated (read-only) `@llblab/pi-telegram` 0.51.6
  `lib/queue.ts`, `lib/preview.ts`, `lib/activity.ts`, `lib/outbound.ts`,
  `lib/replies.ts`, `lib/delivery.ts`, `lib/telegram-api.ts`, plus the
  on-machine Telegram journals/logs/state under `~/.pi/agent/tmp/telegram/`.
- **Problem / Solution / Benefits:** the friction is a delivery pipeline whose
  failure is silent and global (one hung task stops all output while drafts
  keep working). The proposed fix bounds each stage and makes every skip
  observable, so subsequent occurrences localize themselves in the existing
  diagnostics instead of requiring this forensic reconstruction.
- **Less valuable improvements (noted, not done):** a local watcher that
  detects "no persisted reply in N minutes" and auto-reloads the bridge would
  mask the bug and risk session churn; left to the upstream fix.
- **Recommendation strength:** Strong for defects 1-3 (directly evidenced);
  Worth exploring for 5 (plausible trigger, not proven from outside the
  process); Speculative for 6's late-draft ordering (no trace observed).
