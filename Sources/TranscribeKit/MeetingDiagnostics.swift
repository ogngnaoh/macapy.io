import CaptureKit
import Foundation

/// Cumulative duration of audio handed to STT, kept independently per source.
/// A shared/global sum would double-count simultaneous mic and system audio and
/// let one source's future audio move the other's event anchor forward.
public final class FedAudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var secondsBySource: [AudioSource: TimeInterval] = [:]

    public init() {}

    /// O(1), allocation-free after the two source keys exist, and never
    /// retains the audio buffer. Intended for the real fan-out tap.
    public func record(_ chunk: AudioChunk, source: AudioSource) {
        let sampleRate = chunk.buffer.format.sampleRate
        guard sampleRate > 0 else { return }
        let duration = Double(chunk.buffer.frameLength) / sampleRate
        guard duration.isFinite, duration >= 0 else { return }
        lock.withLock { secondsBySource[source, default: 0] += duration }
    }

    public func seconds(for source: AudioSource) -> TimeInterval {
        lock.withLock { secondsBySource[source, default: 0] }
    }

    /// Prevents a forward-looking STT `tEnd` from creating an impossible
    /// latency while preserving a source's own session-relative timeline.
    public func clampedEventEnd(_ tEnd: TimeInterval, source: AudioSource) -> TimeInterval {
        min(max(tEnd, 0), seconds(for: source))
    }
}

/// Lock-protected count of transcription stream failures for one meeting.
/// Error values are intentionally not retained: provider/transcript content
/// can appear in descriptions, while diagnostics needs only the count.
public final class STTErrorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    public init() {}

    public func increment() {
        lock.withLock { value += 1 }
    }

    public var count: Int {
        lock.withLock { value }
    }
}
