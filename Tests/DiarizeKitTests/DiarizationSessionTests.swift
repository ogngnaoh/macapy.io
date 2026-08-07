import AVFoundation
import CaptureKit
import DiarizeKit
import Foundation
import Testing

/// Session-layer logic with a scripted engine (no models): first-appearance
/// S-labels, incremental live attribution that never flips, and a finalize
/// summary independent of event ordering.
struct DiarizationSessionTests {

    /// Emits pre-scripted turns: one batch per `ingest` call, in order, then
    /// the `tail` batch (+ embeddings) at `finish`.
    private actor ScriptedEngine: DiarizationEngine {
        private var batches: [[SpeakerTurn]]
        private let tail: [SpeakerTurn]
        private let tailEmbeddings: [String: Data]

        init(batches: [[SpeakerTurn]], tail: [SpeakerTurn] = [], tailEmbeddings: [String: Data] = [:]) {
            self.batches = batches
            self.tail = tail
            self.tailEmbeddings = tailEmbeddings
        }

        func ingest(_ chunk: AudioChunk) async throws -> [SpeakerTurn] {
            batches.isEmpty ? [] : batches.removeFirst()
        }

        func finish() async throws -> (turns: [SpeakerTurn], embeddings: [String: Data]) {
            (tail, tailEmbeddings)
        }
    }

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private func anyChunk() -> AudioChunk {
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 8)!
        buffer.frameLength = 8
        return AudioChunk(buffer: buffer, time: nil)
    }

    @Test func labelsFollowFirstAppearanceOrder() async throws {
        // Key "zz" speaks first, so it gets S1 despite sorting after "aa".
        let session = DiarizationSession(
            engine: ScriptedEngine(batches: [
                [SpeakerTurn(speakerKey: "zz", tStart: 0, tEnd: 5)],
                [SpeakerTurn(speakerKey: "aa", tStart: 5, tEnd: 10)],
            ]))
        _ = try await session.ingest(anyChunk())
        _ = try await session.ingest(anyChunk())

        let result = try await session.finalize()
        #expect(result.speakers.map(\.key) == ["zz", "aa"])
        #expect(result.speakers.map(\.label) == ["S1", "S2"])
    }

    @Test func finalArrivingAfterItsTurnsAttributesImmediately() async throws {
        let session = DiarizationSession(
            engine: ScriptedEngine(batches: [
                [SpeakerTurn(speakerKey: "v1", tStart: 0, tEnd: 6)]
            ]))
        _ = try await session.ingest(anyChunk())

        let segmentID = UUID()
        let live = await session.noteFinal(segmentID: segmentID, tStart: 1, tEnd: 5)
        #expect(live == [LiveAttribution(segmentID: segmentID, label: "S1")])
    }

    @Test func finalArrivingBeforeItsTurnsAttributesWhenTheWindowFlushes() async throws {
        let session = DiarizationSession(
            engine: ScriptedEngine(batches: [
                [SpeakerTurn(speakerKey: "v1", tStart: 0, tEnd: 6)]
            ]))

        let segmentID = UUID()
        let early = await session.noteFinal(segmentID: segmentID, tStart: 1, tEnd: 5)
        #expect(early.isEmpty)  // no turns yet

        let live = try await session.ingest(anyChunk())
        #expect(live == [LiveAttribution(segmentID: segmentID, label: "S1")])
    }

    @Test func liveAttributionIsEmittedExactlyOnce() async throws {
        let session = DiarizationSession(
            engine: ScriptedEngine(batches: [
                [SpeakerTurn(speakerKey: "v1", tStart: 0, tEnd: 6)],
                [SpeakerTurn(speakerKey: "v1", tStart: 6, tEnd: 12)],
            ]))
        _ = try await session.ingest(anyChunk())

        let segmentID = UUID()
        let first = await session.noteFinal(segmentID: segmentID, tStart: 1, tEnd: 5)
        #expect(first.count == 1)

        // More turns arrive; the already-labeled segment must not re-emit.
        let second = try await session.ingest(anyChunk())
        #expect(second.isEmpty)
    }

    @Test func finalizeRecomputesOverEverythingAndCarriesEmbeddings() async throws {
        let embedding = Data([9, 9, 9])
        let session = DiarizationSession(
            engine: ScriptedEngine(
                batches: [[SpeakerTurn(speakerKey: "v1", tStart: 0, tEnd: 4)]],
                tail: [SpeakerTurn(speakerKey: "v2", tStart: 4, tEnd: 9)],
                tailEmbeddings: ["v1": embedding]
            ))
        let early = UUID()
        let late = UUID()
        _ = try await session.ingest(anyChunk())
        _ = await session.noteFinal(segmentID: early, tStart: 0, tEnd: 4)
        // This one is only covered by the tail turns finalize() flushes.
        _ = await session.noteFinal(segmentID: late, tStart: 5, tEnd: 9)

        let result = try await session.finalize()
        #expect(result.assignments == [early: "v1", late: "v2"])
        #expect(result.speakers == [
            MeetingDiarization.Speaker(key: "v1", label: "S1", embedding: embedding),
            MeetingDiarization.Speaker(key: "v2", label: "S2", embedding: nil),
        ])
    }
}
