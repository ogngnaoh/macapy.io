import CaptureKit
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

    public init(
        fixture: String, nVolatile: Int, nFinal: Int,
        p50Ms: Double, p95Ms: Double, maxMs: Double, passG1: Bool
    ) {
        self.fixture = fixture
        self.nVolatile = nVolatile
        self.nFinal = nFinal
        self.p50Ms = p50Ms
        self.p95Ms = p95Ms
        self.maxMs = maxMs
        self.passG1 = passG1
    }
}

/// Runs `fixtureURL` through the real transcription pipeline and returns its
/// `HarnessReport`. The "speech-to-visible" numbers (`p50Ms`/`p95Ms`/`maxMs`/
/// `passG1`) come from **volatile** events only (slice-05 doc decision 3 —
/// that's the G1-relevant moment; finals are a later refinement). `nFinal`
/// is reported alongside as a sanity count, not folded into the percentiles.
public func runHarness(
    fixtureURL: URL, locale: Locale = Locale(identifier: "en_US")
) async throws -> HarnessReport {
    let engine = SpeechAnalyzerEngine(locale: locale)
    try await engine.prepare(locale: locale)
    let format = try await engine.preferredInputFormat()

    // sessionStart is the wall-clock anchor for "audioTEnd == 0": set right
    // before playback begins, so prepare()/format-negotiation time (which
    // can include a one-time asset install) never leaks into the latency
    // numbers.
    let recorder = LatencyRecorder(sessionStart: Date())
    let source = FixturePlaybackSource(fixtureURL: fixtureURL)
    let audio = try await source.start(format: format)
    let events = engine.transcribe(audio, source: .mic)

    for try await event in events {
        let arrivalWall = Date()
        switch event {
        case let .volatile(_, _, tEnd):
            recorder.record(kind: .volatile, audioTEnd: tEnd, arrivalWall: arrivalWall)
        case let .final(segment):
            recorder.record(kind: .final, audioTEnd: segment.tEnd, arrivalWall: arrivalWall)
        case .turnEnded:
            break
        }
    }
    await source.stop()

    let report = recorder.report()
    return HarnessReport(
        fixture: fixtureURL.lastPathComponent,
        nVolatile: report.volatile.count,
        nFinal: report.final.count,
        p50Ms: report.volatile.p50Ms,
        p95Ms: report.volatile.p95Ms,
        maxMs: report.volatile.maxMs,
        passG1: report.volatile.count > 0 && report.volatile.p95Ms < 1_000
    )
}
