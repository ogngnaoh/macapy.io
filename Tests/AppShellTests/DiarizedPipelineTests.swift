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

    /// Emits one scripted final per source, then ends its event stream.
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
                    for await _ in audio {}  // keep the branch drained
                }
                for segment in events {
                    continuation.yield(.final(segment))
                }
                continuation.finish()
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
            makeDiarizer: { DiarizationSession(engine: engine) }
        )

        try await pipeline.start(mode: .persistent(meetingStore))
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
            makeDiarizer: { DiarizationSession(engine: engine) }
        )

        try await pipeline.start(mode: .persistent(meetingStore))
        let meetingID = try #require(await pipeline.stop())

        let speakers = try await meetingStore.speakers(for: meetingID)
        #expect(speakers.map(\.label) == ["S1", "S2"])
        #expect(speakers.map(\.embedding) == [Data([1]), Data([2])])

        let attributed = try await meetingStore.attributedSegments(for: meetingID)
        #expect(attributed.map(\.speakerLabel) == ["S1", "S2"])
    }

    @Test func stopCompletingDuringDiarizerConstructionOrphansNothing() async throws {
        // Fresh-context critic finding: the detached session construction is a
        // multi-second window; a stop() that runs to completion inside it must
        // not leave the just-built session (a live CoreML load in production)
        // alive past teardown. The weak box is the leak oracle.
        final class Gate: @unchecked Sendable {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            weak var builtSession: DiarizationSession?
            private let lock = NSLock()
            func noteBuilt(_ session: DiarizationSession) {
                lock.withLock { builtSession = session }
            }
            // Sync wrapper: DispatchSemaphore.wait() is unavailable directly
            // in async contexts; the detached task calls this instead.
            func waitUntilEntered() { entered.wait() }
        }
        let gate = Gate()
        let store = TranscriptStore()
        let meetingStore = MeetingStore(database: try MacapyDatabase.inMemory())
        let engine = ScriptedDiarizationEngine(turnBatches: [])
        let pipeline = MeetingPipeline(
            engine: ScriptedFinalsEngine(finals: [:]),
            sources: [ScriptedSource(source: .system, chunkCount: 0)],
            store: store,
            makeDiarizer: {
                gate.entered.signal()
                gate.release.wait()  // holds the detached thread, not an actor
                let session = DiarizationSession(engine: engine)
                gate.noteBuilt(session)
                return session
            }
        )

        let startTask = Task { try await pipeline.start(mode: .persistent(meetingStore)) }
        // Wait (off the main actor) until start() is provably suspended inside
        // the factory, then let stop() run to full completion.
        await Task.detached { gate.waitUntilEntered() }.value
        _ = await pipeline.stop()

        gate.release.signal()
        try await startTask.value
        await Task.yield()

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
            makeDiarizer: { throw Boom() }
        )

        try await pipeline.start(mode: .persistent(meetingStore))
        let meetingID = try #require(await pipeline.stop())

        // Transcript intact, zero speakers, zero labels — an M1 meeting.
        #expect(store.segments == [segment])
        #expect(store.speakerLabels.isEmpty)
        #expect(try await meetingStore.speakers(for: meetingID).isEmpty)
    }
}
