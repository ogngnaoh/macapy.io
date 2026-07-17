import AVFoundation

/// A source of PCM audio chunks, already converted to the caller's requested
/// format. `pause()`/`resume()` ship now (slice 2) even though the hotkey that
/// drives them arrives in slice 4 — retrofitting the protocol after slice 3's
/// process-tap conformance would be a breaking change.
public protocol AudioCaptureSource: Sendable {
    var source: AudioSource { get }

    /// Starts capture and returns a stream of chunks already converted to
    /// `format`. The stream finishes when `stop()` is called.
    func start(format: AVAudioFormat) async throws -> AsyncStream<AudioChunk>

    func pause() async
    func resume() async
    func stop() async
}
