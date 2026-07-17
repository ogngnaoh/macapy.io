import Foundation
import Testing
import TranscribeKit

/// Check 1 (slice 5): `LatencyRecorder` percentile math against synthetic
/// samples with known percentiles. Percentiles use the nearest-rank method
/// (`LatencyReport.Stats`'s doc comment has the exact rank formula) —
/// deterministic, so these expected values are exact, not approximate.
struct LatencyRecorderTests {

    private let sessionStart = Date(timeIntervalSince1970: 1_700_000_000)

    /// A sample arriving `ms` milliseconds after `sessionStart`, with
    /// `audioTEnd == 0` — so its latency is exactly `ms`.
    private func arrival(afterMs ms: Double) -> Date {
        sessionStart.addingTimeInterval(ms / 1_000)
    }

    private func approxEqual(_ a: Double, _ b: Double, tolerance: Double = 0.01) -> Bool {
        abs(a - b) < tolerance
    }

    @Test func tenEvenlySpacedVolatileSamplesYieldExactP50P95Max() {
        let recorder = LatencyRecorder(sessionStart: sessionStart)
        for ms in [100.0, 200, 300, 400, 500, 600, 700, 800, 900, 1_000] {
            recorder.record(kind: .volatile, audioTEnd: 0, arrivalWall: arrival(afterMs: ms))
        }

        let report = recorder.report()
        #expect(report.volatile.count == 10)
        // Nearest-rank, n=10: p50 → rank ceil(5.0)=5 → sorted[4] = 500.
        #expect(approxEqual(report.volatile.p50Ms, 500))
        // p95 → rank ceil(9.5)=10 → sorted[9] = 1000 (== max).
        #expect(approxEqual(report.volatile.p95Ms, 1_000))
        #expect(approxEqual(report.volatile.maxMs, 1_000))
    }

    @Test func fourFinalSamplesYieldExactP50P95Max() {
        let recorder = LatencyRecorder(sessionStart: sessionStart)
        for ms in [100.0, 200, 300, 400] {
            recorder.record(kind: .final, audioTEnd: 0, arrivalWall: arrival(afterMs: ms))
        }

        let report = recorder.report()
        #expect(report.final.count == 4)
        // n=4: p50 → rank ceil(2.0)=2 → sorted[1] = 200.
        #expect(approxEqual(report.final.p50Ms, 200))
        // p95 → rank ceil(3.8)=4 → sorted[3] = 400 (== max).
        #expect(approxEqual(report.final.p95Ms, 400))
        #expect(approxEqual(report.final.maxMs, 400))
    }

    @Test func volatileAndFinalStatsAreComputedIndependently() {
        let recorder = LatencyRecorder(sessionStart: sessionStart)
        recorder.record(kind: .volatile, audioTEnd: 0, arrivalWall: arrival(afterMs: 100))
        recorder.record(kind: .volatile, audioTEnd: 0, arrivalWall: arrival(afterMs: 300))
        recorder.record(kind: .final, audioTEnd: 0, arrivalWall: arrival(afterMs: 5_000))

        let report = recorder.report()
        #expect(report.volatile.count == 2)
        #expect(report.final.count == 1)
        #expect(approxEqual(report.volatile.maxMs, 300))
        #expect(approxEqual(report.final.maxMs, 5_000))
    }

    @Test func emptyRecorderReportsZeroedStatsNotACrash() {
        let recorder = LatencyRecorder(sessionStart: sessionStart)
        let report = recorder.report()
        #expect(report.volatile.count == 0)
        #expect(report.volatile.p50Ms == 0)
        #expect(report.volatile.p95Ms == 0)
        #expect(report.volatile.maxMs == 0)
        #expect(report.final.count == 0)
    }

    @Test func singleSampleAllPercentilesEqualItsOwnLatencyMinusAudioTEnd() {
        let recorder = LatencyRecorder(sessionStart: sessionStart)
        // arrival at +750ms, audioTEnd 0.25s (250ms) → latency = 500ms.
        recorder.record(kind: .volatile, audioTEnd: 0.25, arrivalWall: arrival(afterMs: 750))

        let report = recorder.report()
        #expect(report.volatile.count == 1)
        #expect(approxEqual(report.volatile.p50Ms, 500))
        #expect(approxEqual(report.volatile.p95Ms, 500))
        #expect(approxEqual(report.volatile.maxMs, 500))
    }

    // MARK: - Negative-latency exclusion (slice-5 blocker postmortem)

    /// A sample whose `audioTEnd` (seconds) exceeds its arrival offset —
    /// i.e. a negative-latency sample, the kind the blocker traced to a
    /// pacing bug (since fixed) and now guards against structurally via
    /// exclusion.
    private func negativeSample(_ recorder: LatencyRecorder, kind: LatencyRecorder.Kind, arrivalMs: Double, audioTEndSeconds: Double) {
        recorder.record(kind: kind, audioTEnd: audioTEndSeconds, arrivalWall: arrival(afterMs: arrivalMs))
    }

    @Test func negativeLatencySamplesAreExcludedFromPercentilesButCountedVisibly() {
        let recorder = LatencyRecorder(sessionStart: sessionStart)
        // Two valid (non-negative) volatile samples: 100ms, 300ms.
        recorder.record(kind: .volatile, audioTEnd: 0, arrivalWall: arrival(afterMs: 100))
        recorder.record(kind: .volatile, audioTEnd: 0, arrivalWall: arrival(afterMs: 300))
        // Three negative-latency volatile samples (audioTEnd exceeds the
        // arrival offset) — e.g. arrival at +100ms but audioTEnd claims
        // 1000ms of audio already recognized: latency = 100 - 1000 = -900ms.
        negativeSample(recorder, kind: .volatile, arrivalMs: 100, audioTEndSeconds: 1.0)
        negativeSample(recorder, kind: .volatile, arrivalMs: 200, audioTEndSeconds: 1.0)
        negativeSample(recorder, kind: .volatile, arrivalMs: 50, audioTEndSeconds: 0.2)

        let report = recorder.report()
        // Percentiles computed from the 2 valid samples only.
        #expect(report.volatile.count == 2)
        #expect(approxEqual(report.volatile.maxMs, 300))
        // The 3 negative samples are counted, not silently dropped.
        #expect(report.volatile.excludedNegativeCount == 3)
        #expect(report.volatile.totalCount == 5)
        #expect(approxEqual(report.volatile.excludedNegativeFraction, 3.0 / 5.0, tolerance: 0.001))
    }

    @Test func allNegativeSamplesYieldZeroedPercentilesButNonzeroExcludedCount() {
        let recorder = LatencyRecorder(sessionStart: sessionStart)
        negativeSample(recorder, kind: .volatile, arrivalMs: 10, audioTEndSeconds: 5.0)
        negativeSample(recorder, kind: .volatile, arrivalMs: 20, audioTEndSeconds: 5.0)

        let report = recorder.report()
        #expect(report.volatile.count == 0)
        #expect(report.volatile.p50Ms == 0)
        #expect(report.volatile.p95Ms == 0)
        #expect(report.volatile.maxMs == 0)
        #expect(report.volatile.excludedNegativeCount == 2)
        #expect(report.volatile.totalCount == 2)
        #expect(approxEqual(report.volatile.excludedNegativeFraction, 1.0, tolerance: 0.001))
    }

    @Test func statsWithNoSamplesAtAllHaveZeroTotalCountAndZeroFraction() {
        let recorder = LatencyRecorder(sessionStart: sessionStart)
        let report = recorder.report()
        #expect(report.volatile.totalCount == 0)
        #expect(report.volatile.excludedNegativeFraction == 0)
    }

    @Test func excludedNegativesAreTrackedIndependentlyPerKind() {
        let recorder = LatencyRecorder(sessionStart: sessionStart)
        negativeSample(recorder, kind: .volatile, arrivalMs: 10, audioTEndSeconds: 5.0)
        recorder.record(kind: .final, audioTEnd: 0, arrivalWall: arrival(afterMs: 100))

        let report = recorder.report()
        #expect(report.volatile.excludedNegativeCount == 1)
        #expect(report.final.excludedNegativeCount == 0)
        #expect(report.final.count == 1)
    }
}
