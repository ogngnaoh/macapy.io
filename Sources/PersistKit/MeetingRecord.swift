import CaptureKit
import Foundation
import GRDB
import TranscribeKit

/// The `meetings` row (SPEC §6.2). Public: `MeetingStore`'s callers (the
/// pipeline, the history view) work with this type directly.
public struct MeetingRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: String
    public var ephemeral: Bool

    public init(
        id: UUID,
        title: String,
        startedAt: Date,
        endedAt: Date?,
        status: String,
        ephemeral: Bool
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.ephemeral = ephemeral
    }
}

extension MeetingRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meetings"
}

extension MeetingRecord {
    /// `status` is a plain `String` at the row boundary (not an enum) so a
    /// future status value never needs a migration. Public since slice 3:
    /// meeting detail decides "artifacts-pending" off `status == endedStatus`.
    public static let activeStatus = "active"
    public static let endedStatus = "ended"

    public var hasEnded: Bool { status == Self.endedStatus }
}

/// The `segments` row. Internal to PersistKit: `MeetingStore` converts to/from
/// `TranscribeKit.Segment` at the boundary, mapping `AudioSource.mic`/`.system`
/// to the schema's `us`/`them` (slice-04 doc decision 3) — the rest of the app
/// never sees "us"/"them" strings.
struct SegmentRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "segments"

    var id: UUID
    var meetingID: UUID
    var source: String
    var text: String
    var tStart: Double
    var tEnd: Double
    var isFinal: Bool

    init(segment: Segment, meetingID: UUID) {
        self.id = segment.id
        self.meetingID = meetingID
        self.source = segment.source.persistedSource
        self.text = segment.text
        self.tStart = segment.tStart
        self.tEnd = segment.tEnd
        self.isFinal = true
    }

    /// `nil` if `source` doesn't decode to a known `AudioSource` — defensive
    /// only; every row this module writes round-trips cleanly.
    var asSegment: Segment? {
        guard let audioSource = AudioSource(persistedSource: source) else { return nil }
        return Segment(id: id, source: audioSource, text: text, tStart: tStart, tEnd: tEnd)
    }
}

extension AudioSource {
    /// Row-boundary mapping (SPEC §6.2): `mic` is the app's user ("us");
    /// `system` is everyone else in the meeting ("them").
    var persistedSource: String {
        switch self {
        case .mic: return "us"
        case .system: return "them"
        }
    }

    init?(persistedSource raw: String) {
        switch raw {
        case "us": self = .mic
        case "them": self = .system
        default: return nil
        }
    }
}
