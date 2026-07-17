import CaptureKit
import Foundation
import Testing
import TranscribeKit

@testable import PersistKit

/// Check 3: `SegmentWriter` flushes on a debounce window and on the row
/// threshold; a final flush at meeting end loses nothing. Also proves the
/// BINDING attach-before-start constraint at the `TranscriptStore` boundary
/// (see SegmentWriter.swift's doc comment and the slice-04 doc Notes).
///
/// `@MainActor`: `TranscriptStore` (TranscribeKit) is main-actor-isolated;
/// the two attach-ordering tests below construct and drive one directly.
@MainActor
struct SegmentWriterTests {
    private func seg(_ text: String, _ t: TimeInterval) -> Segment {
        Segment(id: UUID(), source: .mic, text: text, tStart: t, tEnd: t + 1)
    }

    /// Polls up to ~2s for `fetch` to return a non-empty result.
    private func waitUntilNonEmpty(
        _ fetch: @Sendable () async throws -> [Segment]
    ) async throws -> [Segment] {
        for _ in 0..<200 {
            let result = try await fetch()
            if !result.isEmpty { return result }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try await fetch()
    }

    @Test func flushesOnDebounceWindowWithoutReachingThreshold() async throws {
        let meetingStore = MeetingStore(database: try MacapyDatabase.inMemory())
        let meeting = try await meetingStore.beginMeeting(startedAt: Date(), ephemeral: false)
        let writer = SegmentWriter(
            store: meetingStore, meetingID: meeting.id,
            batchThreshold: 25, debounceNanos: 30_000_000  // 30ms — well short of the test timeout
        )
        let (stream, continuation) = AsyncStream<Segment>.makeStream()
        let runTask = Task { await writer.run(consuming: stream) }

        continuation.yield(seg("one", 0))
        continuation.yield(seg("two", 1))
        // Well under the 25-row threshold: only the debounce window flushes this.

        let stored = try await waitUntilNonEmpty { try await meetingStore.segments(for: meeting.id) }
        #expect(stored.map(\.text) == ["one", "two"])

        continuation.finish()
        _ = await runTask.value
    }

    @Test func flushesAtRowThresholdWithoutWaitingForDebounce() async throws {
        let meetingStore = MeetingStore(database: try MacapyDatabase.inMemory())
        let meeting = try await meetingStore.beginMeeting(startedAt: Date(), ephemeral: false)
        let writer = SegmentWriter(
            store: meetingStore, meetingID: meeting.id,
            batchThreshold: 5, debounceNanos: 5_000_000_000  // 5s — must not be what triggers this flush
        )
        let (stream, continuation) = AsyncStream<Segment>.makeStream()
        let runTask = Task { await writer.run(consuming: stream) }

        for i in 0..<5 { continuation.yield(seg("s\(i)", TimeInterval(i))) }

        // Poll with a short timeout: if this only passed via the 5s debounce,
        // it would still be empty here, catching a threshold-flush regression.
        var stored: [Segment] = []
        for _ in 0..<100 {
            stored = try await meetingStore.segments(for: meeting.id)
            if stored.count == 5 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(stored.count == 5, "threshold flush did not fire promptly (debounce is 5s, this polled ~1s)")
        #expect(stored.map(\.text) == (0..<5).map { "s\($0)" })

        continuation.finish()
        _ = await runTask.value
    }

    /// Regression (verifier-caught race, see SegmentWriter.swift's FIX doc
    /// comment): an earlier `flushAndStop()` read `buffer` directly and could
    /// race a still-in-flight `run()` iteration, silently dropping the tail.
    /// This test is now deterministic by construction: `flushAndStop()` can
    /// only proceed once `run()` has itself observed the stream end and
    /// performed the flush — there is no scheduling window left to race, so
    /// no `Task.yield()`/sleep slack is needed (or would even help mask a
    /// regression here — removing it is the point).
    @Test func finalFlushLosesNothingEvenBelowThresholdAndBeforeDebounce() async throws {
        let meetingStore = MeetingStore(database: try MacapyDatabase.inMemory())
        let meeting = try await meetingStore.beginMeeting(startedAt: Date(), ephemeral: false)
        let writer = SegmentWriter(
            store: meetingStore, meetingID: meeting.id,
            batchThreshold: 25, debounceNanos: 5_000_000_000  // long enough that only the trailing flush can flush in time
        )
        let (stream, continuation) = AsyncStream<Segment>.makeStream()
        let runTask = Task { await writer.run(consuming: stream) }

        continuation.yield(seg("tail-1", 0))
        continuation.yield(seg("tail-2", 1))
        // No yields/sleeps: AsyncStream guarantees both of the above are
        // delivered to run()'s for-await before it observes this as "ended".
        continuation.finish()

        try await writer.flushAndStop()

        let stored = try await meetingStore.segments(for: meeting.id)
        #expect(stored.map(\.text) == ["tail-1", "tail-2"], "final flush must not lose buffered segments")

        _ = await runTask.value
    }

    /// Stress version of the above, run through the real `TranscriptStore` +
    /// `finishFinalsStreams()` path exactly as `MeetingPipeline.stop()` uses
    /// it: apply one final, immediately end the stream, immediately
    /// `flushAndStop()` — zero yields/sleeps between any of these steps, 50
    /// iterations with fresh stores each time. The old (buffer-reading)
    /// `flushAndStop()` would flake here under scheduler pressure; this
    /// passes deterministically because `flushAndStop()` cannot return before
    /// `run()` has drained everything the stream will ever yield.
    @Test func stressImmediateFinishAndStopNeverLosesASegment() async throws {
        for i in 0..<50 {
            let transcriptStore = TranscriptStore()
            let meetingStore = MeetingStore(database: try MacapyDatabase.inMemory())
            let meeting = try await meetingStore.beginMeeting(startedAt: Date(), ephemeral: false)
            let writer = SegmentWriter(store: meetingStore, meetingID: meeting.id)

            let finals = transcriptStore.finalsStream()
            let runTask = Task { await writer.run(consuming: finals) }

            let segment = Segment(id: UUID(), source: .mic, text: "iteration-\(i)", tStart: 0, tEnd: 1)
            transcriptStore.apply(.final(segment), from: .mic)

            transcriptStore.finishFinalsStreams()
            try await writer.flushAndStop()

            let stored = try await meetingStore.segments(for: meeting.id)
            #expect(stored.map(\.text) == ["iteration-\(i)"], "iteration \(i) lost its segment")

            _ = await runTask.value
        }
    }

    // MARK: - Binding constraint: attach before any final can be produced

    /// Reproduces the slice-2 critic's exact hazard at the `TranscriptStore`
    /// boundary: `finalsStream()` has no replay, so a writer must be attached
    /// (this test: before `store.apply` is ever called) to see a final emitted
    /// immediately afterward.
    @Test func attachedWriterCapturesAFinalEmittedImmediatelyAfterAttach() async throws {
        let transcriptStore = TranscriptStore()
        let meetingStore = MeetingStore(database: try MacapyDatabase.inMemory())
        let meeting = try await meetingStore.beginMeeting(startedAt: Date(), ephemeral: false)
        let writer = SegmentWriter(
            store: meetingStore, meetingID: meeting.id, debounceNanos: 30_000_000
        )

        // Attach BEFORE anything is applied — the binding ordering constraint.
        let finals = transcriptStore.finalsStream()
        let runTask = Task { await writer.run(consuming: finals) }

        let segment = Segment(id: UUID(), source: .mic, text: "immediate", tStart: 0, tEnd: 1)
        transcriptStore.apply(.final(segment), from: .mic)

        let stored = try await waitUntilNonEmpty { try await meetingStore.segments(for: meeting.id) }
        #expect(stored.map(\.text) == ["immediate"])

        transcriptStore.reset()  // ends the finals stream
        _ = await runTask.value
    }

    /// The converse, proving the hazard is real (non-vacuity): a final applied
    /// **before** `finalsStream()` is ever called is not — cannot be —
    /// delivered to a writer that attaches afterward. This is what makes the
    /// BINDING constraint binding: attach-after-start would silently lose
    /// exactly this kind of early/boundary final.
    @Test func aFinalAppliedBeforeAttachIsNotDeliveredToALateAttach() async throws {
        let transcriptStore = TranscriptStore()
        let early = Segment(id: UUID(), source: .mic, text: "too-early", tStart: 0, tEnd: 1)
        transcriptStore.apply(.final(early), from: .mic)

        // Attach only now — after the final above was already applied.
        let finals = transcriptStore.finalsStream()
        let received = Received()
        let collectTask = Task {
            for await segment in finals { await received.append(segment) }
        }

        let late = Segment(id: UUID(), source: .mic, text: "on-time", tStart: 1, tEnd: 2)
        transcriptStore.apply(.final(late), from: .mic)
        transcriptStore.reset()
        _ = await collectTask.value

        let texts = await received.texts
        #expect(texts == ["on-time"], "a late attach must miss finals applied before it")
    }
}

/// Thread-safe accumulator for the late-attach test above (a plain captured
/// `var` mutated inside a `Task {}` trips Swift 6's capture checker even when
/// both sides are MainActor-isolated).
private actor Received {
    private(set) var texts: [String] = []
    func append(_ segment: Segment) { texts.append(segment.text) }
}
