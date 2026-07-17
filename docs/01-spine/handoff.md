# Handoff — Milestone 01 (Spine)

## Start here next session

Slice 5 (latency instrumentation + fixture harness proving G1 + diagnostics basics) is **active** — the last build slice. slice5-builder (sonnet) dispatched: LatencyRecorder, FixturePlaybackSource, `LatencyHarness` executable (`swift run -c release macapy-latency <fixture>` → JSON p50/p95/max + pass_g1), G1BudgetTests debug-ceiling regression test, minimal live diagnostics section. Then verifier → user live checks (authoritative release harness run, number recorded in milestone.md) → ship ritual → **milestone close-out**: real-meeting dogfood, zero-network full pass, cold start < 2s, then milestone 01 → shipped / 02 → active. If resuming mid-slice, the slice-05 checklist shows the last completed role.

## Current state

- Slices 1–4 **shipped** (4: 2026-07-17, all live checks individually confirmed). App now does: dual-stream live transcript (You/Them), GRDB persistence w/ history window, ephemeral mode, ⌥⌘M start/stop + ⌥⌘P pause.
- 56/56 tests green ×many, 0 flakes ever; xcodebuild clean incl. wiped-DerivedData builds. GRDB 7.11.1 is the only external dep.
- Slice-4 record: two real defects caught pre-ship (deterministic tail-final data loss in SegmentWriter — fixed via `finishFinalsStreams()` + completion signal; latent slice-1 Carbon HotKey bug — fixed + proven live). Contract notes live in slice-04 Notes (attach-before-start; finish-before-flushAndStop).
- Deferred to close-out by agreement: slice-3 real-meeting dogfood (exit criterion 2), zero-network full-meeting pass (criterion 4), cold-start measure (criterion 5 part).
- Commands: `swift test`, `xcodebuild -project macapy.xcodeproj -scheme macapy build`; Xcode 26 selected.

## Open concerns

- G1 (<1s speech-to-visible) is still **unmeasured** — slice 5 is the proof; if p95 ≥ 1s on base Apple Silicon the milestone's headline claim fails and we tune (chunk size, volatile reporting) before close-out.
- Real-meeting accuracy/robustness unproven until the close-out dogfood.
- Clean-machine model download path unexercised (model preinstalled here).
- Backlog (milestone notes): mid-capture format listener; TCC-denial-silent onboarding (M5); unbounded-stream memory watch under analyzer stall.
