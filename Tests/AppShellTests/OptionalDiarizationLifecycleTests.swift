import AVFoundation
import CaptureKit
import DiarizeKit
import Foundation
import PersistKit
import Testing
import TranscribeKit

@testable import AppShell

@MainActor
struct OptionalDiarizationLifecycleTests {
    final class FactoryGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var opened = false
        private var entered = false
        func wait() {
            condition.lock()
            entered = true
            while !opened { condition.wait() }
            condition.unlock()
        }
        func release() { condition.lock(); opened = true; condition.broadcast(); condition.unlock() }
        var hasEntered: Bool { condition.lock(); defer { condition.unlock() }; return entered }
        var isClosed: Bool { condition.lock(); defer { condition.unlock() }; return !opened }
    }

    actor Gate {
        var entered = false
        private var released = false
        var isClosed: Bool { !released }
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    actor Engine: DiarizationEngine {
        let ingestGate: Gate?
        let finishGate: Gate?
        init(ingest: Gate? = nil, finish: Gate? = nil) { ingestGate = ingest; finishGate = finish }
        func ingest(_ chunk: AudioChunk) async throws -> [SpeakerTurn] {
            await ingestGate?.wait() // Deliberately ignores task cancellation.
            return [.init(speakerKey: "fixture-voice", tStart: 0, tEnd: 10)]
        }
        func finish() async throws -> (turns: [SpeakerTurn], embeddings: [String: Data]) {
            await finishGate?.wait() // Deliberately ignores task cancellation.
            return ([.init(speakerKey: "fixture-voice", tStart: 0, tEnd: 10)], [:])
        }
    }

    actor Source: AudioCaptureSource {
        nonisolated let source: AudioSource = .system
        private let initialChunks: Int
        private var continuation: AsyncStream<AudioChunk>.Continuation?
        var starts = 0
        init(initialChunks: Int = 1) { self.initialChunks = initialChunks }
        func start(format: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
            starts += 1
            let made = AsyncStream<AudioChunk>.makeStream()
            continuation = made.continuation
            for _ in 0..<initialChunks {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
                buffer.frameLength = 160
                buffer.int16ChannelData![0].initialize(repeating: 0, count: 160)
                made.continuation.yield(AudioChunk(buffer: buffer))
            }
            return made.stream
        }
        func stop() { continuation?.finish(); continuation = nil }
        func pause() {}
        func resume() {}
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition(), "The deterministic fake did not reach the expected state")
    }

    private func makePipeline(
        store: TranscriptStore, source: Source, lease: OptionalDiarizationLease,
        grace: Duration = .milliseconds(40),
        make: @escaping @Sendable () throws -> DiarizationSession
    ) -> MeetingPipeline {
        let segment = Segment(id: UUID(), source: .system, text: "Fictional project checkpoint.", tStart: 1, tEnd: 2)
        let engine = MeetingPipelineTests.FakeSTTEngine(
            live: [.system: [.final(segment)]], counters: .init())
        return MeetingPipeline(engine: engine, sources: [source], store: store,
                               makeDiarizer: make, diarizationLease: lease, diarizationGrace: grace)
    }

    @Test func stalledInitializationDoesNotDelayCaptureAndLeaseOutlivesCancellation() async throws {
        let lease = OptionalDiarizationLease()
        let gate = FactoryGate()
        defer { gate.release() }
        // This is failure cleanup, not a performance assertion. Leave enough
        // headroom for unrelated parallel UI tests on a shared CI runner.
        let watchdog = Task.detached { try? await Task.sleep(for: .seconds(30)); gate.release() }
        defer { watchdog.cancel() }
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let store = TranscriptStore()
        let source = Source()
        let first = makePipeline(store: store, source: source, lease: lease) {
            gate.wait(); return DiarizationSession(engine: Engine())
        }
        var unavailable = 0
        first.onDiarizationUnavailable = { unavailable += 1 }
        try await first.start(mode: .persistent(meetings))
        try await waitUntil { gate.hasEntered && !store.segments.isEmpty }
        #expect(await source.starts == 1)
        // Assert the causal contract, independent of full-suite scheduling:
        // the optional factory has not completed when capture/STT are active.
        // The watchdog releases a broken blocking implementation so it fails
        // this assertion instead of leaving the entire test process hung.
        #expect(gate.isClosed)
        let id = try #require(await first.stop())
        #expect(gate.isClosed, "Stop must complete before the blocked factory is released")
        #expect(lease.isOccupied)
        #expect(try await meetings.segments(for: id).count == 1)
        #expect(try await meetings.speakers(for: id).isEmpty)
        try await waitUntil { unavailable == 1 }

        let secondSource = Source()
        let second = makePipeline(store: TranscriptStore(), source: secondSource, lease: lease) {
            Issue.record("A cancelled but still executing factory must retain its lease")
            return DiarizationSession(engine: Engine())
        }
        try await second.start(mode: .ephemeral)
        #expect(await secondSource.starts == 1)
        await second.stop()
        #expect(lease.isOccupied)
        gate.release()
        try await waitUntil { !lease.isOccupied }

        let third = makePipeline(store: TranscriptStore(), source: Source(), lease: lease) {
            DiarizationSession(engine: Engine())
        }
        try await third.start(mode: .ephemeral)
        #expect(lease.isOccupied)
        await third.stop()
        try await waitUntil { !lease.isOccupied }
    }

    @Test(arguments: [false, true])
    func uncancellableIngestOrFinalizeCannotDelayStopOrWriteLate(finalize: Bool) async throws {
        let lease = OptionalDiarizationLease()
        let gate = Gate()
        let watchdog = Task.detached { try? await Task.sleep(for: .seconds(30)); await gate.release() }
        defer { watchdog.cancel() }
        let engine = Engine(ingest: finalize ? nil : gate, finish: finalize ? gate : nil)
        let store = TranscriptStore()
        let meetings = MeetingStore(database: try MacapyDatabase.inMemory())
        let pipeline = makePipeline(store: store, source: Source(), lease: lease) { DiarizationSession(engine: engine) }
        try await pipeline.start(mode: .persistent(meetings))
        try await waitUntil { !store.segments.isEmpty }
        if !finalize { try await waitUntil { await gate.entered } }
        let id = try #require(await pipeline.stop())
        #expect(await gate.isClosed, "Stop must complete before the blocked engine is released")
        #expect(lease.isOccupied)
        #expect(await gate.entered)
        store.reset()
        let next = Segment(id: UUID(), source: .system, text: "A separate fictional meeting.", tStart: 1, tEnd: 2)
        store.apply(.final(next), from: .system)
        await gate.release()
        try await waitUntil { !lease.isOccupied }
        #expect(store.speakerLabels.isEmpty)
        #expect(store.segments == [next])
        #expect(try await meetings.speakers(for: id).isEmpty)
        #expect(try await meetings.attributedSegments(for: id).allSatisfy { $0.speakerID == nil })
    }

    @Test func successfulOptionalWorkLabelsAndPersistsBeforeMeetingEnds() async throws {
        let lease = OptionalDiarizationLease()
        let store = TranscriptStore()
        let meetings = MeetingStore(database: try MacapyDatabase.inMemory())
        let pipeline = makePipeline(store: store, source: Source(), lease: lease, grace: .seconds(30)) {
            DiarizationSession(engine: Engine())
        }
        try await pipeline.start(mode: .persistent(meetings))
        try await waitUntil { !store.speakerLabels.isEmpty }
        let id = try #require(await pipeline.stop())
        #expect(try await meetings.speakers(for: id).map(\.label) == ["S1"])
        #expect(try await meetings.attributedSegments(for: id).allSatisfy { $0.speakerID != nil })
        #expect(try await meetings.listMeetings().first?.status == MeetingRecord.endedStatus)
        #expect(!lease.isOccupied)
    }

    @Test func loadingOverflowDisablesOptionalLabelsButPreservesTranscript() async throws {
        let gate = FactoryGate()
        defer { gate.release() }
        let watchdog = Task.detached { try? await Task.sleep(for: .seconds(30)); gate.release() }
        defer { watchdog.cancel() }
        let lease = OptionalDiarizationLease()
        let store = TranscriptStore()
        let meetings = MeetingStore(database: try MacapyDatabase.inMemory())
        let pipeline = makePipeline(store: store, source: Source(initialChunks: 150), lease: lease) {
            gate.wait(); return DiarizationSession(engine: Engine())
        }
        var unavailable = 0
        pipeline.onDiarizationUnavailable = { unavailable += 1 }
        try await pipeline.start(mode: .persistent(meetings))
        try await waitUntil { unavailable == 1 && !store.segments.isEmpty }
        let id = try #require(await pipeline.stop())
        #expect(pipeline.droppedChunks >= 1)
        gate.release()
        try await waitUntil { !lease.isOccupied }
        #expect(unavailable == 1)
        #expect(try await meetings.segments(for: id).count == 1)
        #expect(try await meetings.speakers(for: id).isEmpty)
        #expect(store.speakerLabels.isEmpty)
    }

    @Test func finalMetadataHasIndependentBoundAndContainsNoTranscriptText() async {
        let inbox = DiarizationInbox(audioLimit: 2, finalLimit: 2)
        let first = DiarizationSegmentSnapshot(id: UUID(), tStart: 1, tEnd: 2)
        let second = DiarizationSegmentSnapshot(id: UUID(), tStart: 2, tEnd: 3)
        #expect(inbox.append(.final(first)))
        #expect(inbox.append(.final(second)))
        #expect(!inbox.append(.final(.init(id: UUID(), tStart: 3, tEnd: 4))))
        #expect(inbox.bufferedCounts.finals == 2)
        #expect(inbox.bufferedCounts.audio == 0)
        #expect(inbox.droppedAudio == 0)
        inbox.cancel()
        #expect(inbox.bufferedCounts.finals == 0)
        #expect(await inbox.next() == nil)
    }

    @Test func initializationFailureReportsOnceWhileRecordingContinues() async throws {
        enum FixtureError: Error { case unavailable }
        let store = TranscriptStore()
        let pipeline = makePipeline(store: store, source: Source(), lease: OptionalDiarizationLease()) {
            throw FixtureError.unavailable
        }
        var unavailable = 0
        pipeline.onDiarizationUnavailable = { unavailable += 1 }
        try await pipeline.start(mode: .ephemeral)
        try await waitUntil { unavailable == 1 && !store.segments.isEmpty }
        await pipeline.stop()
        #expect(unavailable == 1)
        #expect(store.segments.count == 1)
    }
}
