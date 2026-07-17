import Foundation
import Testing
import TranscribeKit

@testable import LatencyHarnessLib

/// Check (slice-5 negative-latency blocker postmortem): `HarnessReport`'s
/// mapping from a `LatencyReport` snapshot excludes negative-latency
/// samples from `p50Ms`/`p95Ms`/`maxMs` (via `LatencyReport.Stats` itself)
/// while still counting every observed volatile in `nVolatile` and
/// surfacing how many were excluded — never silently folding them in. This
/// drives `HarnessReport.from(fixture:report:)` directly with a
/// `LatencyRecorder` fed synthetic samples, so it doesn't need a real
/// audio/ASR pipeline (that end-to-end path is what `runHarness` +
/// `shortFixtureStaysUnderTheDebugConfigCeiling` below cover).
struct HarnessReportMappingTests {

    private let sessionStart = Date(timeIntervalSince1970: 1_700_000_000)

    private func arrival(afterMs ms: Double) -> Date {
        sessionStart.addingTimeInterval(ms / 1_000)
    }

    @Test func negativeVolatileSamplesAreExcludedFromPercentilesAndCountedInTheReport() {
        let recorder = LatencyRecorder(sessionStart: sessionStart)
        // 3 valid volatiles (positive latency).
        recorder.record(kind: .volatile, audioTEnd: 0, arrivalWall: arrival(afterMs: 50))
        recorder.record(kind: .volatile, audioTEnd: 0, arrivalWall: arrival(afterMs: 100))
        recorder.record(kind: .volatile, audioTEnd: 0, arrivalWall: arrival(afterMs: 150))
        // 2 negative volatiles (audioTEnd exceeds the arrival offset — the
        // exact shape the blocker's root-caused pacing bug produced).
        recorder.record(kind: .volatile, audioTEnd: 5.0, arrivalWall: arrival(afterMs: 100))
        recorder.record(kind: .volatile, audioTEnd: 5.0, arrivalWall: arrival(afterMs: 200))
        // 1 final, valid.
        recorder.record(kind: .final, audioTEnd: 0, arrivalWall: arrival(afterMs: 300))

        let report = HarnessReport.from(fixture: "synthetic.wav", report: recorder.report())

        // Every observed volatile is counted — valid or excluded.
        #expect(report.nVolatile == 5)
        #expect(report.nFinal == 1)
        // Exactly the 2 negative samples were excluded, visibly.
        #expect(report.excludedNegativeCount == 2)
        #expect(abs(report.excludedNegativeFraction - 2.0 / 5.0) < 0.001)
        // Percentiles reflect only the 3 valid samples (max = 150ms), never
        // the negative ones.
        #expect(abs(report.maxMs - 150) < 0.01)
        #expect(report.p50Ms >= 0)
        #expect(report.p95Ms >= 0)
    }

    @Test func allValidSamplesReportZeroExcludedCountAndFraction() {
        let recorder = LatencyRecorder(sessionStart: sessionStart)
        recorder.record(kind: .volatile, audioTEnd: 0, arrivalWall: arrival(afterMs: 50))
        recorder.record(kind: .volatile, audioTEnd: 0, arrivalWall: arrival(afterMs: 100))

        let report = HarnessReport.from(fixture: "synthetic.wav", report: recorder.report())

        #expect(report.nVolatile == 2)
        #expect(report.excludedNegativeCount == 0)
        #expect(report.excludedNegativeFraction == 0)
    }

    @Test func allNegativeSamplesFailPassG1RatherThanReportingAMisleadingPass() {
        let recorder = LatencyRecorder(sessionStart: sessionStart)
        // Every volatile sample is negative — nothing valid to measure.
        recorder.record(kind: .volatile, audioTEnd: 5.0, arrivalWall: arrival(afterMs: 10))
        recorder.record(kind: .volatile, audioTEnd: 5.0, arrivalWall: arrival(afterMs: 20))

        let report = HarnessReport.from(fixture: "synthetic.wav", report: recorder.report())

        #expect(report.nVolatile == 2)
        #expect(report.excludedNegativeCount == 2)
        // With zero valid samples, passG1 must not default to a misleading
        // true — an all-excluded run proves nothing about G1.
        #expect(report.passG1 == false)
    }
}
