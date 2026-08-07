# Slice 4 — Diarization (FluidAudio) + Memory-Watch Hardening + RMS + Diagnostics

**Status:** active
**Plan written:** 2026-07-17; **rewritten 2026-08-07** (joint re-plan of slices 4+5 per handoff — the 2026-07-24 checks predated the no-manual-checks ruling and slices 2–3's findings; all checks are now deterministic automated oracles, user-reviewed at plan approval 2026-08-07)
**References:** ../../SPEC.md §5 (FluidAudio dep), §6.2 (speakers schema), §6.5, G4; ./milestone.md exit criteria 4 & 7; M1 backlog (unbounded-stream memory watch); slice-01 design debt (signal strip RMS wiring)

The plan for this slice is also its record.

## Design

### Scope (grew at re-plan)

Diarization on the them-stream + `speakers` schema + S1/S2 labels; bounded capture→analyzer buffering with drop counter (G4 pull-in); **RMS signal-strip wiring** (slice-1 debt: "session-state-driven until slice 4 wires real RMS"); **diagnostics stat-grid** (memory MB + dropped-chunks tiles per design/06).

### Decisions (re-plan, 2026-08-07; supersede the 2026-07-17 list)

1. **Engine: chunked-incremental FluidAudio *offline* pipeline** (~10 s windows of accumulated them-audio; FluidAudio's cross-call speaker manager keeps within-meeting identity) behind a `DiarizationEngine` protocol. Whole-file re-runs are disqualified by arithmetic (4 h of 16 kHz Int16 them-audio ≈ 460 MB > G4's 400 MB budget); streaming Sortformer is the engine-internal fallback if the Phase-0 gate shows cross-window identity loss. Speaker keys map to `S1`/`S2`… by first appearance (**amends** the old "Speaker 1/2" — design mockups are source of truth and the 34 pt gutter fits only `S1`). Mic stream is the user by definition; M1 you/them untouched.
2. **Placement: new SPM target `DiarizeKit`** (deps: CaptureKit + FluidAudio; *not* PersistKit — it emits value types and `MeetingPipeline` writes the stores). TranscribeKit stays pure Speech-framework; all model-gated suites live in `DiarizeKitTests`. Chunks arrive in the analyzer's *negotiated* format (Int16 mono 16 k on SDK 26.5, but queried) — DiarizeKit converts defensively to its required 16 k mono rather than assuming.
3. **Attribution is post-hoc, two channels.** Live: `TranscriptStore.speakerLabels: [Segment.ID: String]` observable map + `setSpeakerLabel` (cleared on `reset()`); gutter resolves `label ?? "Them"/"You"`; volatile lines never consult the map — G1 untouched by construction. DB: one batched sweep in `MeetingPipeline.stop()`, after `segmentWriter.flushAndStop()` (kills the insert/UPDATE race with the debounced writer) and before `endMeeting` (the post-meeting agent always sees labels; a mid-meeting crash loses labels but keeps the transcript — same durability class as M1, accepted). The diarizer consumes audio via its fan-out branch and finals via a second `finalsStream()` consumer (the store's continuation dictionary supports N consumers), attached pre-capture under the same binding constraint as the SegmentWriter. AgentKit boundary: `MeetingStore.attributedSegments(for:)`; one-line change at `PostMeetingAgent.swift:96`.
4. **Bounded fan-out lives in CaptureKit** (**amends** old decision 4's "fan-out in TranscribeKit" — the operator has nothing STT-specific and the RMS tap wants it too): `BoundedAudioFanOut` — one forwarding task eagerly drains the source stream (capture's internal `.unbounded` streams never accumulate) into N `.bufferingNewest(100)` branches (~10 s of audio at the observed ~0.1 s chunk cadence; ~320 KB ceiling per branch), per-branch lock-protected drop counters from the yield result's evicted element. Applied at the `MeetingPipeline.start()` seam for both sources: mic → [STT], system → [STT, diarizer]. The latency harness re-routes through the same operator so G1 measures the production shape. Drop-oldest + a counted, surfaced gap is the honest stall behavior — replaying a >10 s backlog into STT would produce garbage timing anyway.
5. **RMS:** computed per-chunk inside the forwarding loop (both sources — design wants per-source levels: you = amber, them = slate) → lock-protected `SignalLevelMeter` → `coordinator.currentSignalMeter` → `SignalStripView` polls at 100 ms via `TimelineView`. Tick shape, voice colors, and the reduce-motion static-dot collapse are preserved (level modulates tick scale only).
6. **Models: consent-gated one-time download (author ruling 2026-08-07).** `DiarizationModelStore.isInstalled` (checks `~/.cache/fluidaudio/Models/`) + `downloadIfNeeded()` called only behind an explicit Settings affordance naming the endpoint and ~129 MB size; `DiarizationAvailability.resolve(consented:installed:)` is a pure decision. Models absent ⇒ the meeting runs exactly as M1 with zero network — the G6 default is preserved and the download is a documented, user-approved exception. Tests needing real models gate skip-not-fail: `@Suite(.enabled(if: hasModels))` (the `LiveCredentials.hasDeepSeek` precedent).
7. **Speaker roster surface: deferred** — not drawn in any approved mockup; the gutter labels carry the information and history rows get a speaker count in slice 5. Needs a design addendum if ever wanted.

### FluidAudio vetting record (desk half, 2026-08-07)

Apache-2.0 SDK; diarization models CC-BY-4.0 (pyannote-segmentation + WeSpeaker CoreML conversions, ~129 MB, cached under `~/.cache/fluidaudio/Models/`, `offlineMode` flag available). Maintenance healthy: 2.6 k★, 644 commits, v0.12.x with frequent releases, CI diarization-benchmark regression tests, wide production adoption. Zero SPM package dependencies, but two C++ wrapper targets and one **build-time binary xcframework** (NemoTextProcessing from FluidInference's text-processing-rs; SPM-checksummed — supply-chain note, and clean checkouts fetch it at build time). Platforms macOS 14+ / swift-tools 6.0 — compatible with our macOS 26 / Swift 6 target. **The empirical half is Phase 0's hard gate below.**

## Acceptance checks (rewritten 2026-08-07; user-reviewed at plan approval — all deterministic automated oracles)

**[M]** = gated skip-not-fail on model presence; real-time-paced runs live only in gated suites so the always-run suite stays fast.

1. **[M]** Two-voice fixture through the real `FluidAudioDiarizer`: ≥ 2 distinct speaker keys; per the fixture's known voice schedule, every voice-A region resolves (majority overlap) to one key, every voice-B region to another, A ≠ B. *(replaces old check 1; precondition: Phase-0 gate passed)*
2. `SpeakerAttributor` pure oracle: synthetic turns × synthetic finals → exact expected assignments, incl. below-threshold → nil and boundary-straddling cases. *(new)*
3. **[M]** Real-pipeline multi-voice run: two-voice fixture as `.system` + single-voice as `.mic` via `FixturePlaybackSource`, real SpeechAnalyzer + real FluidAudio through the real `MeetingPipeline` → after `stop()`: ≥ 2 speakers rows labeled S1/S2; ≥ 2 distinct speakerIds on them-segments; every mic segment's speakerId NULL; stop-duration loosely bounded. *(replaces former live check 7 — the real-meeting half folds into dogfooding + the app-complete walk, satisfying milestone exit criterion 4's dev half)*
4. Fake-diarizer pipeline test: turns spanning all time ⇒ only `.system` segments labeled; all M1 you/them tests stay green unmodified. *(replaces old 2)*
5. Stall oracle: stalled consumer, K ≫ n chunks ⇒ drop counter == K − n exactly; on resume the consumer receives exactly the newest n, in order; weak refs to every evicted `AVAudioPCMBuffer` are nil (evicted audio provably deallocated ⇒ flat memory structurally). *(replaces old 4 + the stall half of old live 8)*
6. Bounded-growth oracle: ~36 000 chunks (1 h-equivalent) fast-fed with a slow consumer ⇒ live-chunk count never exceeds bound × branches, total drops match exact arithmetic; `MemoryFootprint` sanity (reading > 0; touching a 64 MB allocation raises it ≥ 48 MB). *(new; the growth half of old live 8 — the 1-hour real reading folds into dogfooding via the diagnostics readout)*
7. Schema v4 oracles: extended exact-set column pins (`speakers`; `segments` + `speakerId`); insert/assign round-trip; meeting delete cascades speakers and segments; speaker delete ⇒ `segments.speakerId` NULL; double-migration no-op. *(replaces old 5)*
8. Persistence sweep + agent boundary: fake-diarizer run ⇒ speakers rows in first-appearance order with expected segment assignments; `PostMeetingAgent` transcript lines read S1/S2 for attributed, Them for unattributed, You for mic. *(new)*
9. Live-UI attribution: `setSpeakerLabel` updates the observable map, `reset()` clears it; gutter-resolution helper returns S1 when attributed, Them/You otherwise; volatile lines never consult attributions. *(new)*
10. G1: (a) **[M, release]** `swift run -c release macapy-latency <fixture> --diarize` p95 passes with the fan-out + real diarization branch active; (b) always-run: fan-out pass-through preserves order with zero drops under a draining consumer; the debug G1 tripwire (now routed through the operator) stays green. *(replaces old 3)*
11. RMS exact values (silence → 0, constant amplitude a → a, known sine → a/√2 within fixed tolerance); `SignalLevelMeter` concurrent record/poll returns the latest per-source level. *(new)*
12. Diagnostics wiring: scripted stall run ⇒ coordinator-exposed drop count polled by diagnostics is the exact expected value; memory-tile formatting helpers pinned; G3/STT-error slots render as reserved placeholders (wiring is M3 debt). *(new)*
13. Full `swift test` green (always-run suite fast, fakes only); gated suites green where models present; `xcodebuild` clean. *(replaces old 6)*

Former live checks 7–8 are fully re-expressed by 3, 5, 6, 12 + the diagnostics readout during normal dogfooding; no author-walked checks during development (2026-08-06 ruling).

## Checklist

- [x] Acceptance checks user-reviewed (original set at M2 kickoff gate 2026-07-24; **rewritten set reviewed at joint re-plan approval 2026-08-07**)
- [x] FluidAudio desk vetting (license/size/maintenance) recorded above
- [ ] **Phase 0 — HARD GATE:** FluidAudio + `DiarizeKit` skeleton in Package.swift; two-voice `say` fixture candidates generated (`say -v` M/F pair, alternating utterances, `afconvert` → 16 k mono Int16) and run through real FluidAudio in a scratch harness; pass ⇒ commit `Tests/DiarizeKitTests/Fixtures/two-voices.wav` (~60–90 s, known schedule) and finalize check 1; fail ⇒ other voice pairs / longer turns / author-recorded clips
- [ ] Phase 1 — `BoundedAudioFanOut` + `SignalLevelMeter` + `rms(of:)` in CaptureKit (TDD: checks 5, 6, 10b, 11); wired at the pipeline seam; `signalMeter`/`droppedChunks` exposed via pipeline + coordinator; existing pipeline tests green unmodified
- [ ] Phase 2 — `MemoryFootprint.current()` (mach `phys_footprint`); `StatTile` + stat-grid to design/06 in `DiagnosticsSectionView` (latency p50/p95, Memory MB, Dropped chunks; reserved G3/STT slots); signal strip wired (100 ms poll)
- [ ] Phase 3 — migration `v4-speakers` (+ `segments.speakerId` FK `.setNull`); `SpeakerRecord`; `MeetingStore.insertSpeakers/assignSpeakers/speakers(for:)/attributedSegments(for:)`; column pins extended (TDD: check 7)
- [ ] Phase 4 — DiarizeKit proper: `DiarizationEngine`, `FluidAudioDiarizer` actor, pure `SpeakerAttributor`, `DiarizationSession`, `DiarizationModelStore`/`DiarizationAvailability` (TDD: checks 1, 2)
- [ ] Phase 5 — pipeline integration (injected diarizer, live label pushes, finalize-and-persist in `stop()`); panel/detail label resolution; agent labels; Settings consent affordance (checks 4, 8, 9)
- [ ] Phase 6 — gated end-to-end (check 3); harness `--diarize` + release G1 run (check 10a); full suite + xcodebuild (check 13)
- [ ] Verifier re-runs checks 1–13 with evidence
- [ ] Ship rituals: slice table, integration notes, handoff, commit

## Notes / dead ends

(append as work proceeds)
