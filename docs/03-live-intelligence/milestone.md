# Milestone 03 — Live Intelligence

**Status:** ACTIVE 2026-08-10 (plan and automated acceptance model approved before implementation)
**References:** ../../PRD.md FR-004–FR-007, FR-015; ../../SPEC.md §6.4, G2, G5, G6

## Goal

During a meeting, macapy quietly recognizes a direct question or an explicit commitment assigned to the user and presents a private, meeting-grounded assist fast enough to use in the conversation. The user can also glance at a rolling summary, catch up on the last 90 seconds, or ask one meeting-scoped question without capture ever depending on AI.

## Scope

- DeepSeek-only two-tier cascade: local gates → strict-JSON fast classifier → deep streaming generation.
- Proactive suggested answers and user-commitment flags; on-demand catch-up and one-shot meeting query.
- Rolling summary plus append-only, caching-aware context with a 60,000-character ceiling and compaction at 42,000 characters.
- AI kill switch, Quiet/Balanced/Active sensitivity, editable preferred name, one-card arbitration, spend reservations, graceful provider recovery, and ephemeral cap enforcement.
- G2 diagnostics, inherited G3/STT/fed-clock diagnostics debts, fixed English quality corpus, one-hour cost proof, and three-hour context proof.

## Non-goals

- No memory, RAG, attached-document grounding, pre-meeting briefs, or cross-meeting context (M4).
- No external actions, conversational query threads, persistent live-AI content, additional wired providers/models, or proactive mic-only assistance.
- No UI redesign: build to `design/03-panel-copilot.html` and the existing Quiet instrument system.

## Locked behavior

- Sensitivity thresholds: off 1.0, Quiet 0.90 (default), Balanced 0.80, Active 0.70; fixed 45-second proactive cooldown.
- AI defaults on. Turning it off cancels calls and clears AI content while capture/history continue.
- Preferred name defaults from macOS, remains editable, and is snapshotted at meeting start.
- Proactive work consumes only system-audio turns. Mic-only meetings retain summary, catch-up, and query.
- `suggestAnswer` and `flagCommitment` are proactive; `catchUp` is user-triggered only. One proactive card is active at a time; overlapping triggers drop.
- Proactive cards fade 25 seconds after completion (paused by hover/focus). Requested cards persist until dismissed or replaced.
- User request > proactive moment > rolling-summary refresh. Catch up is enabled after one transcript-minute and uses the last 90 transcript-seconds.
- Rolling summary begins at two transcript-minutes and refreshes every two minutes only with at least six new finalized turns.
- Only DeepSeek's verified default fast/deep models are used; model selection/overrides are hidden and ignored by production MVP wiring.
- Only natural `stop` streaming completions succeed. Incomplete output is cleared and never reused.

## Slices

| # | Slice | Record | Status |
|---|---|---|---|
| 1 | Copilot actions and safety | [plan/record](./slice-01-copilot-actions.md) | closed 2026-08-11 |
| 2 | Rolling context and Ask | [plan/record](./slice-02-context-and-query.md) | active |
| 3 | Trust, diagnostics, and close-out | [plan/record](./slice-03-trust-and-closeout.md) | pending |

## Exit criteria

1. Quiet mode on the fixed English corpus produces at most 2 false positives across 100 negatives and recalls at least 15/20 directed questions and 15/20 explicit user commitments; fake-server and temperature-zero live DeepSeek oracles both pass hands-off.
2. Real-pipeline trigger-to-first-token p95 is < 3 seconds, with classifier p95 ≤ 1 second and generation first-token p95 ≤ 1.5 seconds; catch-up first token is < 2 seconds.
3. Proactive actions, card lifecycle, footer/menu controls, user preemption, sensitivity, preferred-name detection, mic-only policy, and global AI-off behavior are deterministic and keyboard/VoiceOver-operable.
4. Rolling summary/catch-up/query remain meeting-grounded; compaction never mutates the stable prompt prefix, requests never exceed 60,000 characters, the latest ten turns remain verbatim, and a three-hour fixture never hard-fails.
5. Concurrent classifier/generation/artifact calls cannot amplify cap overshoot; usage still books on cancellation; ephemeral calls enforce the cap in memory and leave zero disk residue; a one-hour default workload costs ≤ $0.25 estimated.
6. Provider outage, rate limit, authentication failure, cap raise, AI-toggle cancellation, and non-`stop` terminal states degrade quietly while capture/transcription remain unaffected and recover according to policy.
7. Suggestion p95, Artifacts G3, STT errors, and the fed-clock-corrected transcript metrics render in Diagnostics; full `swift test` and `xcodebuild` are clean and independent verifier reports have no material findings.

## Verification model

- Deterministic automated oracles only during development; no real-meeting halves.
- Live model tests are automated and skip-not-fail without credentials elsewhere, but M3 close-out requires the DeepSeek corpus and live latency suites green on the author's machine.
- Pixels remain deferred to the single app-complete walk. Add M3 panel states, footer controls, AI settings, paused indicator, and G2 tile to that list.

## Integration discipline

- Work occurs on `codex/m3-live-intelligence`; `main` stays untouched until separately authorized.
- Each slice uses fresh builder and non-editing verifier agent sets. Parallel builders use scoped worktrees/branches; root integrates in dependency order and owns the full verification result.
- Slices are sequential. The next slice starts only from the verified integration head of the previous slice.
