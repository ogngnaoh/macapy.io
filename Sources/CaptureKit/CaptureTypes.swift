import AVFoundation
import CoreMedia

/// Which stream a chunk/segment came from. `mic` is "you"; `system` (slice 3)
/// is "them".
public enum AudioSource: String, Sendable, Codable, Hashable {
    case mic
    case system
}

/// Zero-copy hand-off of a captured PCM buffer between isolation domains.
///
/// Ownership rule: **the producer must not touch `buffer` after yielding it.**
/// `BufferConverter` allocates a fresh output buffer for every conversion, so a
/// capture source only ever yields buffers it will never look at again — the
/// rule holds by construction. `@unchecked Sendable` because `AVAudioPCMBuffer`
/// is a reference type the compiler can't prove safe to send; the ownership
/// rule is what actually makes it safe.
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    /// Host-time anchor for the buffer; `nil` in M1 (audio is fed contiguously,
    /// so each analyzer's timeline shares zero ≈ session start). The escape
    /// hatch for cross-source drift in later slices.
    public let time: CMTime?

    public init(buffer: AVAudioPCMBuffer, time: CMTime? = nil) {
        self.buffer = buffer
        self.time = time
    }
}

public enum CaptureError: Error {
    case formatUnavailable
    case conversionFailed(underlying: Error?)
    case engineStartFailed(underlying: Error)
    /// A Core Audio process-tap / aggregate-device call failed. `status` is the
    /// offending `OSStatus`; `stage` names which call (tap create, aggregate
    /// create, IOProc create, device start) so a silent-audio TCC misconfig is
    /// diagnosable from the log.
    case processTapFailed(stage: String, status: OSStatus)
}
