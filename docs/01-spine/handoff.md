# Handoff — Milestone 01 (Spine)

## Start here next session

Slice 4 (GRDB persistence + lifecycle + ephemeral + pause hotkey + history) is **active**; slice4-builder (sonnet) dispatched for the full TDD build — no user touchpoint until its live checks 8–10 (pause halts capture, ephemeral leaves no rows, history reopens a transcript). **Binding constraint the builder must honor (slice-04 doc Notes):** `finalsStream()` has no replay — SegmentWriter attaches BEFORE `pipeline.start()` and re-attaches after every `reset()`, with tests for that ordering. Then verifier (no critic pass for slice 4 per plan) → user live checks → ship ritual → slice 5. If resuming mid-slice, the slice-04 checklist shows the last completed role.

## Current state

- Slices 1–3 **shipped** (3: 2026-07-17; its live check 8, real-meeting dogfood, deferred to close-out by agreement). Dual-stream you/them verified live incl. headphones and mid-capture device switch.
- 26/26 tests green; `xcodebuild` clean; zero external deps so far — GRDB lands in slice 4 (first `.package` entry; tooling fetch is fine, app still makes zero network calls).
- Key techniques recorded: `tccd` string table for TCC keys (slice-03 Notes), `git archive` scratch-dir for read-only old-rev test runs, injected-bug non-vacuity proofs (verifier), two-phase builder with TCC checkpoint.
- Backlog (recorded in milestone Integration notes): mid-capture format listener (didn't reproduce), TCC-denial-silent onboarding UX (M5), unbounded-stream memory watch under analyzer stall (G4).
- Commands: `swift test`, `xcodebuild -project macapy.xcodeproj -scheme macapy build`; Xcode 26 selected.

## Open concerns

- Real-meeting dogfood pending (close-out): accuracy/robustness in a genuine call is still the ultimate unproven.
- Clean-machine speech-model download path unexercised (model preinstalled here); zero-network claim holds only post-install.
- GRDB version pin is the builder's choice this slice — record it and the migration-v1 shape in the slice doc at ship.
- Sleep-based teardown regression test: theoretical flake under extreme load (clean so far).
- ⌥⌘P second Carbon hotkey lands in slice 4 — watch for collisions with existing app shortcuts.
