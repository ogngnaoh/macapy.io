# M3 Slice 03 — Trust, Diagnostics, and Close-out

**Status:** CLOSED 2026-08-12 — all automated, live-provider, and independent close-out gates passed

## Outcome

The live copilot has measured quality, latency, cost, recovery, and production instrumentation sufficient to close M3 without manual development checks.

## Build boundary

- G2 trigger-to-first-token recorder and diagnostics tile; wire Artifacts G3, STT errors, and in-app fed clock.
- Fixed English quality corpus, fake/live classifier oracle, live G2/catch-up fixtures, one-hour cost and three-hour context fixtures.
- Full transient/latched recovery, non-`stop` policy, cancellation races, cap raising, and milestone evidence.

## Acceptance checks

1. The English corpus contains 100 planted negatives, 20 directed questions, and 20 explicit user commitments, including hard negatives (rhetorical/third-party questions, suggestions, other-owner/unowned work, and user speech).
2. Quiet mode produces ≤ 2/100 false positives and recalls ≥ 15/20 in each positive category through both deterministic fake-server and temperature-zero DeepSeek oracles.
3. Real-pipeline automated playback measures G2 p95 < 3 seconds, classifier p95 ≤ 1 second, deep first-token p95 ≤ 1.5 seconds, and catch-up first-token < 2 seconds.
4. A one-hour scripted workload records every call and totals ≤ $0.25 estimated at shipped DeepSeek prices; a three-hour fixture remains within context and memory bounds.
5. Diagnostics renders Suggestion p95, Artifacts G3, STT errors, dropped chunks, memory, and fed-clock-corrected speech metrics; impossible negative latency cannot flatter a percentile.
6. Deterministic failure sequences cover disconnect, 429, 5xx, 401/403, malformed response, 30/60/120-second backoff capped at five minutes, explicit-request bypass, settings recovery, cap raise, and AI-toggle cancellation.
7. Only natural-stop streams become completed content; length/filter/unknown reasons clear partial content, do not enter context, release reservations, and surface a quiet incomplete state.
8. Capture/transcription/history remain unaffected across every AI-disabled, failed, capped, cancelled, mic-only, paused, ephemeral, and teardown path; zero-provider runs issue zero requests.
9. Full test/build matrix is green on the author's machine including live/model-gated suites; logs and on-disk files pass key/transcript leakage canaries.
10. Fresh performance/evidence, reliability/privacy/cost, and whole-architecture verifiers report no material findings; a separate close-out audit confirms all seven milestone criteria with recorded evidence.

## Verified implementation state

- Integration source: `04e4870a2391758519cbcd0a15dd95efad620276` on `codex/m3-live-intelligence`; worktree clean and `git diff --check` clear.
- Full credential-free Swift matrix: 526 tests across 87 suites passed, including real diarization, the independent fake quality oracle, one-hour cost, and three-hour context fixtures.
- Xcode Debug build with signing disabled succeeded.
- Independent architecture/regression verifier: clear. AgentKit owns the per-meeting orchestrator; AppShell is presentation projection. All real DeepSeek tests use the process-wide FIFO gate, Test Connection accepts only one nonempty natural `stop`, and no live-AI persistence path exists.
- Independent reliability/privacy/spend verifier: clear. Targeted fence 2/2, integrated copilot/provider/capture 90/90, reliability/privacy/spend/workload 143/143, adjacent generation/settings/capture 64/64, and explicit-query recovery stress 10/10 passed.
- Recovery is pinned at 30/60/120/240/300 seconds and then capped at five minutes. Failed partial output, overlapping provider replacement, rapid pause/resume, and late old-meeting presentation clears are deterministically fenced.
- Cost proof: 170-call one-hour workload estimates `$0.17462964`. Three-hour proof: 600 turns, 585 bounded request checks, maximum 43,171 characters, latest ten retained, and zero hard failures.
- Diagnostics, fed clock, STT error counting, G3, and text-free Suggestion p95 recording are wired and covered.
- Independent frozen holdout provenance is clear: 140 unique rows with digest `eb91d91c3989e919f2c988a8093d5f858afce2760a32532fb8c32a526d530a84`; fake pipeline scored 0/100 false positives with 20/20 question and 20/20 commitment recall.

## Live closure evidence

- Frozen holdout command exited zero: 1/100 false positives, 20/20 question recall, 19/20 commitment recall, zero retries, 126 network calls, estimated `$0.01926288`. Fixture digest: `eb91d91c3989e919f2c988a8093d5f858afce2760a32532fb8c32a526d530a84`; retained log digest: `a2c9b10b8285146af85394a0882cd2e9e592ce27753ce57dcafae1092a4045ef`.
- Final post-refactor AppShell G2 command exited zero: p95 1,953.035667 ms, max 2,095.517459 ms, 20 samples/40 calls, estimated `$0.0188916`. Retained log digest: `6d161d0995a0895dafd13339cfcec071f101e44dc327f89bb5daed506f22af1e`.
- Independent stage authority remains green: classifier p95 987.115 ms, generation first-token p95 978.820 ms, summed stage G2 p95 1,909.863 ms, and catch-up 878.221 ms.
- Three fresh final auditors independently cleared the seven criteria, evidence integrity, and release boundary. The earlier performance auditor's only two open gates were the frozen live holdout and post-refactor AppShell G2; both are now resolved by the retained passing runs.

## Findings resolved during close-out

- The per-meeting domain orchestrator now lives in AgentKit; AppShell is a thin observable presentation projection.
- Every credentialed DeepSeek suite shares one process-wide FIFO gate, including legacy provider, artifact, and AppShell flows.
- Test Connection now requires exactly one nonempty natural `stop` and discards partial output for all other terminal states.
- Recovery success, partial clearing, provider replacement, AI re-enable projection, rapid pause/resume, teardown, and cross-meeting presentation ownership are revision- and identity-fenced with deterministic race tests.
- The independent quality holdout was frozen before its loader/oracle inspection and is separate from the development corpus used to tune the production prompt.

## Deferred manual evidence

- The final app-complete walk still owns rendered native NSPanel key dispatch and real VoiceOver traversal. Static accessibility contracts, focus ownership, layout bounds, model behavior, native compilation, and Carbon registration are automated and green.
- The measured proactive classification guarantee is English-only; other languages remain best-effort for on-demand features.
