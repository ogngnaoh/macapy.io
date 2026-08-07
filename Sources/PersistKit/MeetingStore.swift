import Foundation
import GRDB
import TranscribeKit

/// Owns one database's meeting/segment reads and writes. Actor-isolated so
/// concurrent callers (the pipeline's `SegmentWriter`, a history view's fetch)
/// serialize safely; GRDB's own writer queue is a second layer of safety
/// underneath. Methods use GRDB's *synchronous* `write`/`read` (not the async
/// overloads) — cheap local SQLite operations blocking the actor's own
/// executor is an accepted, standard GRDB+actor pattern, and it's what lets
/// these methods stay plain `throws` per the slice-04 doc's signatures. Callers
/// outside this actor still need `await` at the call site (Swift's implicit
/// async for cross-actor calls) even though no method here is `async`.
public actor MeetingStore {
    private let database: MacapyDatabase

    public init(database: MacapyDatabase) {
        self.database = database
    }

    /// Inserts a new `meetings` row (`status = .active`) and returns it.
    @discardableResult
    public func beginMeeting(startedAt: Date, ephemeral: Bool) throws -> MeetingRecord {
        let record = MeetingRecord(
            id: UUID(),
            title: Self.defaultTitle(for: startedAt),
            startedAt: startedAt,
            endedAt: nil,
            status: MeetingRecord.activeStatus,
            ephemeral: ephemeral
        )
        try database.dbWriter.write { db in
            try record.insert(db)
        }
        return record
    }

    /// Marks a meeting `.ended` with its end time. A no-op (no throw) if the
    /// id doesn't match any row.
    public func endMeeting(id: MeetingRecord.ID, endedAt: Date) throws {
        try database.dbWriter.write { db in
            guard var record = try MeetingRecord.fetchOne(db, id: id) else { return }
            record.endedAt = endedAt
            record.status = MeetingRecord.endedStatus
            try record.update(db)
        }
    }

    /// Appends segments to a meeting (SPEC invariant: `segments` is
    /// append-only during a meeting). Maps `AudioSource` to `us`/`them` at
    /// the row boundary. A no-op for an empty batch.
    public func append(_ segments: [Segment], to meetingID: MeetingRecord.ID) throws {
        guard !segments.isEmpty else { return }
        try database.dbWriter.write { db in
            for segment in segments {
                try SegmentRecord(segment: segment, meetingID: meetingID).insert(db)
            }
        }
    }

    /// One meeting by id, or `nil` — the post-meeting agent's guard against
    /// generating for a meeting that no longer exists.
    public func meeting(id: MeetingRecord.ID) throws -> MeetingRecord? {
        try database.dbWriter.read { db in
            try MeetingRecord.fetchOne(db, id: id)
        }
    }

    /// All meetings, most recently started first (history list order).
    public func listMeetings() throws -> [MeetingRecord] {
        try database.dbWriter.read { db in
            try MeetingRecord
                .order(Column("startedAt").desc)
                .fetchAll(db)
        }
    }

    /// A meeting's segments, ordered by `tStart` (the append-only invariant
    /// means insertion order already matches, but the explicit order makes
    /// the guarantee independent of storage order).
    public func segments(for meetingID: MeetingRecord.ID) throws -> [Segment] {
        try database.dbWriter.read { db in
            try SegmentRecord
                .filter(Column("meetingID") == meetingID)
                .order(Column("tStart"))
                .fetchAll(db)
                .compactMap(\.asSegment)
        }
    }

    /// Deletes a meeting; `segments` rows cascade via the FK (SPEC §6.2).
    public func deleteMeeting(id: MeetingRecord.ID) throws {
        try database.dbWriter.write { db in
            _ = try MeetingRecord.deleteOne(db, id: id)
        }
    }

    // MARK: - Speakers (schema v4, slice-4 decision 3)

    /// Inserts a meeting's diarized speakers in one transaction. Called once,
    /// from `MeetingPipeline.stop()`'s persistence sweep.
    public func insertSpeakers(_ speakers: [SpeakerRecord]) throws {
        guard !speakers.isEmpty else { return }
        try database.dbWriter.write { db in
            for speaker in speakers {
                try speaker.insert(db)
            }
        }
    }

    /// Batched post-hoc attribution: sets `segments.speakerId` for every
    /// listed segment, one transaction. Runs after `flushAndStop()` (every
    /// segment row provably inserted), so a missing row is a real
    /// inconsistency — surfaced by the thrown error, not skipped.
    public func assignSpeakers(
        _ assignments: [Segment.ID: SpeakerRecord.ID],
        meetingID: MeetingRecord.ID
    ) throws {
        guard !assignments.isEmpty else { return }
        try database.dbWriter.write { db in
            for (segmentID, speakerID) in assignments {
                try db.execute(
                    sql: """
                        UPDATE segments SET speakerId = :speakerID
                        WHERE id = :segmentID AND meetingID = :meetingID
                        """,
                    arguments: ["speakerID": speakerID, "segmentID": segmentID, "meetingID": meetingID]
                )
            }
        }
    }

    /// A meeting's speakers, in label order (S1, S2, … — first-appearance
    /// order by construction, since labels are assigned in that order).
    public func speakers(for meetingID: MeetingRecord.ID) throws -> [SpeakerRecord] {
        try database.dbWriter.read { db in
            try SpeakerRecord
                .filter(Column("meetingID") == meetingID)
                .order(Column("label"))
                .fetchAll(db)
        }
    }

    /// Segments joined with their diarized speaker labels — the post-meeting
    /// read path (meeting detail, the agent's transcript build).
    public func attributedSegments(for meetingID: MeetingRecord.ID) throws -> [AttributedSegment] {
        try database.dbWriter.read { db in
            let labelsByID: [UUID: String] = try SpeakerRecord
                .filter(Column("meetingID") == meetingID)
                .fetchAll(db)
                .reduce(into: [:]) { $0[$1.id] = $1.label }
            return try SegmentRecord
                .filter(Column("meetingID") == meetingID)
                .order(Column("tStart"))
                .fetchAll(db)
                .compactMap { record in
                    guard let segment = record.asSegment else { return nil }
                    return AttributedSegment(
                        segment: segment,
                        speakerID: record.speakerId,
                        speakerLabel: record.speakerId.flatMap { labelsByID[$0] }
                    )
                }
        }
    }

    private static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Meeting \(formatter.string(from: date))"
    }
}
