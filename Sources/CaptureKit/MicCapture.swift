import AVFoundation
import os

/// Microphone capture via `AVAudioEngine`. Installs a tap on the input node at
/// its native format, converts each buffer to the requested format on the audio
/// thread, and yields `AudioChunk`s. An actor so start/stop/pause are
/// serialized; the tap block itself runs on a real-time audio thread and never
/// touches actor state — only the (Sendable) stream continuation and a boxed,
/// audio-thread-only converter.
public actor MicCapture: AudioCaptureSource {
    public nonisolated let source: AudioSource = .mic

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var tapInstalled = false
    private let log = Logger(subsystem: "io.macapy.app", category: "MicCapture")

    public init() {}

    public func start(format: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        let converter = try BufferConverter(from: nativeFormat, to: format)

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        // The tap block runs on a real-time audio thread, not the actor
        // executor. It only reads the boxed converter (whose sole user is this
        // thread) and yields to the Sendable continuation — no actor state, no
        // `self`. The converter allocates a fresh buffer per call, so the tap's
        // own reused buffer is never handed downstream (AudioChunk rule).
        let box = ConverterBox(converter)
        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { buffer, _ in
            guard let converted = try? box.converter.convert(buffer) else { return }
            continuation.yield(AudioChunk(buffer: converted, time: nil))
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            continuation.finish()
            self.continuation = nil
            log.error("AVAudioEngine start failed: \(error.localizedDescription)")
            throw CaptureError.engineStartFailed(underlying: error)
        }
        return stream
    }

    public func pause() async {
        engine.pause()
    }

    public func resume() async {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    public func stop() async {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    /// Carries the non-Sendable converter across the `@Sendable` tap boundary.
    /// The audio thread is its only user.
    private final class ConverterBox: @unchecked Sendable {
        let converter: BufferConverter
        init(_ converter: BufferConverter) { self.converter = converter }
    }
}
