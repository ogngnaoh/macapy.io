import Foundation
import Testing
import TranscribeKit

/// Check 3: `TranscriptStore` volatile/final semantics, ordering, reset, and the
/// `finalsStream()` side-channel that slice 4's writer consumes.
@MainActor
struct TranscriptStoreTests {

    private func segment(
        _ text: String, _ source: AudioSource, _ tStart: TimeInterval, _ tEnd: TimeInterval
    ) -> Segment {
        Segment(id: UUID(), source: source, text: text, tStart: tStart, tEnd: tEnd)
    }

    @Test func volatileReplacesPerSourceLine() {
        let store = TranscriptStore()
        store.apply(.volatile(text: "hel", tStart: 0, tEnd: 1), from: .mic)
        #expect(store.volatile[.mic]?.text == "hel")
        store.apply(.volatile(text: "hello", tStart: 0, tEnd: 1), from: .mic)
        #expect(store.volatile[.mic]?.text == "hello")
        #expect(store.volatile[.mic]?.source == .mic)
        #expect(store.segments.isEmpty)
    }

    @Test func volatileIsPerSourceIndependent() {
        let store = TranscriptStore()
        store.apply(.volatile(text: "you-speaking", tStart: 0, tEnd: 1), from: .mic)
        store.apply(.volatile(text: "them-speaking", tStart: 0, tEnd: 1), from: .system)
        #expect(store.volatile[.mic]?.text == "you-speaking")
        #expect(store.volatile[.system]?.text == "them-speaking")
    }

    @Test func finalClearsThatSourcesVolatileAndAppends() {
        let store = TranscriptStore()
        store.apply(.volatile(text: "hello", tStart: 0, tEnd: 1), from: .mic)
        store.apply(.volatile(text: "them", tStart: 0, tEnd: 1), from: .system)
        store.apply(.final(segment("hello world", .mic, 0, 1)), from: .mic)
        #expect(store.volatile[.mic] == nil)
        #expect(store.volatile[.system]?.text == "them")  // other source untouched
        #expect(store.segments.map(\.text) == ["hello world"])
    }

    @Test func finalsInsertOrderedByTStartAcrossSources() {
        let store = TranscriptStore()
        // Apply out of order; store keeps them sorted by tStart.
        store.apply(.final(segment("second", .system, 2, 3)), from: .system)
        store.apply(.final(segment("first", .mic, 0, 1)), from: .mic)
        store.apply(.final(segment("middle", .mic, 1, 2)), from: .mic)
        #expect(store.segments.map(\.text) == ["first", "middle", "second"])
    }

    @Test func resetEmptiesSegmentsAndVolatile() {
        let store = TranscriptStore()
        store.apply(.volatile(text: "x", tStart: 0, tEnd: 1), from: .mic)
        store.apply(.final(segment("y", .mic, 0, 1)), from: .mic)
        store.reset()
        #expect(store.segments.isEmpty)
        #expect(store.volatile.isEmpty)
    }

    @Test func finalsStreamDeliversExactlyTheFinals() async {
        let store = TranscriptStore()
        let finals = store.finalsStream()

        store.apply(.volatile(text: "on", tStart: 0, tEnd: 1), from: .mic)  // must NOT appear
        store.apply(.final(segment("one", .mic, 0, 1)), from: .mic)
        store.apply(.volatile(text: "tw", tStart: 1, tEnd: 2), from: .system)  // must NOT appear
        store.apply(.final(segment("two", .system, 1, 2)), from: .system)
        store.reset()  // ends the finals stream (new meeting)

        var received: [String] = []
        for await seg in finals {
            received.append(seg.text)
        }
        #expect(received == ["one", "two"])
    }
}
