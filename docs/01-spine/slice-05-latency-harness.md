# Slice 5 — Latency Instrumentation, Fixture-Playback Harness (G1), Diagnostics Basics

**Status:** pending
**Plan approved:** pending user review (front-loaded batch for slices 2–5, 2026-07-16)
**References:** ../../SPEC.md §3 (G1), §8 (observability), §10, ./milestone.md

The plan for this slice is also its record (working-doc convention). Checklist below is current state.

## Design

### Decisions (made during planning, 2026-07-16)

1. **One instrument, three consumers.** A single `LatencyRecorder` feeds (a) the authoritative harness executable, (b) a loose-ceiling regression test, (c) the in-app diagnostics section. No parallel measurement paths.
2. **The harness is a separate SPM executable target** (`LatencyHarness`, product `macapy-latency`). Proving G1 needs *a number out*, on demand, in **release** configuration; test targets are pass/fail-shaped and default to debug. Authoritative run: `swift run -c release macapy-latency <fixture.wav>` on base Apple Silicon → JSON `{fixture, n_volatile, n_final, p50_ms, p95_ms, max_ms, pass_g1}`, nonzero exit on fail; the number is recorded in milestone.md (exit criterion 1).
3. **Latency definition (documented approximation of G1):** per event, `arrivalWall − (sessionStartWall + audioTEnd)` — the delay between the moment of speech covered by a result and the event reaching the UI layer; rendering adds ≤1 frame on top. Volatile events are the G1-relevant ones (speech becomes *visible* at the volatile). Recorder computes p50/p95/max.
4. **`FixturePlaybackSource` is product code in CaptureKit** (a full `AudioCaptureSource` conformance): reads a wav via `AVAudioFile`, converts, yields ~100ms chunks paced in real time against a `ContinuousClock` timeline. Shared by the harness executable and the regression test.
5. **Fixtures are machine-generated** (`say -o … && afconvert`), committed under test fixtures — reproducible spoken-English audio without a human recording. A longer (~2–3min) fixture is generated for the authoritative run.
6. **Regression tripwire:** `G1BudgetTests` runs the same harness library on a short fixture with a loose **debug-config** ceiling (p95 < 1.5s) — it catches regressions in CI-ish runs without pretending debug numbers prove G1.
7. **Diagnostics basics (SPEC §8 seed):** a minimal section showing the live session's recorder percentiles and event counts, fed by the same recorder instance the pipeline updates. Full diagnostics panel is M2+.
8. Optional debug `os_signpost`s at chunk-yield and event-arrival for Instruments deep-dives.

### Layout

```
Sources/TranscribeKit/LatencyRecorder.swift   samples + p50/p95/max; Sendable
Sources/CaptureKit/FixturePlaybackSource.swift actor; wav → real-time-paced chunks
Sources/LatencyHarnessLib/ (or TranscribeKit)  runHarness(fixture:) → HarnessReport (shared by exe + test)
Sources/LatencyHarness/main.swift             executable: parse args, run, print JSON, exit code
Tests/TranscribeKitTests/                     recorder math tests
Tests/CaptureKitTests/                        pacing test
Tests/G1BudgetTests/                          debug-ceiling regression test
Sources/AppShell/                             minimal diagnostics section (settings or history window)
Package.swift                                 + LatencyHarness executable target (+ lib), G1BudgetTests
```

### Components

```swift
// TranscribeKit
public final class LatencyRecorder: @unchecked Sendable {   // lock-protected sample buffer
    public struct Sample: Sendable { public let kind: Kind; public let audioTEnd: TimeInterval; public let arrivalWall: Date }
    public enum Kind: Sendable { case volatile, final }
    public init(sessionStart: Date)
    public func record(kind: Kind, audioTEnd: TimeInterval, arrivalWall: Date)
    public func report() -> LatencyReport                    // p50/p95/max per kind + counts
}

// CaptureKit
public actor FixturePlaybackSource: AudioCaptureSource {
    public init(fixtureURL: URL, chunkDuration: TimeInterval = 0.1)
    // yields converted chunks paced so N seconds of audio take ≈N wall seconds
}
```

## Acceptance checks (written before implementation; user review pending)

Machine-verifiable:

1. `LatencyRecorder` percentile math unit tests against synthetic samples (known p50/p95/max).
2. Pacing test: `FixturePlaybackSource` delivers N seconds of fixture audio in ≈N wall seconds (bounded tolerance) and finishes its stream at the end.
3. Harness end-to-end in a test: short fixture through the real engine emits a valid `HarnessReport`; debug-config p95 < 1.5s regression ceiling holds.
4. Full `swift test` green; `xcodebuild` clean.

User-live:

5. `swift run -c release macapy-latency <long fixture>` on base Apple Silicon reports **p95 < 1000ms** for speech-to-visible; the JSON is recorded in milestone.md (exit criterion 1).
6. Diagnostics section shows sane live percentiles and counts during a real meeting.

## Checklist

- [ ] Acceptance checks user-reviewed (front-loaded batch gate)
- [ ] Builder: LatencyRecorder (+ math tests red→green)
- [ ] Builder: FixturePlaybackSource (+ pacing test red→green)
- [ ] Builder: harness lib + executable target + JSON output
- [ ] Builder: G1BudgetTests debug-ceiling regression test
- [ ] Builder: pipeline wiring of recorder + minimal diagnostics section
- [ ] Verifier: independent re-run of checks 1–4 with evidence
- [ ] Live checks 5–6 walked with the user; G1 number recorded in milestone.md
- [ ] Ship rituals: milestone table, integration notes, handoff, final commit

## Notes / dead ends

(append as work proceeds)
