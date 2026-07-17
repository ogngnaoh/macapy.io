import AVFoundation
import CaptureKit
import Foundation
import Speech
import os

/// `STTEngine` backed by Apple's on-device `SpeechAnalyzer` (macOS 26+). One
/// `SpeechTranscriber` + `SpeechAnalyzer` pair is created per `transcribe()`
/// call (per meeting/source); "stop meeting" is just "finish the capture
/// stream", after which the engine finalizes and the transcript tail arrives
/// naturally.
public struct SpeechAnalyzerEngine: STTEngine {
    private let locale: Locale
    private static let log = Logger(subsystem: "io.macapy.app", category: "SpeechAnalyzerEngine")

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    private func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    public func prepare(locale: Locale) async throws {
        let wanted = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == wanted }) else {
            throw TranscribeError.localeUnsupported(locale)
        }

        let transcriber = makeTranscriber(locale)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscribeError.assetsUnavailable(locale, underlying: error)
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    public func preferredInputFormat() async throws -> AVAudioFormat {
        let transcriber = makeTranscriber(locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscribeError.assetsUnavailable(locale, underlying: nil)
        }
        return format
    }

    public func transcribe(
        _ audio: AsyncStream<AudioChunk>, source: AudioSource
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let transcriber = makeTranscriber(locale)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

                // Consume results concurrently with feeding (mirrors the
                // validated de-risk spike ordering).
                let resultsTask = Task {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        let range = result.range
                        let start = range.start.seconds
                        let end = range.end.seconds
                        let tStart = start.isFinite ? Swift.max(0, start) : 0
                        let tEnd = end.isFinite ? Swift.max(tStart, end) : tStart
                        if result.isFinal {
                            continuation.yield(.final(Segment(
                                id: UUID(), source: source, text: text, tStart: tStart, tEnd: tEnd)))
                        } else {
                            continuation.yield(.volatile(text: text, tStart: tStart, tEnd: tEnd))
                        }
                    }
                }
                defer { resultsTask.cancel() }

                do {
                    try await analyzer.start(inputSequence: inputSequence)
                    for await chunk in audio {
                        inputBuilder.yield(AnalyzerInput(buffer: chunk.buffer, bufferStartTime: chunk.time))
                    }
                    inputBuilder.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    try await resultsTask.value
                    continuation.finish()
                } catch {
                    inputBuilder.finish()
                    resultsTask.cancel()
                    Self.log.error("transcription failed: \(error.localizedDescription)")
                    continuation.finish(throwing: TranscribeError.analyzerFailed(underlying: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
