import AVFoundation
import Foundation

/// Per-chunk level arithmetic for the signal strip (slice-4 decision 5).
public enum AudioLevel {
    /// RMS of the first channel, normalized to 0...1 full-scale. Int16 and
    /// Float32 mono are the two formats this pipeline produces (the analyzer's
    /// negotiated format and the tap's native float, respectively); anything
    /// else reads as silence rather than guessing.
    public static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        if let int16 = buffer.int16ChannelData {
            let channel = int16[0]
            var sum: Double = 0
            for i in 0..<frames {
                let sample = Double(channel[i]) / 32_768
                sum += sample * sample
            }
            return Float((sum / Double(frames)).squareRoot())
        }
        if let float = buffer.floatChannelData {
            let channel = float[0]
            var sum: Double = 0
            for i in 0..<frames {
                let sample = Double(channel[i])
                sum += sample * sample
            }
            return Float((sum / Double(frames)).squareRoot())
        }
        return 0
    }
}

/// Latest per-source signal level, written by the fan-out's `onChunk` tap and
/// polled by the signal strip at UI cadence. Lock-protected class, not an
/// actor: the writer is a hot loop and the reader is a 100ms poll — neither
/// wants suspension (the `LatencyRecorder` pattern).
public final class SignalLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var levels: [AudioSource: Float] = [:]

    public init() {}

    public func record(source: AudioSource, level: Float) {
        lock.withLock { levels[source] = level }
    }

    /// 0 when the source has produced nothing (idle reads as silence).
    public func level(for source: AudioSource) -> Float {
        lock.withLock { levels[source] ?? 0 }
    }

    public func reset() {
        lock.withLock { levels.removeAll() }
    }
}
