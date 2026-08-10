# M3 Slice 02 — Rolling Context and Ask

**Status:** PENDING — acceptance checks approved 2026-08-10 before implementation

## Outcome

The panel maintains a glanceable meeting summary, catch-up is grounded in the last 90 transcript-seconds, and Ask streams one independent meeting-only answer. Context stays bounded and caching-aware for meetings of any length.

## Build boundary

- Structured rolling summary with two-minute/six-turn cadence.
- Stable-prefix context assembler: 60,000-character hard ceiling, compaction at 42,000, latest ten turns verbatim.
- Catch-up grounding, one-shot query, prompt-injection defense, call arbitration, panel summary/query controls, keyboard/menu shortcuts, and requested-card persistence.

## Acceptance checks

1. Property tests prove compaction never mutates the stable prefix, assembled requests never exceed 60,000 characters, and the latest ten turns remain byte-identical and ordered.
2. Cadence tests prove no summary before two transcript-minutes, no refresh without six new turns, deterministic two-minute refreshes, and silence/pause do not advance transcript time.
3. Summary fixtures require decisions, owners, deadlines, commitments, and unresolved questions without invented facts; only successful summaries replace the visible strip.
4. Failed compaction retains the last successful summary plus the newest turns that fit; a three-hour synthetic meeting never hard-fails or grows context without bound.
5. Catch-up is disabled before 60 seconds, includes exactly the last 90 transcript-seconds afterward, streams within its output ceiling, and stays until dismissed/replaced.
6. Query tests prove strict current-meeting grounding, no prior-query memory, ≤ 150 words, safe treatment of transcript/query instructions, and no persistence.
7. Arbitration tests prove query/catch-up cancel proactive or summary work, proactive cancels summary work, cancelled work releases spend reservation, and only the winning result reaches the panel.
8. Panel/menu tests prove footer actions, `⌥⌘C`, `⌥⌘K`, focus/Return/Escape, summary strip, streaming volatile treatment, replacement/dismissal, VoiceOver labels, and full keyboard operation.
9. Fake-server integration covers malformed summaries, disconnect, 429/5xx, non-`stop` query completion, cancellation, recovery, reasoning suppression, and correct ledger purposes.
10. Focused suites, full `swift test`, and `xcodebuild` pass; fresh context/budget, streaming/arbitration, and UX/accessibility verifiers report no material findings.
