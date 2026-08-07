import Foundation
import GRDB
import TranscribeKit

/// The `speakers` row (SPEC §6.2, schema v4): one within-meeting voice from
/// diarization. `label` is the rendered gutter string (`S1`, `S2`, … by first
/// appearance — slice-4 decision 1); `embedding` is the engine's speaker
/// embedding, persisted for M4's cross-meeting identity work and unused until
/// then. Public: the pipeline writes these via `MeetingStore`, meeting detail
/// reads them.
public struct SpeakerRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let meetingID: UUID
    public let label: String
    public let embedding: Data?

    public init(id: UUID, meetingID: UUID, label: String, embedding: Data?) {
        self.id = id
        self.meetingID = meetingID
        self.label = label
        self.embedding = embedding
    }
}

extension SpeakerRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speakers"
}

/// A segment joined with its diarized speaker, if any (slice-4 decision 3).
/// `speakerLabel == nil` renders as the M1 source-based gutter ("You"/"Them").
public struct AttributedSegment: Sendable, Equatable {
    public let segment: Segment
    public let speakerID: UUID?
    public let speakerLabel: String?

    public init(segment: Segment, speakerID: UUID?, speakerLabel: String?) {
        self.segment = segment
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
    }
}
