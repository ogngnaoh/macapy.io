import CaptureKit
import Foundation

/// A contiguous stretch of one speaker's speech on the them-stream, in the
/// meeting's session-relative timeline (same zero as the analyzer's
/// `tStart`/`tEnd`: audio is fed contiguously, so time = cumulative fed
/// duration).
public struct SpeakerTurn: Sendable, Equatable {
    /// Engine-stable key for a distinct voice within this meeting. Keys are
    /// opaque; `DiarizationSession` maps them to `S1`/`S2`… labels by first
    /// appearance (slice-4 decision 1).
    public let speakerKey: String
    public let tStart: TimeInterval
    public let tEnd: TimeInterval

    public init(speakerKey: String, tStart: TimeInterval, tEnd: TimeInterval) {
        self.speakerKey = speakerKey
        self.tStart = tStart
        self.tEnd = tEnd
    }
}

/// Diarization engine seam (slice-4 decision 1): the chunked-incremental
/// FluidAudio offline pipeline is the one production implementation; the
/// protocol exists so a streaming variant (Sortformer) can replace it without
/// touching the session/attribution layers if cross-window identity proves
/// unstable.
public protocol DiarizationEngine: Sendable {
    /// Feed one converted audio chunk (any format — implementations convert
    /// defensively to their required sample rate/layout). Returns any newly
    /// completed speaker turns; may buffer internally and return [].
    func ingest(_ chunk: AudioChunk) async throws -> [SpeakerTurn]

    /// Flush remaining audio and return the final turns plus per-speaker
    /// embeddings for persistence (`speakers.embedding` BLOB, schema v4).
    func finish() async throws -> (turns: [SpeakerTurn], embeddings: [String: Data])
}
