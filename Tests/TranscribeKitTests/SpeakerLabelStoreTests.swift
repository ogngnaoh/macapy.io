import CaptureKit
import Foundation
import Testing
import TranscribeKit

/// Slice-4 check 9: the live attribution map — set, survive unrelated events,
/// clear on reset; volatile rendering has no id to consult it with, by type.
@MainActor
struct SpeakerLabelStoreTests {

    private func final(_ text: String, source: AudioSource = .system, at t: TimeInterval) -> Segment {
        Segment(id: UUID(), source: source, text: text, tStart: t, tEnd: t + 0.9)
    }

    @Test func setSpeakerLabelIsObservableAndIdempotent() {
        let store = TranscriptStore()
        let segment = final("hello", at: 0)
        store.apply(.final(segment), from: .system)

        #expect(store.speakerLabels[segment.id] == nil)  // renders as "Them"
        store.setSpeakerLabel("S1", for: segment.id)
        #expect(store.speakerLabels[segment.id] == "S1")
        store.setSpeakerLabel("S1", for: segment.id)
        #expect(store.speakerLabels[segment.id] == "S1")
    }

    @Test func labelsSurviveLaterEventsAndUnknownIDsAreHarmless() {
        let store = TranscriptStore()
        let first = final("one", at: 0)
        store.apply(.final(first), from: .system)
        store.setSpeakerLabel("S1", for: first.id)

        // A label may land before its final has been applied (live race) —
        // it must simply wait in the map.
        let upcoming = final("two", at: 1)
        store.setSpeakerLabel("S2", for: upcoming.id)
        store.apply(.volatile(text: "thr", tStart: 2, tEnd: 2.4), from: .system)
        store.apply(.final(upcoming), from: .system)

        #expect(store.speakerLabels[first.id] == "S1")
        #expect(store.speakerLabels[upcoming.id] == "S2")
    }

    @Test func resetClearsTheMap() {
        let store = TranscriptStore()
        let segment = final("gone", at: 0)
        store.apply(.final(segment), from: .system)
        store.setSpeakerLabel("S1", for: segment.id)

        store.reset()
        #expect(store.speakerLabels.isEmpty)
    }
}
