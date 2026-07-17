import AVFoundation

/// Hardware-free PCM format + sample-rate conversion over `AVAudioConverter`.
///
/// Streaming-safe by construction: `primeMethod = .none` so chunk boundaries
/// don't drop priming samples, and every `convert(_:)` allocates a **fresh**
/// output buffer — which is what lets `AudioChunk`'s producer-never-touches rule
/// hold. Not thread-safe: one instance per capture source, driven only from that
/// source's audio thread.
public struct BufferConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    public init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.formatUnavailable
        }
        converter.primeMethod = .none
        self.converter = converter
        self.outputFormat = outputFormat
    }

    /// Converts `buffer` into a newly allocated buffer in the target format.
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CaptureError.conversionFailed(underlying: nil)
        }

        // AVAudioConverterInputBlock is `@Sendable`, though it's invoked
        // synchronously here. Box the per-call state so the closure captures a
        // single Sendable reference instead of a non-Sendable buffer + a mutated
        // `var`, which strict concurrency would flag.
        let input = InputState(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if input.consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            input.consumed = true
            inputStatus.pointee = .haveData
            return input.buffer
        }

        if let conversionError {
            throw CaptureError.conversionFailed(underlying: conversionError)
        }
        if status == .error {
            throw CaptureError.conversionFailed(underlying: nil)
        }
        return output
    }

    /// One-shot input state for a single `convert` call. `@unchecked Sendable`
    /// so it can cross the `@Sendable` input-block boundary; only ever touched
    /// synchronously within one `convert(_:)` invocation.
    private final class InputState: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var consumed = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
}
