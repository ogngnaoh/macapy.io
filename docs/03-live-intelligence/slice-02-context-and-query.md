# M3 Slice 02 — Rolling Context and Ask

**Status:** CLOSED 2026-08-11 — all automated checks and three independent verifier lenses clear

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
5. Catch-up is disabled before the meeting-relative transcript timestamp reaches 60 seconds, includes exactly the last 90 transcript-seconds afterward, streams within its output ceiling, and stays until dismissed/replaced.
6. Query tests prove strict current-meeting grounding, no prior-query memory, ≤ 150 words, safe treatment of transcript/query instructions, and no persistence.
7. Arbitration tests prove query/catch-up cancel proactive or summary work, proactive cancels summary work, cancelled work releases spend reservation, and only the winning result reaches the panel.
8. Panel/menu tests prove footer actions, `⌥⌘C`, `⌥⌘K`, focus/Return/Escape, summary strip, streaming volatile treatment, replacement/dismissal, VoiceOver labels, and full keyboard operation.
9. Fake-server integration covers malformed summaries, disconnect, 429/5xx, non-`stop` query completion, cancellation, recovery, reasoning suppression, and correct ledger purposes.
10. Focused suites, full `swift test`, and `xcodebuild` pass; fresh context/budget, streaming/arbitration, and UX/accessibility verifiers report no material findings.

## Closure evidence

- Verified source integration SHA: `9275b39e446910f167151ec693edfc7df354a093` on `codex/m3-live-intelligence`.
- Full Swift matrix: 471 tests across 75 suites passed, including credentialed DeepSeek flows and the real diarization end-to-end fixture.
- Xcode: `xcodebuild -project macapy.xcodeproj -scheme macapy build -quiet` succeeded.
- Context/budget verifier: clean after remediation; 36 focused tests across 3 suites passed. All eight public generator overloads enforce the exact 60,000-character request boundary after escaping, before provider access.
- Streaming/arbitration/failure verifier: clean; 78 live-copilot tests across 5 suites, 39 spend/failure tests across 3 suites, and 8 rolling-context tests passed.
- UX/accessibility/design verifier: clean after remediation; 54 focused tests across 3 suites passed and Carbon registered `⌥⌘C`, `⌥⌘K`, and `⌥⌘D` successfully.
- Three-hour context, stable-prefix immutability, latest-ten retention, deterministic compaction, transcript-time cadence, exact 90-second catch-up, independent query grounding, cancellation/preemption, requested-card persistence, and non-persistence are test-pinned.
- Integration worktree was clean and `git diff --check` passed after both remediation merges.

## Findings resolved during verification

- Public `CopilotGenerator` APIs now reject an actual constructed request above 60,000 characters before network access, including expansion caused by JSON quoting and control characters.
- The fixed 340×470 panel now guarantees a 96-point transcript floor and a bounded, scrollable answer surface; 150-word requested answers remain reachable.
- Streaming answer tails use the approved volatile treatment and settle to normal ink; Escape dismisses from the common panel container, including Submit focus.
- Requested cards and the query field now follow `design/03-panel-copilot.html`; the rolling-summary accessibility group announces once.

## Deferred manual evidence

- The final app-complete walk still owns rendered native NSPanel key dispatch and real VoiceOver traversal. Static accessibility contracts, focus ownership, layout bounds, model behavior, native compilation, and Carbon registration are automated and green.
- Slice 3 owns automatic 30/60/120-second transient recovery/backoff, diagnostics, corpus quality, and live latency/cost evidence.
