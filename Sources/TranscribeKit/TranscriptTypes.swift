import CaptureKit
import Foundation

/// A finalized transcript segment. Times are seconds, session-relative, and
/// comparable across sources (all analyzers share zero ≈ session start in M1).
/// Matches schema v1 `segments` (`text`, `t_start`, `t_end`).
public struct Segment: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let source: AudioSource
    public let text: String
    public let tStart: TimeInterval
    public let tEnd: TimeInterval

    public init(id: UUID, source: AudioSource, text: String, tStart: TimeInterval, tEnd: TimeInterval) {
        self.id = id
        self.source = source
        self.text = text
        self.tStart = tStart
        self.tEnd = tEnd
    }
}

/// A completed speaker turn assembled from one or more finalized segments.
///
/// Turn boundaries are supplied by the source engine through `.turnEnded`.
/// Segment ids keep the turn traceable to the durable transcript while the
/// joined text and time bounds make it cheap for live-intelligence consumers
/// to build context without rescanning `TranscriptStore.segments`.
public struct TranscriptTurn: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let source: AudioSource
    public let text: String
    public let segmentIDs: [Segment.ID]
    public let tStart: TimeInterval
    public let tEnd: TimeInterval

    public init(
        id: UUID = UUID(),
        source: AudioSource,
        text: String,
        segmentIDs: [Segment.ID],
        tStart: TimeInterval,
        tEnd: TimeInterval
    ) {
        self.id = id
        self.source = source
        self.text = text
        self.segmentIDs = segmentIDs
        self.tStart = tStart
        self.tEnd = tEnd
    }
}

/// An event from an `STTEngine`. Attributes are stripped at the engine boundary
/// (the M1 panel doesn't use them). `.turnEnded` marks the end of a speaker
/// turn for the event's source.
public enum TranscriptEvent: Sendable, Equatable {
    case volatile(text: String, tStart: TimeInterval, tEnd: TimeInterval)
    case final(Segment)
    case turnEnded
}

public enum TranscribeError: Error {
    case localeUnsupported(Locale)
    case assetsUnavailable(Locale, underlying: Error?)
    case analyzerFailed(underlying: Error)
}
