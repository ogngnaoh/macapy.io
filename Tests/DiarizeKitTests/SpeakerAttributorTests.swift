import DiarizeKit
import Foundation
import Testing

/// Slice-4 check 2: attribution is exact arithmetic over synthetic turns and
/// segment windows — majority overlap wins, sub-threshold coverage stays
/// unattributed, straddlers go to the side covering more.
struct SpeakerAttributorTests {

    private func window(_ id: UUID, _ tStart: Double, _ tEnd: Double) -> SpeakerAttributor.SegmentWindow {
        .init(id: id, tStart: tStart, tEnd: tEnd)
    }

    @Test func majorityOverlapWins() {
        let segment = UUID()
        let assignments = SpeakerAttributor.assign(
            turns: [
                SpeakerTurn(speakerKey: "a", tStart: 0, tEnd: 7),
                SpeakerTurn(speakerKey: "b", tStart: 7, tEnd: 10),
            ],
            segments: [window(segment, 0, 10)]
        )
        #expect(assignments == [segment: "a"])
    }

    @Test func belowThresholdStaysUnattributed() {
        let segment = UUID()
        let assignments = SpeakerAttributor.assign(
            turns: [SpeakerTurn(speakerKey: "a", tStart: 0, tEnd: 2)],
            segments: [window(segment, 0, 10)]  // 20% coverage < 30% threshold
        )
        #expect(assignments.isEmpty)
    }

    @Test func exactThresholdAttributes() {
        let segment = UUID()
        let assignments = SpeakerAttributor.assign(
            turns: [SpeakerTurn(speakerKey: "a", tStart: 0, tEnd: 3)],
            segments: [window(segment, 0, 10)]  // exactly 30%
        )
        #expect(assignments == [segment: "a"])
    }

    @Test func straddlingSegmentGoesToTheSideCoveringMore() {
        let segment = UUID()
        let assignments = SpeakerAttributor.assign(
            turns: [
                SpeakerTurn(speakerKey: "a", tStart: 0, tEnd: 4),
                SpeakerTurn(speakerKey: "b", tStart: 4, tEnd: 20),
            ],
            segments: [window(segment, 2, 8)]  // a covers 2s, b covers 4s
        )
        #expect(assignments == [segment: "b"])
    }

    @Test func disjointTurnsOfOneSpeakerAccumulate() {
        let segment = UUID()
        let assignments = SpeakerAttributor.assign(
            turns: [
                SpeakerTurn(speakerKey: "a", tStart: 0, tEnd: 2),
                SpeakerTurn(speakerKey: "a", tStart: 3, tEnd: 5),
                SpeakerTurn(speakerKey: "b", tStart: 2, tEnd: 3),
            ],
            segments: [window(segment, 0, 5)]  // a: 4s, b: 1s
        )
        #expect(assignments == [segment: "a"])
    }

    @Test func segmentOutsideAllTurnsStaysUnattributed() {
        let segment = UUID()
        let assignments = SpeakerAttributor.assign(
            turns: [SpeakerTurn(speakerKey: "a", tStart: 0, tEnd: 5)],
            segments: [window(segment, 20, 25)]
        )
        #expect(assignments.isEmpty)
    }

    @Test func zeroDurationSegmentAndEmptyInputsAreSafe() {
        let segment = UUID()
        #expect(SpeakerAttributor.assign(turns: [], segments: [window(segment, 0, 1)]).isEmpty)
        #expect(
            SpeakerAttributor.assign(
                turns: [SpeakerTurn(speakerKey: "a", tStart: 0, tEnd: 1)],
                segments: [window(segment, 1, 1)]
            ).isEmpty)
        #expect(SpeakerAttributor.assign(turns: [], segments: []).isEmpty)
    }

    @Test func equalOverlapTieBreaksDeterministically() {
        let segment = UUID()
        let assignments = SpeakerAttributor.assign(
            turns: [
                SpeakerTurn(speakerKey: "b", tStart: 0, tEnd: 5),
                SpeakerTurn(speakerKey: "a", tStart: 5, tEnd: 10),
            ],
            segments: [window(segment, 0, 10)]  // 5s each — smallest key wins
        )
        #expect(assignments == [segment: "a"])
    }
}
