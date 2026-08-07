import CaptureKit
import DiarizeKit
import Foundation
import TranscribeKit

/// One end-to-end run of the latency harness (slice-05 doc decisions 1–2):
/// fixture → real `FixturePlaybackSource` → real `SpeechAnalyzerEngine` → a
/// fresh `LatencyRecorder`, no UI. Shared by the `LatencyHarness` executable
/// (the release-config authoritative run) and `G1BudgetTests` (the
/// debug-config regression tripwire) — same code path, different
/// configs/fixtures/thresholds.
public struct HarnessReport: Sendable, Codable, Equatable {
    public let fixture: String
    public let nVolatile: Int
    public let nFinal: Int
    public let p50Ms: Double
    public let p95Ms: Double
    public let maxMs: Double
    public let passG1: Bool
    /// Volatile samples excluded from the percentiles above because their
    /// computed latency was negative (negative-latency blocker postmortem —
    /// see `LatencyReport.Stats`'s doc comment). Counted, never silently
    /// folded in: a nonzero value here means the number above rests on
    /// fewer samples than `nVolatile` and is worth a second look.
    public let excludedNegativeCount: Int
    public let excludedNegativeFraction: Double

    public init(
        fixture: String, nVolatile: Int, nFinal: Int,
        p50Ms: Double, p95Ms: Double, maxMs: Double, passG1: Bool,
        excludedNegativeCount: Int, excludedNegativeFraction: Double
    ) {
        self.fixture = fixture
        self.nVolatile = nVolatile
        self.nFinal = nFinal
        self.p50Ms = p50Ms
        self.p95Ms = p95Ms
        self.maxMs = maxMs
        self.passG1 = passG1
        self.excludedNegativeCount = excludedNegativeCount
        self.excludedNegativeFraction = excludedNegativeFraction
    }

    /// Maps a `LatencyReport` snapshot into a `HarnessReport` — pure logic,
    /// factored out of `runHarness` so the negative-exclusion bookkeeping
    /// (`nVolatile` counts every observed event, valid or excluded;
    /// `excludedNegativeCount`/`Fraction` come from the volatile stats) is
    /// unit-testable without a real audio/ASR pipeline. See
    /// `HarnessReportMappingTests` in G1BudgetTests.
    static func from(fixture: String, report: LatencyReport) -> HarnessReport {
        HarnessReport(
            fixture: fixture,
            nVolatile: report.volatile.totalCount,
            nFinal: report.final.totalCount,
            p50Ms: report.volatile.p50Ms,
            p95Ms: report.volatile.p95Ms,
            maxMs: report.volatile.maxMs,
            passG1: report.volatile.count > 0 && report.volatile.p95Ms < 1_000,
            excludedNegativeCount: report.volatile.excludedNegativeCount,
            excludedNegativeFraction: report.volatile.excludedNegativeFraction
        )
    }
}

/// Runs `fixtureURL` through the real transcription pipeline and returns its
/// `HarnessReport`. The "speech-to-visible" numbers (`p50Ms`/`p95Ms`/`maxMs`/
/// `passG1`) come from **volatile** events only (slice-05 doc decision 3 —
/// that's the G1-relevant moment; finals are a later refinement). `nVolatile`/
/// `nFinal` count every event observed, valid or excluded — not folded down
/// by exclusion.
/// `diarize: true` (slice-4 check 10a) adds the production second branch —
/// real FluidAudio consuming the same chunks concurrently — so the release G1
/// number is measured with diarization's CPU load in the picture. Requires
/// installed models; the attributions are discarded (latency is the subject).
public func runHarness(
    fixtureURL: URL, locale: Locale = Locale(identifier: "en_US"), diarize: Bool = false
) async throws -> HarnessReport {
    let engine = SpeechAnalyzerEngine(locale: locale)
    try await engine.prepare(locale: locale)
    let format = try await engine.preferredInputFormat()
    let diarizer = diarize ? DiarizationSession(engine: try FluidAudioDiarizer()) : nil

    // sessionStart is the wall-clock anchor for "audioTEnd == 0": set right
    // before playback begins, so prepare()/format-negotiation time (which
    // can include a one-time asset install) never leaks into the latency
    // numbers.
    let recorder = LatencyRecorder(sessionStart: Date())
    let source = FixturePlaybackSource(fixtureURL: fixtureURL)
    let audio = try await source.start(format: format)

    // Structural clamp (negative-latency blocker fix, Phase 2): covered
    // speech can never exceed audio actually delivered to the analyzer, by
    // construction. Tap the stream between the source and the engine to
    // track cumulative fed-audio duration, and clamp every recorded
    // audioTEnd to `min(rawAudioTEnd, fedSoFar)` — this makes an impossible
    // negative latency structurally impossible in this path, on top of (not
    // instead of) the real fix: `FixturePlaybackSource`'s own real-time
    // pacing had a yield-before-sleep bug that delivered every chunk ~one
    // chunk-duration early throughout the whole stream (root-caused via the
    // Phase-1 investigation — not an anchor-choice problem: the whole-result
    // `range.end` and the per-run `.audioTimeRange` end were numerically
    // identical for every volatile sample and neither ever exceeded
    // fed-audio; the fed clock itself was running fast).
    // Since slice 4 the tee is the production operator itself
    // (`BoundedAudioFanOut`, the memory-watch seam MeetingPipeline uses), so
    // G1 is measured through the exact stream shape the app runs — the
    // fed-clock rides its per-chunk tap.
    let fed = FedAudioCounter()
    let fanOut = BoundedAudioFanOut.split(audio, branchCount: diarizer == nil ? 1 : 2) { chunk in
        fed.add(Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate)
    }
    let feedTask = fanOut.forwarding
    var diarizeTask: Task<Void, Never>?
    if let diarizer {
        let branch = fanOut.branches[1]
        diarizeTask = Task {
            do {
                for await chunk in branch {
                    _ = try await diarizer.ingest(chunk)
                }
                _ = try await diarizer.finalize()
            } catch {
                FileHandle.standardError.write(Data("diarize branch failed: \(error)\n".utf8))
            }
        }
    }

    let events = engine.transcribe(fanOut.branches[0], source: .mic)

    for try await event in events {
        let arrivalWall = Date()
        let fedSoFar = fed.seconds
        switch event {
        case let .volatile(_, _, tEnd):
            recorder.record(kind: .volatile, audioTEnd: min(tEnd, fedSoFar), arrivalWall: arrivalWall)
        case let .final(segment):
            recorder.record(kind: .final, audioTEnd: min(segment.tEnd, fedSoFar), arrivalWall: arrivalWall)
        case .turnEnded:
            break
        }
    }
    await source.stop()
    _ = await feedTask.value
    if let diarizeTask {
        _ = await diarizeTask.value
    }

    return HarnessReport.from(fixture: fixtureURL.lastPathComponent, report: recorder.report())
}

/// Cumulative duration of audio handed off to the engine so far —
/// lock-protected so the feed-forwarding task (writer) and the event loop
/// (reader) can touch it from different tasks safely.
private final class FedAudioCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _seconds: TimeInterval = 0

    var seconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return _seconds
    }

    func add(_ delta: TimeInterval) {
        lock.lock()
        _seconds += delta
        lock.unlock()
    }
}
