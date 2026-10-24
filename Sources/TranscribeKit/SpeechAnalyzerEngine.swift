import AVFoundation
import CaptureKit
import Foundation
import Speech
import os

/// Asset installation is a setup operation. Meeting capture and model tests
/// can require existing assets without invoking any installation request.
public enum SpeechAssetInstallationPolicy: Sendable {
    case allowDownload
    case installedOnly
}

/// `STTEngine` backed by Apple's on-device `SpeechAnalyzer` (macOS 26+). One
/// `SpeechTranscriber` + `SpeechAnalyzer` pair is created per `transcribe()`
/// call (per meeting/source); "stop meeting" is just "finish the capture
/// stream", after which the engine finalizes and the transcript tail arrives
/// naturally.
public struct SpeechAnalyzerEngine: STTEngine {
    private let locale: Locale
    private let assetInstallationPolicy: SpeechAssetInstallationPolicy
    private static let log = Logger(subsystem: "io.macapy.app", category: "SpeechAnalyzerEngine")

    public init(
        locale: Locale = .current,
        assetInstallationPolicy: SpeechAssetInstallationPolicy = .allowDownload
    ) {
        self.locale = locale
        self.assetInstallationPolicy = assetInstallationPolicy
    }

    private func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        Self.makeTranscriber(locale)
    }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Read-only readiness check; never requests installation or downloads.
    public static func assetsAreInstalled(locale: Locale) async -> Bool {
        await AssetInventory.status(forModules: [makeTranscriber(locale)]) == .installed
    }

    public func prepare(locale: Locale) async throws {
        let wanted = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == wanted }) else {
            throw TranscribeError.localeUnsupported(locale)
        }

        do {
            try await Self.prepareAssets(
                locale: locale,
                policy: assetInstallationPolicy,
                isInstalled: { await Self.assetsAreInstalled(locale: locale) },
                install: {
                    let transcriber = Self.makeTranscriber(locale)
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        try await request.downloadAndInstall()
                    }
                }
            )
        } catch {
            throw TranscribeError.assetsUnavailable(locale, underlying: error)
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    /// Dependency seam verifies that the installed-only policy cannot reach
    /// the download closure, even when assets are absent or being removed.
    static func prepareAssets(
        locale: Locale,
        policy: SpeechAssetInstallationPolicy,
        isInstalled: () async -> Bool,
        install: () async throws -> Void
    ) async throws {
        switch policy {
        case .installedOnly:
            guard await isInstalled() else {
                throw TranscribeError.assetsUnavailable(locale, underlying: nil)
            }
        case .allowDownload:
            try await install()
        }
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
                            let segment = Segment(
                                id: UUID(), source: source, text: text, tStart: tStart, tEnd: tEnd
                            )
                            for event in Self.events(forFinal: segment) {
                                continuation.yield(event)
                            }
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
                    Self.log.error("transcription failed: \(String(describing: type(of: error)), privacy: .public)")
                    continuation.finish(throwing: TranscribeError.analyzerFailed(underlying: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Apple final results are the MVP turn boundary. Keep this small policy
    /// separate from analyzer plumbing so final → turn-ended ordering and the
    /// empty-result exception are deterministic and directly testable.
    static func events(forFinal segment: Segment) -> [TranscriptEvent] {
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [.final(segment)]
        }
        return [.final(segment), .turnEnded]
    }
}
