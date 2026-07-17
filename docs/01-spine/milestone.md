# Milestone 01 — The Spine

**Status:** active
**References:** ../../PRD.md (FR-001, FR-002, FR-003, FR-010 partial, FR-013 partial, FR-014 partial), ../../SPEC.md §6

## Goal

Ship the fastest fully-local live meeting transcriber on macOS — the author can run a real meeting end-to-end (capture → live you/them transcript → persisted history) with zero credentials and zero network traffic.

## Scope

- Swift 6 / SwiftUI app skeleton with the SPM module layout from SPEC §6.1 (`AppShell`, `CaptureKit`, `TranscribeKit`, `PersistKit`; `AgentKit`/`ProviderKit` as empty stubs).
- Menu bar presence + compact always-on-top floating panel; manual start/stop with global hotkey.
- Microphone capture via AVAudioEngine; system-audio capture via Core Audio process tap (`CATapDescription`), both at 16kHz.
- On-device streaming transcription via SpeechAnalyzer behind the `STTEngine` protocol (volatile results render grey, finals replace in place).
- SQLite persistence via GRDB (`meetings`, `segments`, `settings`; schema v1 from SPEC §6.2), including ephemeral (in-memory) mode and pause-capture hotkey.
- Minimal past-meetings list to reopen a persisted transcript (verification surface, not the M2 history feature).
- Latency instrumentation + fixture-playback harness measuring the G1 budget.

## Non-goals

- No diarization (you/them comes free from the two streams; speakers are M2).
- No LLM calls of any kind — `ProviderKit` stays a stub; no key-entry UI.
- No search, no artifacts, no memory (M2+).
- No visual design investment — panel is functional-minimal until the dedicated frontend design session.
- No support for macOS < 26, no second STT engine.

## Slices

| # | Slice (end-to-end, independently shippable) | Status |
|---|---|---|
| 1 | App skeleton: SPM targets, menu bar item, empty floating panel, start/stop state machine ([plan/record](./slice-01-app-skeleton.md)) | shipped 2026-07-16 |
| 2 | Mic → SpeechAnalyzer → live transcript rendering in panel (volatile/final) ([plan/record](./slice-02-mic-live-transcript.md)) | shipped 2026-07-17 |
| 3 | System-audio process tap → dual-stream transcription → you/them labels ([plan/record](./slice-03-system-audio-tap.md)) | shipped 2026-07-17 |
| 4 | GRDB persistence + meeting lifecycle + ephemeral mode + pause hotkey + minimal history list ([plan/record](./slice-04-persistence.md)) | shipped 2026-07-17 |
| 5 | Latency instrumentation, diagnostics basics, fixture-playback test harness proving G1 ([plan/record](./slice-05-latency-harness.md)) | shipped 2026-07-17 |

## Integration notes

(Decisions and dead ends worth remembering — append as work proceeds.)

- 2026-07-16: Milestone derived from approved SPEC; no code exists yet. v0 (Electron/FastAPI) still occupies the repo pending archival decision.
- 2026-07-16 (slice 1): Hand-authored thin pbxproj + root-level local SPM package ref (".") works on Xcode 26.6 — no project generator needed. Decisions: accessory app w/ dynamic activation policy; Carbon RegisterEventHotKey (no Accessibility TCC); no swift-log (os.Logger suffices — SPEC §5 amendment candidate); sandbox decision deferred to slice 3; panel has no close button (visibility stays in lockstep with session state). Gotchas hit: NSPanel `hidesOnDeactivate` defaults true; Swift 6.3 forbids @MainActor storage access from nonisolated deinit (→ `nonisolated(unsafe)` for Carbon refs).
- 2026-07-16 (slices 2–5 planning): SpeechAnalyzer API **validated against SDK 26.5** — actor-based, fed via `AsyncSequence<AnalyzerInput>`, volatile results opt-in (`ReportingOption.volatileResults`), `result.isFinal`, `AssetInventory` model install; process-tap API (`CATapDescription`, `AudioHardwareCreateProcessTap`) confirmed present. SPEC §6 amendment candidates from this: (1) audio format must be *queried* via `bestAvailableAudioFormat` — the fixed-16kHz assumption is wrong, conversion step needed; (2) `STTEngine` gains `prepare()`/`preferredInputFormat()`; (3) `TranscriptEvent` carries plain `String` + `TimeInterval` (matches schema v1); (4) `TranscriptStore` as `@MainActor @Observable` rather than plain actor in M1. Also: the zero-network exit check (criterion 4) must be sequenced **after** the one-time speech-model asset install, which needs network once. Execution model: front-loaded slice docs 2–5 with a single user review gate; per slice, builder subagent (TDD) → critic pass (slices 2–3 only) → independent verifier subagent re-runs machine checks → user-walked live checks; orchestrator owns docs and commits; handoff rewritten at every role boundary.

- 2026-07-17 (slice 2 shipped): Real mic → SpeechAnalyzer → live panel works end-to-end; user-verified live. Role loop earned its keep: critic found a MAJOR teardown-chaining leak the builder's tests couldn't see (fixed TDD, red 30bd2de → green 1dd43fc, closure verified empirically); verifier independently re-executed red at the pre-fix tree via `git archive` scratch dir (technique worth reusing). Gotchas: `.secondary` color alone can't mark volatile text against the panel — italic added (e61295f), full fix belongs to the frontend-design session; `finalsStream()` has no replay (binding constraint recorded in slice-04 doc); AVAudioFormat is non-Sendable (reconstruct per source); queried analyzer format is 16kHz **Int16** mono. Slice-2 verifier caveat carried forward: cross-event timestamp ordering assertion added to slice-3's dual-stream test (check addition flagged to user at ship).

- 2026-07-17 (slice 3 shipped): dual-stream you/them works live (video→Them, mic→You, headphones OK, mid-capture device switch stayed sane). Decisions confirmed hands-on: **unsandboxed** (SPEC §8 clarification resolved); TCC key `NSAudioCaptureUsageDescription`/`kTCCServiceAudioCapture` — keys aren't in SDK headers, the `tccd` binary's service→key string table is the authoritative source (reusable technique). Private tap + private aggregate ⇒ coreaudiod auto-destroys on process exit, even on crash. Two concurrent real analyzers proven (machine check 2). Backlog: mid-capture format change unhandled by code (didn't reproduce on device switch; fix = format listener if it ever does); TCC denial presents as silent audio (M5 onboarding UX); unbounded audio stream under analyzer stall is more acute for continuous system audio (G4 memory watch). Real-meeting dogfood (live check 8) deferred to milestone close-out.

- 2026-07-17 (slice 4 shipped): persistence + lifecycle + ephemeral + pause + history all live-verified (incl. sqlite row-count ephemeral proof). GRDB pinned 7.11.1 (first external dep). Two defects caught by the role loop before ship: **SegmentWriter tail-final data loss** — flushAndStop relied on actor enqueue order; with the test's scheduling slack removed the loss was *deterministic*, fixed via explicit stream-finish (`TranscriptStore.finishFinalsStreams()`, additive API) + completion signal; and a **latent slice-1 HotKey bug** (unfiltered Carbon handler would have swallowed both hotkeys once ⌥⌘P existed), fixed with EventHotKeyID filtering and proven live. SPEC §6.2 amendment note: DB columns are camelCase, not the sketch's snake_case. Lesson recorded: a test that needs `Task.yield()` slack to pass is hiding a race, not tolerating one.

- 2026-07-17 (slice 5 shipped — **G1 proven**): authoritative release harness on the author's machine: **p95 85.36ms / p50 32.97ms speech-to-visible** (775 volatiles, 34 finals, 0 excluded), ~11.7× inside the 1s budget — exit criterion 1 satisfied. The number is only credible because the review loop killed two false versions of it first: the initial harness reported *negative* latencies (p95 −4.77ms, passG1 "true") — verifier's raw-sample dump exposed it; root cause was the fixture player yielding chunks before their pacing sleep (~100ms early all run), NOT SpeechAnalyzer, whose timestamps proved honest (0/775 exceed fed audio). Fixes: sleep-then-yield + chunk-level precision test (red 12/12 pre-fix), fed-audio clamp, and impossible-negative samples now excluded-and-counted visibly in every report (a silently-flattering number can't recur). Lesson recorded: when a measurement looks impossibly good, suspect the harness before the system under test.

## Exit criteria

Written before implementation (verification convention):

1. Fixture-playback harness shows speech-to-visible-transcript < 1s (G1) on base Apple Silicon.
2. Author runs one real meeting end-to-end: dual-source transcript live in the panel, persisted, reopenable from the list.
3. Capture works with headphones connected (process tap is pre-output).
4. Zero-credential, zero-network run confirmed (no outbound traffic observed during a full meeting).
5. Cold start < 2s; pause hotkey verifiably halts capture; ephemeral meeting leaves no rows on disk.
