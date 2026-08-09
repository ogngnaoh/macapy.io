import Foundation
import GRDB
import TranscribeKit

/// `MeetingStore`'s own failure modes (beyond what GRDB throws).
public enum MeetingStoreError: Error, Equatable {
    /// `renameMeeting` with an empty or whitespace-only title (slice-5
    /// check 5: the UI reverts instead of storing an unsearchable blank).
    case emptyTitle
}

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

    /// One history-list row (slice-05 doc decision, per design/04): the
    /// meeting plus the counts its summary line renders — duration ·
    /// speaker count · artifact count.
    public struct MeetingSummary: Decodable, FetchableRecord, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        public var startedAt: Date
        public var endedAt: Date?
        public var status: String
        public var ephemeral: Bool
        public var speakerCount: Int
        public var artifactCount: Int

        /// `nil` while the meeting is still active (no `endedAt` yet).
        public var duration: TimeInterval? {
            endedAt.map { $0.timeIntervalSince(startedAt) }
        }

        public var hasEnded: Bool { status == MeetingRecord.endedStatus }

        /// The summary's meeting fields as a `MeetingRecord` — for callers
        /// (meeting detail) whose API speaks records.
        public var asRecord: MeetingRecord {
            MeetingRecord(
                id: id, title: title, startedAt: startedAt, endedAt: endedAt,
                status: status, ephemeral: ephemeral)
        }
    }

    /// All meetings with their summary counts, most recently started first —
    /// the history list's one query. Ephemeral rows are filtered even though
    /// none can exist in the on-disk database (they live in per-meeting
    /// in-memory databases) — the filter makes the surface's contract
    /// independent of that construction.
    public func meetingSummaries() throws -> [MeetingSummary] {
        try database.dbWriter.read { db in
            try MeetingSummary.fetchAll(
                db,
                sql: """
                    SELECT m.*,
                        (SELECT count(*) FROM speakers sp WHERE sp.meetingID = m.id) AS speakerCount,
                        (SELECT count(*) FROM artifacts a WHERE a.meetingID = m.id) AS artifactCount
                    FROM meetings m
                    WHERE m.ephemeral = 0
                    ORDER BY m.startedAt DESC
                    """)
        }
    }

    /// Renames a meeting (slice-05 doc decision 9 — auto-generated titles
    /// made title search near-meaningless without this). The plain UPDATE
    /// re-indexes the title through the FTS `_au` trigger for free. An
    /// empty or whitespace-only title is rejected; stored titles are
    /// trimmed. A no-op (no throw) if the id matches no row.
    public func renameMeeting(id: MeetingRecord.ID, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MeetingStoreError.emptyTitle
        }
        try database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE meetings SET title = ? WHERE id = ?",
                arguments: [trimmed, id])
        }
    }

    /// Delete-everything (FR-013; slice-05 doc decision 8) — **meeting data
    /// only** (author ruling 2026-08-07): Keychain credentials and `settings`
    /// rows survive. One transaction deletes every meeting (segments,
    /// artifacts, speakers, and metered spend cascade via their FKs; the FTS
    /// `_ad` triggers scrub all three indexes) plus the NULL-meetingID spend
    /// rows the cascade can't reach. Afterwards `VACUUM` rewrites the file so
    /// deleted content doesn't linger in free pages, and a TRUNCATE
    /// checkpoint empties the WAL — that pair is what makes the byte-grep
    /// residue oracle (check 13) possible.
    public func deleteAllUserData() throws {
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM meetings")
            try db.execute(sql: "DELETE FROM spend_ledger")
            // The `_ad` triggers only *mark* index entries deleted — the FTS5
            // segment blobs in `*_fts_data` still contain the dead tokens
            // until a merge. `optimize` collapses each index to nothing
            // (zero live docs remain), so VACUUM below has no token bytes
            // left to copy.
            for fts in ["meetings_fts", "segments_fts", "artifacts_fts"] {
                try db.execute(sql: "INSERT INTO \(fts)(\(fts)) VALUES('optimize')")
            }
        }
        try database.dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            // In-memory databases have no WAL; the checkpoint is a no-op there.
            try db.checkpoint(.truncate)
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
