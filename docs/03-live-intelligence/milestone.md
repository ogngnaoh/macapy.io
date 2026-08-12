# Milestone 03 — Live Intelligence

**Status:** CLOSED 2026-08-12 — all seven exit criteria and final independent audits passed
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
| 2 | Rolling context and Ask | [plan/record](./slice-02-context-and-query.md) | closed 2026-08-11 |
| 3 | Trust, diagnostics, and close-out | [plan/record](./slice-03-trust-and-closeout.md) | closed 2026-08-12 |

## Exit criteria

1. Quiet mode on the fixed English corpus produces at most 2 false positives across 100 negatives and recalls at least 15/20 directed questions and 15/20 explicit user commitments; fake-server and temperature-zero live DeepSeek oracles both pass hands-off.
2. Real-pipeline trigger-to-first-token p95 is < 3 seconds, with classifier p95 ≤ 1 second and generation first-token p95 ≤ 1.5 seconds; catch-up first token is < 2 seconds.
3. Proactive actions, card lifecycle, footer/menu controls, user preemption, sensitivity, preferred-name detection, mic-only policy, and global AI-off behavior are deterministic and keyboard/VoiceOver-operable.
4. Rolling summary/catch-up/query remain meeting-grounded; compaction never mutates the stable prompt prefix, requests never exceed 60,000 characters, the latest ten turns remain verbatim, and a three-hour fixture never hard-fails.
5. Concurrent classifier/generation/artifact calls cannot amplify cap overshoot; usage still books on cancellation; ephemeral calls enforce the cap in memory and leave zero disk residue; a one-hour default workload costs ≤ $0.25 estimated.
6. Provider outage, rate limit, authentication failure, cap raise, AI-toggle cancellation, and non-`stop` terminal states degrade quietly while capture/transcription remain unaffected and recover according to policy.
7. Suggestion p95, Artifacts G3, STT errors, and the fed-clock-corrected transcript metrics render in Diagnostics; full `swift test` and `xcodebuild` are clean and independent verifier reports have no material findings.

## Exit verdicts

| # | Verdict | Closure evidence |
|---|---|---|
| 1 | PASS | Frozen temperature-zero DeepSeek holdout: 1/100 false positives, 20/20 directed-question recall, 19/20 commitment recall, zero retries. Fake oracle: 0/100, 20/20, 20/20. |
| 2 | PASS | Final AppShell G2 p95 1,953.036 ms (max 2,095.517 ms). Independent stage authority: classifier p95 987.115 ms, generation first-token p95 978.820 ms, stage G2 p95 1,909.863 ms, catch-up 878.221 ms. |
| 3 | PASS | Proactive actions, requested work, preemption, expiry/interaction, sensitivity/name/mic-only/AI-off behavior, shortcuts, focus, labels, and keyboard contracts are test-pinned. Static accessibility and Carbon registration are green. |
| 4 | PASS | Stable prefix, meeting-only grounding, deterministic compaction, 60,000-character ceiling, latest-ten retention, summary cadence, and 90-second catch-up are pinned. Three-hour fixture: 600 turns, 585 checks, max 43,171 characters, zero hard failures. |
| 5 | PASS | Concurrent reservations, cancellation booking, shared live/artifact meter, cap raise, and ephemeral zero-disk behavior passed. One-hour workload: 170 calls and `$0.17462964`. |
| 6 | PASS | Disconnect, 429/5xx, 401/403, malformed/non-`stop`, cap, AI-off, stale wake, provider replacement, pause/resume, teardown, and capture-independence paths passed. Backoff is 30/60/120/240/300 seconds, capped at five minutes. |
| 7 | PASS | Suggestion p95, G3, STT error, drop, memory, and fed-clock diagnostics are wired. Final credential-free matrix: 526 tests across 87 suites; Xcode Debug build passed; final architecture, reliability/privacy/spend, evidence, criteria, and release audits are clear. |

## Closure evidence

- Verified production source SHA: `04e4870a2391758519cbcd0a15dd95efad620276` on `codex/m3-live-intelligence`.
- Frozen holdout fixture SHA-256: `eb91d91c3989e919f2c988a8093d5f858afce2760a32532fb8c32a526d530a84`. It was frozen in `e413b24` before its oracle was added in `2247bd2`; no production prompt, fixture, manifest, or oracle changed afterward.
- Live holdout command exited zero and ran exactly `realDeepSeekFrozenHoldoutMeetsQuietGuarantee`: 140 rows, 14 local mic rejections, 126 network calls, 1/100 false positives, 20/20 question recall, 19/20 commitment recall, zero retries, estimated cost `$0.01926288`. Retained log SHA-256: `a2c9b10b8285146af85394a0882cd2e9e592ce27753ce57dcafae1092a4045ef`.
- Live AppShell command exited zero and ran exactly `triggerToFirstVisibleTokenP95IsUnderThreeSeconds`: 20 samples, 40 calls, p95 1,953.035667 ms, max 2,095.517459 ms, estimated cost `$0.0188916`. Retained log SHA-256: `6d161d0995a0895dafd13339cfcec071f101e44dc327f89bb5daed506f22af1e`.
- Combined final live-evidence estimate: `$0.03815448`. Logs contained no API key, authorization header, private transcript, raw prompt, or real-meeting content.
- M3 was merged to `main` through [PR #2](https://github.com/ogngnaoh/macapy.io/pull/2) on 2026-08-12. Merge commit: `95f1490626fbe3efb46d9df9e5d26bda8739b382`. No app deployment or release was performed.

## Verification model

- Deterministic automated oracles only during development; no real-meeting halves.
- Live model tests are automated and skip-not-fail without credentials elsewhere. The frozen DeepSeek holdout and final AppShell G2 suite passed on the author's machine for close-out.
- The user accepted the automated accessibility, focus, layout, shortcut-registration, and native-build evidence for M3; no separate manual app walk is required for milestone closure.

## Integration discipline

- Work was integrated on `codex/m3-live-intelligence` and merged only after explicit authorization and PR review.
- Each slice uses fresh builder and non-editing verifier agent sets. Parallel builders use scoped worktrees/branches; root integrates in dependency order and owns the full verification result.
- Slices are sequential. The next slice starts only from the verified integration head of the previous slice.
