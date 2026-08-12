import CaptureKit
import Foundation
import Testing

@testable import TranscribeKit

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

    /// Slice 4 addition: `finishFinalsStreams()` ends the side-channel (so a
    /// meeting's `SegmentWriter` can complete deterministically at
    /// `MeetingPipeline.stop()`) but — unlike `reset()` — leaves the
    /// transcript itself alone, since the panel keeps showing it after stop.
    @Test func finishFinalsStreamsEndsTheStreamWithoutClearingTranscript() async {
        let store = TranscriptStore()
        let finals = store.finalsStream()

        store.apply(.final(segment("kept", .mic, 0, 1)), from: .mic)
        store.finishFinalsStreams()

        #expect(store.segments.map(\.text) == ["kept"], "finishFinalsStreams must not clear the transcript")

        var received: [String] = []
        for await seg in finals {
            received.append(seg.text)
        }
        #expect(received == ["kept"], "everything yielded before finish() must still be delivered")
    }

    /// AsyncStream's actual guarantee this fix leans on: values yielded
    /// before `finish()` are always delivered to the consumer before it
    /// observes the stream end — regardless of how many were queued up.
    @Test func finishFinalsStreamsDeliversEverythingYieldedBeforeIt() async {
        let store = TranscriptStore()
        let finals = store.finalsStream()

        for i in 0..<20 {
            store.apply(.final(segment("s\(i)", .mic, TimeInterval(i), TimeInterval(i) + 1)), from: .mic)
        }
        store.finishFinalsStreams()

        var received: [String] = []
        for await seg in finals {
            received.append(seg.text)
        }
        #expect(received == (0..<20).map { "s\($0)" })
    }

    @Test func turnsStreamJoinsFinalsAndPreservesSourceIsolationAndEventOrdering() async {
        let store = TranscriptStore()
        let turns = store.turnsStream()
        let micOne = segment(" first ", .mic, 1, 2)
        let system = segment("their turn", .system, 2, 4)
        let micTwo = segment("second", .mic, 4, 5)

        store.apply(.final(micOne), from: .mic)
        store.apply(.final(system), from: .system)
        store.apply(.final(micTwo), from: .mic)
        store.apply(.turnEnded, from: .system)
        store.apply(.turnEnded, from: .mic)
        store.finishFinalsStreams()

        var received: [TranscriptTurn] = []
        for await turn in turns {
            received.append(turn)
        }

        #expect(received.map(\.source) == [.system, .mic])
        #expect(received.map(\.text) == ["their turn", "first second"])
        #expect(received[0].segmentIDs == [system.id])
        #expect(received[1].segmentIDs == [micOne.id, micTwo.id])
        #expect(received[1].tStart == 1)
        #expect(received[1].tEnd == 5)
    }

    @Test func turnsStreamIsNonReplaying() async {
        let store = TranscriptStore()
        store.apply(.final(segment("before", .system, 0, 1)), from: .system)
        store.apply(.turnEnded, from: .system)

        let turns = store.turnsStream()
        store.apply(.final(segment("after", .system, 1, 2)), from: .system)
        store.apply(.turnEnded, from: .system)
        store.finishFinalsStreams()

        var received: [String] = []
        for await turn in turns {
            received.append(turn.text)
        }
        #expect(received == ["after"])
    }

    @Test func turnEndedWithoutNonEmptyFinalsDoesNotEmit() async {
        let store = TranscriptStore()
        let turns = store.turnsStream()

        store.apply(.volatile(text: "draft", tStart: 0, tEnd: 1), from: .mic)
        store.apply(.turnEnded, from: .mic)
        store.apply(.final(segment("  \n", .mic, 1, 2)), from: .mic)
        store.apply(.turnEnded, from: .mic)
        store.finishFinalsStreams()

        var received: [TranscriptTurn] = []
        for await turn in turns {
            received.append(turn)
        }
        #expect(received.isEmpty)
    }

    @Test func resetEndsTurnsStreamAndDropsPendingTurn() async {
        let store = TranscriptStore()
        let turns = store.turnsStream()
        store.apply(.final(segment("unfinished", .mic, 0, 1)), from: .mic)

        store.reset()

        var received: [TranscriptTurn] = []
        for await turn in turns {
            received.append(turn)
        }
        #expect(received.isEmpty)

        let nextMeetingTurns = store.turnsStream()
        store.apply(.turnEnded, from: .mic)
        store.finishFinalsStreams()
        var nextMeetingReceived: [TranscriptTurn] = []
        for await turn in nextMeetingTurns {
            nextMeetingReceived.append(turn)
        }
        #expect(nextMeetingReceived.isEmpty)
    }

    @Test func meetingFinishEndsTurnsStreamAfterDeliveringCompletedTurns() async {
        let store = TranscriptStore()
        let turns = store.turnsStream()
        store.apply(.final(segment("complete", .system, 0, 1)), from: .system)
        store.apply(.turnEnded, from: .system)

        store.finishFinalsStreams()

        var received: [String] = []
        for await turn in turns {
            received.append(turn.text)
        }
        #expect(received == ["complete"])
    }

    @Test func cancellingConsumerRemovesTurnsContinuation() async {
        let store = TranscriptStore()
        let turns = store.turnsStream()
        #expect(store.activeTurnStreamCount == 1)

        let consumer = Task {
            var iterator = turns.makeAsyncIterator()
            return await iterator.next()
        }
        await Task.yield()
        consumer.cancel()
        _ = await consumer.value
        await Task.yield()

        #expect(store.activeTurnStreamCount == 0)
    }
}
