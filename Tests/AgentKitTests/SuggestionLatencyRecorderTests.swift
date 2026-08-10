import AgentKit
import Foundation
import Testing

struct SuggestionLatencyRecorderTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func nearestRankP95ExcludesImpossibleNegativesAndCountsLifecycle() {
        let recorder = SuggestionLatencyRecorder()
        let ids = (0..<21).map { _ in UUID() }
        for (index, id) in ids.prefix(20).enumerated() {
            recorder.trigger(id, at: start)
            recorder.recordFirstVisible(
                id,
                at: start.addingTimeInterval(Double(index + 1) / 100)
            )
        }
        // Physically impossible and therefore visible-but-excluded.
        recorder.trigger(ids[20], at: start)
        recorder.recordFirstVisible(ids[20], at: start.addingTimeInterval(-1))

        let cancelled = UUID()
        let pending = UUID()
        recorder.trigger(cancelled, at: start)
        recorder.cancel(cancelled)
        recorder.trigger(pending, at: start)

        let report = recorder.report()
        #expect(report.count == 20)
        // Nearest rank n=20: ceil(.95 * 20) = 19 -> 190ms.
        #expect(abs(report.p95Ms - 190) < 0.001)
        #expect(report.excludedNegativeCount == 1)
        #expect(report.cancelledCount == 1)
        #expect(report.pendingCount == 1)
        #expect(report.completedCount == 21)
        #expect(report.totalTriggerCount == 23)
    }

    @Test func firstVisibleWinsAndCancellationIsIdempotent() {
        let recorder = SuggestionLatencyRecorder()
        let id = UUID()
        recorder.trigger(id, at: start)
        #expect(recorder.recordFirstVisible(
            id, at: start.addingTimeInterval(0.25)))
        #expect(!recorder.recordFirstVisible(
            id, at: start.addingTimeInterval(0.5)))
        recorder.cancel(id)

        let report = recorder.report()
        #expect(report.count == 1)
        #expect(abs(report.p95Ms - 250) < 0.001)
        #expect(report.cancelledCount == 0)
    }

    @Test func teardownCancelsPendingAndNewMeetingResetClearsAllEvidence() {
        let recorder = SuggestionLatencyRecorder()
        recorder.trigger(UUID(), at: start)
        recorder.trigger(UUID(), at: start)
        recorder.cancelPending()
        #expect(recorder.report().cancelledCount == 2)
        #expect(recorder.report().pendingCount == 0)

        recorder.reset()
        #expect(recorder.report().totalTriggerCount == 0)
    }

    @Test func concurrentTriggersAndCommitsRemainExact() async {
        let recorder = SuggestionLatencyRecorder()
        let ids = (0..<200).map { _ in UUID() }
        await withTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    recorder.trigger(id, at: self.start)
                    recorder.recordFirstVisible(
                        id,
                        at: self.start.addingTimeInterval(Double(index + 1) / 1_000)
                    )
                }
            }
        }
        let report = recorder.report()
        #expect(report.count == 200)
        #expect(report.pendingCount == 0)
        #expect(report.excludedNegativeCount == 0)
    }
}
