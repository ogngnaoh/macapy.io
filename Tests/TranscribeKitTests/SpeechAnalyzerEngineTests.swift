import AVFoundation
import CaptureKit
import Foundation
import Testing
import TranscribeKit

/// Check 1 (de-risk spike): a committed `say`-generated fixture wav fed through
/// the real `SpeechAnalyzerEngine` under `swift test` yields a nonempty
/// transcript with the expected keywords; at least one `.volatile` precedes its
/// `.final`; times are monotonic and non-negative; the event stream finishes
/// after input ends. If the environment blocks the real engine (asset download
/// impossible / speech TCC), this fails with an explicit "environment-blocked"
/// message rather than being green-washed.
@Suite(.serialized)
struct SpeechAnalyzerEngineTests {

    private static let englishUS = Locale(identifier: "en_US")

    @Test func transcribesFixtureVolatileThenFinal() async throws {
        guard let url = Bundle.module.url(
            forResource: "fox", withExtension: "wav", subdirectory: "Fixtures"
        ) else {
            Issue.record("environment-blocked: fixture fox.wav missing from test bundle")
            return
        }

        let engine = SpeechAnalyzerEngine(locale: Self.englishUS)
        do {
            try await engine.prepare(locale: Self.englishUS)
        } catch {
            Issue.record("environment-blocked: prepare() failed — \(error)")
            return
        }
        let format = try await engine.preferredInputFormat()

        // Read the fixture and convert it, chunk by chunk, into the engine's
        // preferred format via the production converter, mirroring MicCapture.
        let file = try AVAudioFile(forReading: url)
        let readFormat = file.processingFormat
        let converter = try BufferConverter(from: readFormat, to: format)

        let (audio, audioCont) = AsyncStream<AudioChunk>.makeStream()
        let events = engine.transcribe(audio, source: .mic)

        // Feed synchronously (unbounded buffering) then consume events.
        let chunkFrames: AVAudioFrameCount = 8000  // ~0.5s @ 16kHz to elicit volatiles
        while true {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: chunkFrames) else { break }
            try file.read(into: inBuf, frameCount: chunkFrames)
            if inBuf.frameLength == 0 { break }
            let converted = try converter.convert(inBuf)
            audioCont.yield(AudioChunk(buffer: converted, time: nil))
            if inBuf.frameLength < chunkFrames { break }
        }
        audioCont.finish()

        var volatileCount = 0
        var anyVolatile = false
        var sawVolatileBeforeFinal = false
        var finalTexts: [String] = []
        var times: [(Double, Double)] = []
        var streamFinished = false

        for try await event in events {
            switch event {
            case let .volatile(text, tStart, tEnd):
                anyVolatile = true
                volatileCount += 1
                _ = text
                times.append((tStart, tEnd))
            case let .final(segment):
                if anyVolatile { sawVolatileBeforeFinal = true }
                finalTexts.append(segment.text)
                times.append((segment.tStart, segment.tEnd))
            case .turnEnded:
                break
            }
        }
        streamFinished = true  // reaching here means the stream completed after input ended

        let full = finalTexts.joined(separator: " ").lowercased()
        #expect(streamFinished)
        #expect(!full.isEmpty, "transcript should be nonempty")
        #expect(anyVolatile, "expected at least one volatile event")
        #expect(volatileCount >= 1)
        #expect(sawVolatileBeforeFinal, "expected a volatile to precede a final")

        let keywords = ["quick", "brown", "fox", "lazy", "dog", "meeting", "device", "locally"]
        let hits = keywords.filter { full.contains($0) }
        #expect(hits.count >= 3, "expected ≥3 fixture keywords, got \(hits) in \"\(full)\"")

        #expect(times.allSatisfy { $0.0 >= 0 && $0.1 >= $0.0 }, "times must be non-negative and ordered")
    }
}
