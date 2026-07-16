# Slice 2 — Mic → SpeechAnalyzer → Live Transcript

**Status:** active
**Plan approved:** pending user review (front-loaded batch for slices 2–5, 2026-07-16)
**References:** ../../SPEC.md §6.1, §6.3–6.4, ./milestone.md, ./slice-01-app-skeleton.md

The plan for this slice is also its record (working-doc convention). Checklist below is current state.

## Design

### Decisions (made during planning, 2026-07-16)

1. **API surface validated against SDK 26.5 (planning session):** `SpeechAnalyzer` is an actor fed via `AsyncSequence<AnalyzerInput>` (wrapping `AVAudioPCMBuffer`); volatile results are opt-in (`ReportingOption.volatileResults`); `result.isFinal` distinguishes partials; `result.text` is `AttributedString`; model assets require `AssetInventory` install/reserve. SPEC's fixed-16kHz assumption is wrong — the analyzer's format must be **queried** via `bestAvailableAudioFormat(compatibleWith:)` and capture converted to it (SPEC §6 amendment candidate).
2. **Format handshake and conversion live in CaptureKit.** The pipeline asks the engine for its preferred format, then starts capture with that format; `MicCapture` converts at the tap callback via a hardware-free `BufferConverter`. TranscribeKit consumes a uniform pre-converted stream and never touches AVAudioConverter — slice 3's tap source reuses the converter unchanged.
3. **`pause()/resume()` ship in the capture protocol now**, trivially implemented on AVAudioEngine, even though the hotkey arrives in slice 4. Exit criterion 5 ("pause verifiably halts capture") is a capture-layer operation; retrofitting the protocol after slice 3's tap conformance would break it.
4. **`AudioChunk` is a zero-copy `@unchecked Sendable` wrapper** over `AVAudioPCMBuffer` with one documented ownership rule: the producer never touches a buffer after yielding it. `BufferConverter` allocates a fresh output buffer per conversion, so the rule holds by construction. `time: CMTime?` field exists but is `nil` in M1 (see 6).
5. **`STTEngine` protocol amended vs SPEC §6.3:** gains `prepare(locale:)` (asset check/download — async, must happen before capture starts) and `preferredInputFormat()`. `TranscriptEvent` carries plain `String` (attributes stripped at the engine boundary; M1 panel doesn't use them) and `TimeInterval` seconds (matches schema v1 `t_start`/`t_end`). `.turnEnded` stays in the enum but is **never emitted in M1** — the M3 engine adds it from silence-gap heuristics. Both are SPEC amendment candidates.
6. **Session-relative timeline, designed for slices 3/5:** audio is fed contiguously (`bufferStartTime: nil`) and all capture sources start together at pipeline start, so every analyzer's timeline shares zero ≈ session start and `Segment` times are comparable across sources (slice 3 interleaves by `tStart`; slice 5 computes latency from audio time). Escape hatch if drift appears: stamp `bufferStartTime` from a shared host-time clock via `AudioChunk.time`.
7. **`TranscriptStore` lands now, as `@MainActor @Observable` in TranscribeKit** (SPEC says actor — amendment candidate: event rates are a few/sec, main-actor serialization costs nothing at M1 scale and removes an observation-bridging layer). Volatile model: **at most one volatile line per source** — SpeechTranscriber volatiles are successive refinements of the current utterance, so a final clears that source's volatile line and appends a `Segment`; no volatile/final id-matching needed. Finals also flow out a `finalsStream()` side-channel for slice 4's writer.
8. **One analyzer + transcriber pair per source per meeting**, created inside each `transcribe()` call. On input-stream end the engine calls `finalizeAndFinishThroughEndOfInput()`, drains remaining finals, then finishes — "stop meeting" is just "finish the capture streams" and the transcript tail arrives naturally. Errors surface via `finish(throwing:)`; the pipeline logs and stops the session.
9. **AppShell seam:** a `@MainActor MeetingPipeline` owned by `AppShellCoordinator` through an injectable factory (`init(makePipeline:)` defaulting to production wiring) so AppShellTests drive the whole shell with fakes. `syncPanel()` stays the single start/stop funnel; the start branch resets the store, creates the pipeline, and holds the start `Task` (rapid-toggle guard). `TranscriptStore` is app-lifetime, owned by the coordinator, injected into the panel's environment (the hosting view is cached, so the object must be stable).
10. **De-risk spike is the first build task:** one integration test proving fixture-wav → real SpeechAnalyzer → transcript works under `swift test` (unknowns: asset download, whether SPM test processes need speech TCC). If environment-blocked, it must fail with an explicit "environment-blocked" message — the check is then rescoped to `swift run`/user-live and recorded here, never green-washed.
11. **Asset install vs zero-network:** `prepare()` may download Apple's speech model once; the zero-network acceptance check is sequenced **after** that install (noted in milestone doc).

### Layout

```
Sources/CaptureKit/CaptureTypes.swift        AudioSource, AudioChunk, CaptureError
Sources/CaptureKit/AudioCaptureSource.swift  protocol (start/pause/resume/stop)
Sources/CaptureKit/BufferConverter.swift     AVAudioConverter core, hardware-free
Sources/CaptureKit/MicCapture.swift          actor; AVAudioEngine input tap → convert → yield
Sources/TranscribeKit/TranscriptTypes.swift  Segment, TranscriptEvent, TranscribeError
Sources/TranscribeKit/STTEngine.swift        protocol
Sources/TranscribeKit/SpeechAnalyzerEngine.swift
Sources/TranscribeKit/TranscriptStore.swift  @MainActor @Observable
Sources/AppShell/MeetingPipeline.swift       start/stop orchestration, per-source event tasks
Tests/CaptureKitTests/                       BufferConverter tests
Tests/TranscribeKitTests/                    spike test, TranscriptStore tests, Fixtures/*.wav
Tests/AppShellTests/                         pipeline tests w/ FakeSTTEngine + FakeCaptureSource
App/Info.plist                               + NSMicrophoneUsageDescription
Package.swift                                TranscribeKit → CaptureKit dep; new test targets
```

### Components

```swift
// CaptureKit
public enum AudioSource: String, Sendable, Codable, Hashable { case mic, system }   // mic = "you"

/// Zero-copy transfer: producer must not touch `buffer` after yielding.
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let time: CMTime?          // host-time anchor; nil in M1 (contiguous feed)
}

public protocol AudioCaptureSource: Sendable {
    var source: AudioSource { get }
    /// Delivers chunks already converted to `format`. Stream finishes on stop().
    func start(format: AVAudioFormat) async throws -> AsyncStream<AudioChunk>
    func pause() async
    func resume() async
    func stop() async
}

public actor MicCapture: AudioCaptureSource { public init() }
public struct BufferConverter {
    public init(from: AVAudioFormat, to: AVAudioFormat) throws
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer
}

// TranscribeKit
public struct Segment: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let source: AudioSource
    public let text: String
    public let tStart: TimeInterval   // seconds, session-relative
    public let tEnd: TimeInterval
}

public enum TranscriptEvent: Sendable, Equatable {
    case volatile(text: String, tStart: TimeInterval, tEnd: TimeInterval)
    case final(Segment)
    case turnEnded                    // reserved for M3; never emitted in M1
}

public enum TranscribeError: Error {
    case localeUnsupported(Locale)
    case assetsUnavailable(Locale, underlying: Error?)
    case analyzerFailed(underlying: Error)
}

public protocol STTEngine: Sendable {
    func prepare(locale: Locale) async throws
    func preferredInputFormat() async throws -> AVAudioFormat
    func transcribe(_ audio: AsyncStream<AudioChunk>, source: AudioSource)
        -> AsyncThrowingStream<TranscriptEvent, Error>
}

public struct SpeechAnalyzerEngine: STTEngine { public init(locale: Locale = .current) }

@MainActor @Observable
public final class TranscriptStore {
    public struct VolatileLine: Equatable, Sendable { public let source: AudioSource; public let text: String }
    public private(set) var segments: [Segment]              // ordered by tStart
    public private(set) var volatile: [AudioSource: VolatileLine]
    public init()
    public func apply(_ event: TranscriptEvent, from source: AudioSource)
    public func reset()
    public func finalsStream() -> AsyncStream<Segment>       // consumed by slice 4
}

// AppShell
@MainActor
final class MeetingPipeline {
    init(engine: any STTEngine, sources: [any AudioCaptureSource], store: TranscriptStore)
    func start() async throws   // prepare → preferredInputFormat → start captures → per-source event tasks
    func stop() async           // stop captures (streams finish) → engines finalize → await drain
    func pause() async          // forwards to sources (hotkey arrives slice 4)
    func resume() async
}
```

Data flow: mic tap (native format) → `BufferConverter` → `AsyncStream<AudioChunk>` → `SpeechAnalyzerEngine` → `AsyncThrowingStream<TranscriptEvent>` → pipeline task → `store.apply` (MainActor) → `PanelView` observation (segments solid; trailing volatile line in `.foregroundStyle(.secondary)`; scroll pinned to bottom).

## Acceptance checks (written before implementation; user review pending)

Machine-verifiable (`swift test` + `xcodebuild`, re-run by the independent verifier):

1. **De-risk spike:** committed `say`-generated fixture wav → `SpeechAnalyzerEngine` under `swift test` yields a nonempty transcript containing expected keywords; ≥1 `.volatile` event precedes its `.final`; times are monotonic and non-negative; the event stream finishes after input ends. If environment-blocked (asset download impossible / TCC), the test fails with an explicit "environment-blocked" message and the rescope is recorded in this doc.
2. `BufferConverter` unit tests: synthesized 48kHz float buffer converts to the target format with correct format and plausible frame count; no hardware involved.
3. `TranscriptStore` unit tests: volatile replaces the per-source line; final clears that source's volatile and inserts ordered by `tStart` (including two-source interleave); `reset()` empties; `finalsStream()` delivers exactly the finals.
4. AppShell pipeline tests with `FakeSTTEngine` + `FakeCaptureSource`: start populates the store from scripted events; stop finishes streams and drains pending finals; engine error returns the session to idle; rapid toggles with a slow-starting fake never wedge or double-start the pipeline.
5. Slice-1 tests pass unmodified; full `swift test` green; `xcodebuild -project macapy.xcodeproj -scheme macapy build` clean.

User-live:

6. First mic start triggers the TCC prompt showing the `NSMicrophoneUsageDescription` string; after grant, capture proceeds (watch for re-prompts on ad-hoc-signed rebuilds — known handoff concern).
7. Speaking produces a grey volatile line that updates live and is replaced in place by a solid final line; perceived latency ≈ instant (formal measurement is slice 5).
8. After one-time model asset install: a full start→speak→stop run with `lsof -i` against the process shows zero network connections.

## Checklist

- [ ] Slice doc committed before any Swift code
- [ ] Acceptance checks user-reviewed (front-loaded batch gate)
- [ ] Builder: de-risk spike (fixture + failing integration test first, then engine to green)
- [ ] Builder: CaptureKit types + BufferConverter (+ tests red→green)
- [ ] Builder: MicCapture
- [ ] Builder: TranscribeKit types + STTEngine + SpeechAnalyzerEngine
- [ ] Builder: TranscriptStore (+ tests red→green)
- [ ] Builder: MeetingPipeline + coordinator factory + panel rendering + Info.plist
- [ ] Critic pass (concurrency: actor isolation, AudioChunk ownership, stream teardown/drain)
- [ ] Verifier: independent re-run of checks 1–5 with evidence
- [ ] Live checks 6–8 walked with the user
- [ ] Ship rituals: milestone table, integration notes, handoff, final commit

## Notes / dead ends

(append as work proceeds)
