import AVFoundation
import CaptureKit
import Foundation
import Testing
import TranscribeKit

/// Check 2 (slice 3): two distinct fixture wavs transcribed through **two
/// concurrent** `SpeechAnalyzerEngine.transcribe()` calls both complete with
/// sane, non-cross-contaminated transcripts. This validates the dual-analyzer
/// resource assumption on real hardware — the production pipeline runs one
/// analyzer per source (mic + system) simultaneously.
///
/// File-fed only (no mic/system TCC, no tap): the real system-audio path is
/// user-walked in the live checks. If the environment blocks the real engine,
/// this fails with an explicit "environment-blocked" message rather than being
/// green-washed.
struct ConcurrentEngineTests {

    private static let englishUS = Locale(identifier: "en_US")

    private struct Transcript {
        let full: String
        let finished: Bool
    }

    /// Reads a fixture, converts it chunk-by-chunk into the engine's preferred
    /// format (mirroring the capture path), feeds it through one `transcribe()`
    /// call, and returns the concatenated finals. Runs entirely within its own
    /// async context so two of these overlap under `async let`.
    private func run(
        _ engine: SpeechAnalyzerEngine,
        format: AVAudioFormat,
        resource: String,
        source: AudioSource
    ) async throws -> Transcript {
        guard let url = Bundle.module.url(
            forResource: resource, withExtension: "wav", subdirectory: "Fixtures"
        ) else {
            throw TranscribeError.assetsUnavailable(Self.englishUS, underlying: nil)
        }

        let file = try AVAudioFile(forReading: url)
        let readFormat = file.processingFormat
        let converter = try BufferConverter(from: readFormat, to: format)

        let (audio, audioCont) = AsyncStream<AudioChunk>.makeStream()
        let events = engine.transcribe(audio, source: source)

        let chunkFrames: AVAudioFrameCount = 8000
        while true {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: chunkFrames) else { break }
            try file.read(into: inBuf, frameCount: chunkFrames)
            if inBuf.frameLength == 0 { break }
            let converted = try converter.convert(inBuf)
            audioCont.yield(AudioChunk(buffer: converted, time: nil))
            if inBuf.frameLength < chunkFrames { break }
        }
        audioCont.finish()

        var finals: [String] = []
        var finished = false
        for try await event in events {
            if case let .final(segment) = event { finals.append(segment.text) }
        }
        finished = true
        return Transcript(full: finals.joined(separator: " ").lowercased(), finished: finished)
    }

    @Test func twoConcurrentAnalyzersBothTranscribeWithoutCrosstalk() async throws {
        let engine = SpeechAnalyzerEngine(locale: Self.englishUS)
        do {
            try await engine.prepare(locale: Self.englishUS)
        } catch {
            Issue.record("environment-blocked: prepare() failed — \(error)")
            return
        }
        let format = try await engine.preferredInputFormat()

        // Run both transcriptions concurrently — two analyzers live at once.
        async let foxAsync = run(engine, format: format, resource: "fox", source: .mic)
        async let trainAsync = run(engine, format: format, resource: "train", source: .system)

        let fox: Transcript
        let train: Transcript
        do {
            (fox, train) = try await (foxAsync, trainAsync)
        } catch {
            Issue.record("environment-blocked: concurrent transcription threw — \(error)")
            return
        }

        // Both streams finished (each analyzer finalized independently).
        #expect(fox.finished)
        #expect(train.finished)
        #expect(!fox.full.isEmpty, "fox transcript should be nonempty")
        #expect(!train.full.isEmpty, "train transcript should be nonempty")

        // Each transcript carries its own content.
        let foxKeywords = ["quick", "brown", "fox", "lazy", "dog", "meeting", "transcribed", "locally", "device"]
        let trainKeywords = ["train", "departs", "central", "station", "morning"]
        let foxHits = foxKeywords.filter { fox.full.contains($0) }
        let trainHits = trainKeywords.filter { train.full.contains($0) }
        #expect(foxHits.count >= 3, "expected ≥3 fox keywords, got \(foxHits) in \"\(fox.full)\"")
        #expect(trainHits.count >= 2, "expected ≥2 train keywords, got \(trainHits) in \"\(train.full)\"")

        // No cross-contamination: neither analyzer's output bled into the other.
        for w in ["train", "station", "central", "morning"] {
            #expect(!fox.full.contains(w), "fox transcript unexpectedly contains train word \"\(w)\": \(fox.full)")
        }
        for w in ["fox", "brown", "dog", "meeting"] {
            #expect(!train.full.contains(w), "train transcript unexpectedly contains fox word \"\(w)\": \(train.full)")
        }
    }
}
