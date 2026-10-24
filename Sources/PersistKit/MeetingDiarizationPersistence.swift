import Foundation
import GRDB

/// Immutable source revision for a timing-based attribution. No transcript text
/// is needed. If editable transcript timings are introduced, extend this token.
public struct DiarizationSegmentSnapshot: Sendable, Equatable {
    public let id: UUID
    public let tStart: TimeInterval
    public let tEnd: TimeInterval

    public init(id: UUID, tStart: TimeInterval, tEnd: TimeInterval) {
        self.id = id
        self.tStart = tStart
        self.tEnd = tEnd
    }
}

public enum DiarizationPersistenceError: Error, Sendable {
    case staleSource
    case invalidAssignment
}

extension MeetingStore {
    /// The pipeline calls this only for a worker that naturally completed
    /// within its grace period, after the final transcript flush. A cancelled
    /// worker never owns a database task. Recheck its fence *inside* the write
    /// transaction so a queued cross-actor call cannot resurrect deleted work.
    public func applyDiarization(
        speakers: [SpeakerRecord],
        assignments: [UUID: UUID],
        meetingID: UUID,
        expectedSegments: [DiarizationSegmentSnapshot],
        isCurrent: @Sendable () -> Bool
    ) throws {
        try database.dbWriter.write { db in
            guard isCurrent() else { throw CancellationError() }
            guard let meeting = try MeetingRecord.fetchOne(db, id: meetingID),
                  meeting.status == MeetingRecord.activeStatus else {
                throw DiarizationPersistenceError.staleSource
            }
            let speakerIDs = Set(speakers.map(\.id))
            let sourceIDs = Set(expectedSegments.map(\.id))
            guard speakerIDs.count == speakers.count,
                  sourceIDs.count == expectedSegments.count,
                  speakers.allSatisfy({ $0.meetingID == meetingID }),
                  assignments.allSatisfy({ sourceIDs.contains($0.key) && speakerIDs.contains($0.value) }) else {
                throw DiarizationPersistenceError.invalidAssignment
            }
            for snapshot in expectedSegments {
                guard let row = try SegmentRecord.fetchOne(db, key: snapshot.id),
                      row.meetingID == meetingID, row.source == "them",
                      row.tStart == snapshot.tStart, row.tEnd == snapshot.tEnd else {
                    throw DiarizationPersistenceError.staleSource
                }
            }
            for speaker in speakers { try speaker.insert(db) }
            for (segmentID, speakerID) in assignments {
                try db.execute(sql: "UPDATE segments SET speakerId=? WHERE id=? AND meetingID=? AND source='them'",
                               arguments: [speakerID, segmentID, meetingID])
                guard db.changesCount == 1 else { throw DiarizationPersistenceError.staleSource }
            }
            // Throwing rolls back speakers and assignments together.
            guard isCurrent() else { throw CancellationError() }
        }
    }
}
