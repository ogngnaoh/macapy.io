# M3 Slice 03 — Trust, Diagnostics, and Close-out

**Status:** ACTIVE 2026-08-11 — starting from verified Slice 2 source SHA `9275b39`

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
