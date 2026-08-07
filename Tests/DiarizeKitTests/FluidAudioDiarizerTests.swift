import AVFoundation
import CaptureKit
import DiarizeKit
import Foundation
import Testing

/// Test gating (slice-4 decision 6): real-model suites skip-not-fail when the
/// CoreML models aren't installed — the `LiveCredentials.hasDeepSeek`
/// precedent. Clones run green without the 129MB download.
enum DiarizationTestSupport {
    static var hasModels: Bool { DiarizationModelStore.isInstalled }

    static func fixtureURL(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    }

    /// The committed two-voice fixture's ground truth (Phase-0 gate).
    struct ScheduledTurn: Decodable {
        let speaker: String
        let tStart: Double
        let tEnd: Double
    }

    static func schedule() throws -> [ScheduledTurn] {
        try JSONDecoder().decode(
            [ScheduledTurn].self, from: Data(contentsOf: fixtureURL("schedule.json")))
    }

    /// Reads the fixture into 0.1s `AudioChunk`s — the pipeline's chunk
    /// cadence, without real-time pacing. `AVAudioFile`'s native processing
    /// format (Float32) is fine: the engine reads Float32 mono directly.
    static func chunks(of fixture: URL, chunkFrames: AVAudioFrameCount = 1_600) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: fixture)
        var chunks: [AudioChunk] = []
        while true {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)!
            try file.read(into: buffer, frameCount: chunkFrames)
            if buffer.frameLength == 0 { break }
            chunks.append(AudioChunk(buffer: buffer, time: nil))
            // Short read = EOF; reading again *at* EOF throws (.nilError) —
            // the M1 fixture-reading precedent breaks here too.
            if buffer.frameLength < chunkFrames { break }
        }
        return chunks
    }
}

/// Slice-4 check 1 [gated: models]: the two-voice `say` fixture through the
/// real chunked FluidAudio engine separates into ≥2 stable speakers matching
/// the committed schedule by majority overlap.
@Suite(.enabled(if: DiarizationTestSupport.hasModels))
struct FluidAudioDiarizerTests {

    @Test func twoVoiceFixtureSeparatesPerTheCommittedSchedule() async throws {
        let diarizer = try FluidAudioDiarizer()
        var turns: [SpeakerTurn] = []
        for chunk in try DiarizationTestSupport.chunks(
            of: DiarizationTestSupport.fixtureURL("two-voices.wav"))
        {
            turns.append(contentsOf: try await diarizer.ingest(chunk))
        }
        let (tail, embeddings) = try await diarizer.finish()
        turns.append(contentsOf: tail)

        let keys = Set(turns.map(\.speakerKey))
        #expect(keys.count >= 2)

        // Majority-overlap resolution per scheduled turn: every A-turn must
        // resolve to one key, every B-turn to another, A ≠ B.
        var majority: [String: Set<String>] = [:]
        for scheduled in try DiarizationTestSupport.schedule() {
            var overlapByKey: [String: Double] = [:]
            for turn in turns {
                let overlap = min(scheduled.tEnd, turn.tEnd) - max(scheduled.tStart, turn.tStart)
                if overlap > 0 { overlapByKey[turn.speakerKey, default: 0] += overlap }
            }
            let best = try #require(overlapByKey.max { $0.value < $1.value })
            let duration = scheduled.tEnd - scheduled.tStart
            #expect(best.value / duration > 0.5, "turn at \(scheduled.tStart)s under-covered")
            majority[scheduled.speaker, default: []].insert(best.key)
        }
        #expect(majority["A"]?.count == 1)
        #expect(majority["B"]?.count == 1)
        #expect(majority["A"] != majority["B"])

        // Embeddings ride along for schema v4's speakers.embedding.
        #expect(!embeddings.isEmpty)
    }
}
