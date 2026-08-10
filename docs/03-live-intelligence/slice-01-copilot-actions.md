# M3 Slice 01 — Copilot Actions and Safety

**Status:** CLOSED 2026-08-11 — all automated checks and three independent verifier lenses clear

## Outcome

A system-audio turn can produce a private suggested answer or user-commitment flag through the real two-tier cascade; the user can request a 90-second catch-up. The feature is Quiet by default, cap-safe, cancellable, non-persistent, and unable to affect capture.

## Build boundary

- `TranscriptTurn` plus non-replaying `turnsStream()` attached before capture.
- M3 settings (AI enabled, sensitivity, preferred name) with compatible decoding and fixed DeepSeek production wiring.
- Spend reservation/settlement/cancellation, one shared per-meeting meter, ephemeral in-memory ledger, explicit request ceilings.
- All `CopilotAction` types, gates, strict classifier, deep generation, catch-up, card state/lifecycle, AI kill switch, and initial provider/cap states.

## Acceptance checks

1. Turn-stream tests prove per-source accumulation, chronological payloads, explicit turn-end emission, reset/finish, no replay, and attachment before the first capture event.
2. Settings tests prove defaults, legacy-row decoding, editable preferred name, exact thresholds, global AI-off, model controls absent, and historical overrides preserved but ignored by production wiring.
3. Gate tests cover source, trivial/short questions, name matching, mic overlap, cooldown, active-card drop, paused capture, sensitivity-off, AI-off, no provider, cap, and mic-only on-demand policy with injected clocks.
4. Classifier fake-server tests pin the last-ten-turn prompt, strict schema, action/confidence/target validation, DeepSeek JSON-object quirk, non-thinking fast model, and the impossibility of proactive `catchUp`.
5. Streaming tests prove deep-model output ceilings, answer ≤ 60 words, concrete user-only commitment wording, hidden reasoning, first-token delivery, natural-stop success, and incomplete-output clearing.
6. Card/view-model tests prove one active proactive card, silent overlap drop, 45-second cooldown, 25-second expiry, hover/focus pause, persistent requested catch-up, dismissal, and user preemption.
7. Global AI-off cancels work and clears AI state; cap/provider states are quiet; cancellation is not logged or shown as provider failure; capture/transcript state is unchanged.
8. Spend tests mutation-prove concurrent reservations, release/settlement, booking despite consumer cancellation, cap raise, one shared meter, and no ephemeral disk bytes/rows.
9. End-to-end fake pipeline proves the turn consumer attaches before capture, emits the expected panel state, records classifier/generation ledger purposes, and tears down before post-meeting work.
10. Focused target suites, full `swift test`, and `xcodebuild` pass; three fresh verifiers clear concurrency/lifecycle, privacy/spend, and UI/accessibility lenses.

## Closure evidence

- Integration SHA: `92fd0d89d2ba6fb1fd84a3eedca75e7e0b9a3abd` on `codex/m3-live-intelligence`.
- Full Swift matrix: 431 tests across 73 suites passed, including the credentialed DeepSeek flow and real diarization end-to-end fixture.
- Xcode: `xcodebuild -project macapy.xcodeproj -scheme macapy build` succeeded.
- Lifecycle/concurrency verifier: clean; 124 focused tests across 7 suites passed.
- Privacy/zero-network/spend verifier: clean; 154 focused tests across 15 suites passed.
- Panel/keyboard/accessibility verifier: clean; 71 focused tests across 5 suites passed and Carbon registered `⌥⌘C`, `⌥⌘K`, and `⌥⌘D` successfully.
- Integration worktree was clean and `git diff --check` passed after merge.

## Deferred manual evidence

- The final app-complete walk still owns rendered VoiceOver traversal and real key dispatch in the nonactivating panel. Static accessibility contracts, model behavior, and Carbon registration are automated and green.
- Thread Sanitizer and live-provider/real-database fault injection were not part of this slice's deterministic verification matrix.
- Conservative uncertain spend is deliberately retained in memory for retry safety; surviving a full process restart was not a locked M3 requirement.
