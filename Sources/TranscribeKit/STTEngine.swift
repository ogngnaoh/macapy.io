import AVFoundation
import CaptureKit
import Foundation

/// On-device streaming speech-to-text. One implementation in v1
/// (`SpeechAnalyzerEngine`); the protocol is the escape hatch for a fallback
/// engine (SPEC N1). Amended vs SPEC §6.3: `prepare(locale:)` (asset
/// check/install, before capture) and `preferredInputFormat()` (the analyzer's
/// format must be queried, not assumed 16kHz).
public protocol STTEngine: Sendable {
    /// Ensures the locale's model assets are available. May download once.
    func prepare(locale: Locale) async throws

    /// The audio format the engine wants its input converted to.
    func preferredInputFormat() async throws -> AVAudioFormat

    /// Transcribes `audio` until it finishes, then finalizes and ends the event
    /// stream. Errors surface via the stream's terminal `finish(throwing:)`.
    func transcribe(_ audio: AsyncStream<AudioChunk>, source: AudioSource)
        -> AsyncThrowingStream<TranscriptEvent, Error>
}
