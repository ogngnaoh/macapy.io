import AVFoundation
import CaptureKit
import DiarizeKit
import Foundation
import PersistKit
import Testing
import TranscribeKit

@testable import AppShell

/// Slice-4 checks 4 and 8 (pipeline half): with a scripted diarizer whose
/// turns span all time, only `.system` segments are ever labeled — live map
/// and DB alike; the stop() sweep persists speakers in first-appearance order
/// with the expected assignments.
@MainActor
struct DiarizedPipelineTests {

    private func waitForLabels(_ ids: [UUID], in store: TranscriptStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !ids.allSatisfy({ store.speakerLabels[$0] != nil }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ids.allSatisfy { store.speakerLabels[$0] != nil })
    }

    /// Emits scripted finals, then drains until capture stops. A natural live
    /// EOF is now correctly considered a capture/transcription interruption.
    private struct ScriptedFinalsEngine: STTEngine {
        let finals: [AudioSource: [Segment]]

        func prepare(locale: Locale) async throws {}

        func preferredInputFormat() async throws -> AVAudioFormat {
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        }

        func transcribe(
            _ audio: AsyncStream<AudioChunk>, source: AudioSource
        ) -> AsyncThrowingStream<TranscriptEvent, Error> {
            let events = finals[source] ?? []
            return AsyncThrowingStream { continuation in
                let drain = Task {
                    for segment in events { continuation.yield(.final(segment)) }
                    for await _ in audio {}
                    continuation.finish()
                }
                continuation.onTermination = { _ in drain.cancel() }
            }
        }
    }

    /// Scripted turns on the first ingest; scripted embeddings at finish.
    private actor ScriptedDiarizationEngine: DiarizationEngine {
        private var turnBatches: [[SpeakerTurn]]
        private let embeddings: [String: Data]

        init(turnBatches: [[SpeakerTurn]], embeddings: [String: Data] = [:]) {
            self.turnBatches = turnBatches
            self.embeddings = embeddings
        }

        func ingest(_ chunk: AudioChunk) async throws -> [SpeakerTurn] {
            turnBatches.isEmpty ? [] : turnBatches.removeFirst()
        }

        func finish() async throws -> (turns: [SpeakerTurn], embeddings: [String: Data]) {
            ([], embeddings)
        }
    }

    private actor ScriptedSource: AudioCaptureSource {
        nonisolated let source: AudioSource
        private let chunkCount: Int
        private var continuation: AsyncStream<AudioChunk>.Continuation?

        init(source: AudioSource, chunkCount: Int) {
            self.source = source
            self.chunkCount = chunkCount
        }

        func start(format: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
            let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
            self.continuation = continuation
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
            buffer.frameLength = 8
            for _ in 0..<chunkCount {
                continuation.yield(AudioChunk(buffer: buffer, time: nil))
            }
            return stream
        }

        func pause() async {}
        func resume() async {}

        func stop() async {
            continuation?.finish()
            continuation = nil
        }
    }

    @Test func onlySystemSegmentsAreLabeledLiveAndInTheDatabase() async throws {
        let micSegment = Segment(id: UUID(), source: .mic, text: "mine", tStart: 1, tEnd: 2)
        let themA = Segment(id: UUID(), source: .system, text: "theirs A", tStart: 0, tEnd: 1)
        let themB = Segment(id: UUID(), source: .system, text: "theirs B", tStart: 3, tEnd: 4)

        let store = TranscriptStore()
        let database = try MacapyDatabase.inMemory()
        let meetingStore = MeetingStore(database: database)
        // One all-covering speaker: if attribution ever leaked to the mic
        // side, this configuration would catch it.
        let engine = ScriptedDiarizationEngine(
            turnBatches: [[SpeakerTurn(speakerKey: "v1", tStart: 0, tEnd: 100)]])
        let pipeline = MeetingPipeline(
            engine: ScriptedFinalsEngine(finals: [
                .mic: [micSegment], .system: [themA, themB],
            ]),
            sources: [
                ScriptedSource(source: .mic, chunkCount: 3),
                ScriptedSource(source: .system, chunkCount: 3),
            ],
            store: store,
            makeDiarizer: { DiarizationSession(engine: engine) },
            diarizationLease: OptionalDiarizationLease(),
            // This verifies attribution, not a shared runner's scheduling speed.
            diarizationGrace: .seconds(30)
        )

        try await pipeline.start(mode: .persistent(meetingStore))
        try await waitForLabels([themA.id, themB.id], in: store)
        let meetingID = try #require(await pipeline.stop())

        // Live map: them-only (check 4).
        #expect(store.speakerLabels[themA.id] == "S1")
        #expect(store.speakerLabels[themB.id] == "S1")
        #expect(store.speakerLabels[micSegment.id] == nil)

        // DB sweep: them attributed, mic NULL (checks 4 + 8).
        let attributed = try await meetingStore.attributedSegments(for: meetingID)
        let byID = Dictionary(uniqueKeysWithValues: attributed.map { ($0.segment.id, $0) })
        #expect(byID[themA.id]?.speakerLabel == "S1")
        #expect(byID[themB.id]?.speakerLabel == "S1")
        #expect(byID[micSegment.id]?.speakerLabel == nil)
        #expect(byID[micSegment.id]?.speakerID == nil)
    }

    @Test func sweepPersistsSpeakersInFirstAppearanceOrderWithEmbeddings() async throws {
        let early = Segment(id: UUID(), source: .system, text: "early", tStart: 0, tEnd: 4)
        let late = Segment(id: UUID(), source: .system, text: "late", tStart: 5, tEnd: 9)

        let store = TranscriptStore()
        let meetingStore = MeetingStore(database: try MacapyDatabase.inMemory())
        // Key "zz" speaks first → S1 despite sorting after "aa".
        let engine = ScriptedDiarizationEngine(
            turnBatches: [[
                SpeakerTurn(speakerKey: "zz", tStart: 0, tEnd: 4.5),
                SpeakerTurn(speakerKey: "aa", tStart: 4.5, tEnd: 10),
            ]],
            embeddings: ["zz": Data([1]), "aa": Data([2])]
        )
        let pipeline = MeetingPipeline(
            engine: ScriptedFinalsEngine(finals: [.system: [early, late]]),
            sources: [ScriptedSource(source: .system, chunkCount: 2)],
            store: store,
            makeDiarizer: { DiarizationSession(engine: engine) },
            diarizationLease: OptionalDiarizationLease(),
            diarizationGrace: .seconds(30)
        )

        try await pipeline.start(mode: .persistent(meetingStore))
        try await waitForLabels([early.id, late.id], in: store)
        let meetingID = try #require(await pipeline.stop())

        let speakers = try await meetingStore.speakers(for: meetingID)
        #expect(speakers.map(\.label) == ["S1", "S2"])
        #expect(speakers.map(\.embedding) == [Data([1]), Data([2])])

        let attributed = try await meetingStore.attributedSegments(for: meetingID)
        #expect(attributed.map(\.speakerLabel) == ["S1", "S2"])
    }

    @Test func stopCompletingDuringDiarizerConstructionOrphansNothing() async throws {
        // Capture starts independently of a blocked optional construction.
        // Stop has a bounded grace, but the lease remains occupied until the
        // underlying worker actually exits. Its late session is never adopted.
        final class Gate: @unchecked Sendable {
            let release = DispatchSemaphore(value: 0)
            private var entered = false
            private weak var session: DiarizationSession?
            private let lock = NSLock()
            var hasEntered: Bool { lock.withLock { entered } }
            func noteEntered() { lock.withLock { entered = true } }
            var builtSession: DiarizationSession? { lock.withLock { session } }
            func noteBuilt(_ session: DiarizationSession) {
                lock.withLock { self.session = session }
            }
        }
        let gate = Gate()
        defer { gate.release.signal() }
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(30))
            gate.release.signal()
        }
        defer { watchdog.cancel() }
        let lease = OptionalDiarizationLease()
        let store = TranscriptStore()
        let meetingStore = MeetingStore(database: try MacapyDatabase.inMemory())
        let engine = ScriptedDiarizationEngine(turnBatches: [])
        let pipeline = MeetingPipeline(
            engine: ScriptedFinalsEngine(finals: [:]),
            sources: [ScriptedSource(source: .system, chunkCount: 0)],
            store: store,
            makeDiarizer: {
                gate.noteEntered()
                gate.release.wait()  // holds the detached thread, not an actor
                let session = DiarizationSession(engine: engine)
                gate.noteBuilt(session)
                return session
            },
            diarizationLease: lease
        )

        let startTask = Task { try await pipeline.start(mode: .persistent(meetingStore)) }
        defer { startTask.cancel() }
        // Wait for actual factory entry without blocking another executor
        // thread while the intentionally blocked factory occupies one already.
        let readinessDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !gate.hasEntered && ContinuousClock.now < readinessDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(gate.hasEntered)
        _ = await pipeline.stop()
        #expect(lease.isOccupied)

        gate.release.signal()
        try await startTask.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while lease.isOccupied && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!lease.isOccupied)

        // The session built after stop() completed was dropped, not adopted.
        #expect(gate.builtSession == nil)
        #expect(store.speakerLabels.isEmpty)
    }

    @Test func failingDiarizerFactoryDegradesToAPlainMeeting() async throws {
        struct Boom: Error {}
        let segment = Segment(id: UUID(), source: .system, text: "still here", tStart: 0, tEnd: 1)
        let store = TranscriptStore()
        let meetingStore = MeetingStore(database: try MacapyDatabase.inMemory())
        let pipeline = MeetingPipeline(
            engine: ScriptedFinalsEngine(finals: [.system: [segment]]),
            sources: [ScriptedSource(source: .system, chunkCount: 2)],
            store: store,
            makeDiarizer: { throw Boom() },
            diarizationLease: OptionalDiarizationLease()
        )

        try await pipeline.start(mode: .persistent(meetingStore))
        let meetingID = try #require(await pipeline.stop())

        // Transcript intact, zero speakers, zero labels — an M1 meeting.
        #expect(store.segments == [segment])
        #expect(store.speakerLabels.isEmpty)
        #expect(try await meetingStore.speakers(for: meetingID).isEmpty)
    }
}
