# Handoff — Milestone 01 (Spine)

## Start here next session

Slice 3 (system-audio tap → you/them) is **active**; slice-3 builder runs in two phases: Phase A = config-first (verify exact system-audio TCC usage key against the SDK, add it to Info.plist, record unsandboxed decision, minimal tap-creation path so starting a session triggers the TCC prompt, build clean, then STOP) → **user walks the TCC prompt** → Phase B = full TDD build (red → green per slice-03 checks, incl. the cross-event timestamp ordering assertion added 2026-07-17). Then critic (IOProc real-time safety, teardown ordering, tap lifecycle) → verifier → live checks 4–8 → ship ritual. If resuming mid-slice, the slice-03 checklist shows the last completed role.

## Current state

- Slices 1–2 **shipped** (slice 2: 2026-07-17). Live mic → SpeechAnalyzer → panel works, user-verified; zero network connections confirmed against the live process.
- Slice-2 record (slice-02 doc) holds the full role trail: critic's MAJOR teardown-chaining leak fixed TDD (30bd2de → 1dd43fc) and empirically closed; verifier PASS on all checks with independent red re-execution; live-check-7 contrast failure root-caused (volatiles flowed; `.secondary` alone unreadable) and fixed with italics (e61295f).
- Binding constraints for later slices: slice-04 doc Notes (`finalsStream()` no replay — attach before start, re-attach after reset); AVAudioFormat non-Sendable (reconstruct per source); analyzer format is queried 16kHz Int16 mono.
- 23/23 tests green; `xcodebuild` clean; Xcode 26 selected. Commands: `swift test`, `xcodebuild -project macapy.xcodeproj -scheme macapy build`.

## Open concerns

- Process-tap TCC key name unverified (believed `NSAudioCaptureUsageDescription`) — Phase A verifies hands-on; misconfigured TCC presents as silent audio.
- Unsandboxed decision recorded but to be confirmed hands-on this slice (SPEC §8 clarification).
- Clean-machine speech-model download path still unexercised (model preinstalled here).
- Two concurrent analyzers on base hardware unproven — slice-3 machine check 2 covers it.
- Sleep-based teardown regression test: theoretical flake under extreme load (15/15 clean so far).
