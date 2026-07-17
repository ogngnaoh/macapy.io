# Handoff — Milestone 01 (Spine)

## Start here next session

All five slices are **shipped**. What remains is the **milestone close-out pass** (exit criteria walk with the user, then the final ship ritual): (1) real-meeting dogfood — a genuine call end-to-end: dual-source live transcript, persisted, reopened from history (criteria 2, deferred from slice 3); (2) zero-network full-meeting run — `lsof -i -a -p $(pgrep -x macapy)` empty throughout (criterion 4; model already installed so no download traffic); (3) cold start < 2s (criterion 5 remainder — launch to menu-bar-ready; pause hotkey and ephemeral already proven in slice 4, headphones in slice 3, G1 in slice 5). Then: milestones.md → 01 shipped / 02-understanding active, rewrite this handoff for M2, record SPEC amendment candidates in one place, consider archiving the session's backlog lines into the M2 planning input.

## Current state

- **Exit criterion 1 PROVEN and recorded**: release harness p95 **85.36ms** speech-to-visible (p50 32.97ms, 775 volatiles, 0 excluded) — ~11.7× inside the G1 budget. Full JSON in slice-05 doc + milestone Integration notes.
- 74/74 tests green (14 suites), 0 flakes across every run this milestone; xcodebuild clean incl. wiped DerivedData. Sole dependency GRDB 7.11.1.
- The G1 number survived a real gauntlet: harness pacing bug (yield-before-sleep) produced impossible negative latencies that the first version would have recorded as "proof" — caught by verifier raw-sample dump, root-caused (SpeechAnalyzer timestamps are honest), fixed, re-verified, and the reporting layer now excludes-and-counts impossible samples visibly.
- App feature state: dual-stream You/Them live transcript, GRDB persistence + history window, ephemeral mode, ⌥⌘M/⌥⌘P hotkeys, Settings diagnostics section with live latency percentiles.
- Commands: `swift test`; `xcodebuild -project macapy.xcodeproj -scheme macapy build`; release harness: `swift run -c release macapy-latency Tests/TranscribeKitTests/Fixtures/long-meeting.wav`.

## Open concerns

- Close-out items above are the last unproven claims (real-meeting robustness, zero-network full pass, cold start).
- Clean-machine model-download path never exercised (model preinstalled here) — matters for M5 clone-and-run, not for close-out.
- Backlog carried into M2 planning: mid-capture format listener (unreproduced), TCC-denial-silent onboarding UX (M5), unbounded-stream memory watch under analyzer stall (G4), in-app diagnostics has no fed-clock to clamp against (if live negatives ever appear), SPEC amendments (query-format not 16k; STTEngine prepare/preferredInputFormat; String+TimeInterval events; @MainActor store; camelCase columns; os.Logger not swift-log; unsandboxed).
