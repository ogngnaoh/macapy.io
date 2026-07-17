# Handoff — Milestone 01 (Spine)

## Start here next session

Slice 2 machine-side is **fully verified — only live checks 6–8 remain** (user at the machine: mic TCC prompt string, grey volatile → solid final while speaking, `lsof -i` zero-network run). Walk them from the slice-02 doc, then do the slice-2 ship ritual (milestone table → shipped, slice 3 → active, rewrite this handoff) and dispatch the slice-3 builder (config-first: sandbox/usage-key/TCC walk before pipeline code — see slice-03 doc). Execution model: per slice, builder subagent (TDD, inherit model for 2–3 / sonnet for 4–5) → critic pass (2–3 only) → independent verifier re-runs machine checks → user-walked live checks → ship ritual. Orchestrator owns docs and commits.

## Current state

- Slice 1 shipped 2026-07-16. Slice docs 2–5 approved 2026-07-16 (e7905ba).
- Slice 2 code: red 884e5c3 → green b064b03 → critic MAJOR (teardown chaining) → fix red 30bd2de → green 1dd43fc. Verifier: checks 1–5 PASS (fresh context, evidence-based, red independently re-executed via `git archive` scratch run); critic finding CLOSED empirically; both red→green test changes audited LEGITIMATE. 23/23 tests, xcodebuild clean, no flakes across 15 runs.
- Probe findings: real SpeechAnalyzer runs under `swift test`, no TCC for file-fed audio; queried format 16kHz Int16 mono; en model was preinstalled → `prepare()` download branch unexercised.
- Builder deviations + all role reports recorded in slice-02 Notes; slice-4-binding constraint recorded in slice-04 Notes (`finalsStream()` no replay — attach before start, re-attach after reset).
- Build: `xcodebuild -project macapy.xcodeproj -scheme macapy build`; tests: `swift test`; Xcode 26 selected.

## Open concerns

- SpeechAnalyzer accuracy on real speech/meetings unproven — live checks + slice-3 dogfood are the proof.
- Clean-machine asset download path unexercised; zero-network check valid here because model is already installed.
- Cross-event timestamp monotonicity untested (verifier caveat) — proposed as an added assertion in slice-3's dual-stream tests (user-reviewable check addition).
- Sleep-based regression test has theoretical flake risk under extreme load (15/15 clean locally).
- Mic TCC re-prompts on ad-hoc-signed rebuilds possible (watch during live checks); slice-3 tap TCC key + unsandboxed decision to confirm hands-on.
