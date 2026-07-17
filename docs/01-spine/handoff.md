# Handoff — Milestone 01 (Spine)

## Start here next session

All five slices are **shipped**; only the **close-out pass** stands between here and marking milestone 01 shipped. Walk the three remaining exit-criteria items with the user: (1) cold start < 2s (launch to menu-bar-ready, ~10s to check); (2) real-meeting dogfood — a genuine call end-to-end, dual-source transcript live, persisted, reopened from History (criterion 2, deferred from slice 3); (3) zero-network during that full meeting (`lsof -i -a -p $(pgrep -x macapy)` empty; model already installed, so no download traffic expected). On pass: final ritual — `docs/milestones.md` 01 → shipped / 02-understanding → active, rewrite this handoff for M2, and fold the SPEC amendment candidates + backlog (listed below and in milestone Integration notes) into the M2 planning session's input. M2 then starts with its own milestone doc (`docs/02-understanding/`) per the doc conventions.

## Current state

- Slices 1–5 all shipped 2026-07-16/17 (slice table + per-slice plan/record docs in this folder are the full trail).
- **Exit criterion 1 proven and recorded**: release harness p95 **85.36ms** speech-to-visible (p50 32.97ms, 775 volatiles, 0 excluded, passG1 true) — JSON verbatim in slice-05 Notes and milestone Integration notes. Criteria 3 (headphones) and 5's pause/ephemeral parts proven in slices 3–4.
- App: dual-stream You/Them live transcript (volatile italic-secondary → final solid), GRDB persistence + history window, ephemeral mode, ⌥⌘M start/stop + ⌥⌘P pause, Settings diagnostics with live latency percentiles. 74/74 tests, 14 suites, zero flakes all milestone; xcodebuild clean; sole dep GRDB 7.11.1; unsandboxed (decision confirmed hands-on).
- Execution model that worked (reuse for M2): per slice — builder subagent (TDD, model tiered to difficulty) → critic pass on risky slices → fresh-context verifier re-running checks with evidence → user-walked live checks → ship ritual; handoff/docs updated at every role boundary. 5 real defects caught pre-ship by non-authors (store-reset race, Carbon hotkey handler, deterministic tail-final data loss, volatile-contrast miss, false G1 proof from a harness pacing bug).
- Commands: `swift test`; `xcodebuild -project macapy.xcodeproj -scheme macapy build`; harness: `swift run -c release macapy-latency Tests/TranscribeKitTests/Fixtures/long-meeting.wav`.

## Open concerns

- The three close-out items above are the only unproven exit-criteria claims.
- Clean-machine model-download path never exercised (matters for M5 clone-and-run).
- Backlog for M2 planning: mid-capture format listener (unreproduced); TCC-denial-silent onboarding UX (M5); unbounded-stream memory watch under analyzer stall (G4); in-app diagnostics lacks a fed-clock to clamp against; SPEC amendments (query audio format, STTEngine prepare/preferredInputFormat, String+TimeInterval events, @MainActor TranscriptStore, camelCase columns, os.Logger, unsandboxed).
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC still stand (locale, calendar sources, dual-meeting audio, SQLCipher) — some become live in M2 (provider layer).
