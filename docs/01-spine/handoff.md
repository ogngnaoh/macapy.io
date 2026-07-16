# Handoff — Milestone 01 (Spine)

## Start here next session

Slices 2–5 docs **approved by the user 2026-07-16** (front-loaded review done). Slice 2 is in build: builder subagent dispatched, starting with the de-risk spike (fixture wav → real SpeechAnalyzer under `swift test`, check 1 in slice-02 doc). If resuming: check slice-02 checklist for last completed role, then continue the sequence builder → critic → verifier → user live checks → ship ritual. Execution model: per slice, builder subagent (TDD, inherit model for 2–3 / sonnet for 4–5) → critic pass (2–3 only) → independent verifier re-runs machine checks → user-walked live checks → ship ritual. Orchestrator owns docs and commits.

## Current state

- Slice 1 shipped 2026-07-16, all checks verified (slice-01 doc). Skeleton: menu bar accessory, ⌥⌘M non-activating panel, `SessionController` (idle ⇄ capturing), `AppShellCoordinator.syncPanel()` is the start/stop funnel.
- Planning session (2026-07-16): SpeechAnalyzer + process-tap APIs **validated against SDK 26.5** (Xcode 26.6) — key signatures and gotchas recorded in slice-02/03 docs; SPEC §6 amendment candidates listed in milestone Integration notes (query format not 16kHz; STTEngine prepare/preferredInputFormat; String+TimeInterval events; @MainActor store).
- Slice docs 2–5 written in slice-01 format, acceptance checks numbered and split machine-verifiable vs user-live. Not yet user-reviewed.
- Build: `xcodebuild -project macapy.xcodeproj -scheme macapy build`; tests: `swift test`; Xcode 26 selected.

## Open concerns

- SpeechAnalyzer **accuracy** still unproven (API shape is validated; quality is not) — slice 2 spike + live checks are the proof point; STTEngine protocol is the escape hatch.
- Unknown: whether the real engine runs under `swift test` (asset download; possible TCC on SPM test processes). Spike fails loudly and rescopes to `swift run`/user-live if blocked.
- Speech-model asset install needs network once — zero-network check must run after it.
- Mic TCC re-prompts on ad-hoc-signed rebuilds (slice 2); process-tap TCC key name to verify hands-on (slice 3); sandbox decision planned → unsandboxed, confirm hands-on in slice 3.
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand — none block M1.
