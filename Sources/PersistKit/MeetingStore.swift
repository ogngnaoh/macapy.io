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

    private static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Meeting \(formatter.string(from: date))"
    }
}
