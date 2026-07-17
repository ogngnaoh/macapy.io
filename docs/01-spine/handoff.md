# Handoff — Milestone 01 (Spine)

## Start here next session

Slice 2 build is **done and green** (red 884e5c3 → green b064b03; 22 tests, xcodebuild clean; probe: real engine runs under `swift test`, no TCC, model was preinstalled). Critic + verifier dispatched in parallel. If resuming: read slice-02 checklist + Notes (builder deviations recorded there), collect critic findings and verifier verdicts, resolve any defects (re-verify after fixes), then walk live checks 6–8 with the user and do the ship ritual. Execution model: per slice, builder subagent (TDD, inherit model for 2–3 / sonnet for 4–5) → critic pass (2–3 only) → independent verifier re-runs machine checks → user-walked live checks → ship ritual. Orchestrator owns docs and commits.

## Current state

- Slice 1 shipped 2026-07-16. Slices 2–5 docs approved by the user 2026-07-16 (front-loaded review, commit e7905ba); acceptance checks are pre-implementation and user-reviewed.
- Slice 2 code-complete at b064b03: CaptureKit (AudioChunk/protocol/BufferConverter/MicCapture), TranscribeKit (STTEngine/SpeechAnalyzerEngine/TranscriptStore), AppShell MeetingPipeline + coordinator factory injection + panel volatile/final rendering, mic usage string. Builder deviations + probe findings recorded in slice-02 Notes (result.range times; onFailure/markStopped; panel/hotkey injection seams; AVAudioFormat non-Sendable; queried format = 16kHz Int16 mono).
- Builder self-flagged one loosened test assertion (BufferConverter single-chunk frame bound — resampler group delay); needs independent scrutiny, not builder's word.
- Build: `xcodebuild -project macapy.xcodeproj -scheme macapy build`; tests: `swift test`; Xcode 26 selected.

## Open concerns

- SpeechAnalyzer accuracy on real meetings still unproven — live checks 6–8 + slice-3 dogfood are the proof.
- `prepare()` asset-download branch unexercised (model preinstalled here) — clean-machine behavior unknown; zero-network check must run after one-time install.
- Rapid-toggle/teardown concurrency in coordinator+pipeline is the highest-risk area (fake-driven test passes; critic focusing there).
- Mic TCC re-prompts on ad-hoc-signed rebuilds (watch in live checks); process-tap TCC key + unsandboxed decision to confirm hands-on in slice 3.
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand — none block M1.
