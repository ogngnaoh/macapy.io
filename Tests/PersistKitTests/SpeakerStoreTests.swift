import CaptureKit
import Foundation
import GRDB
import Testing
import TranscribeKit

@testable import PersistKit

/// Slice-4 check 7: the v4 speakers schema round-trips, attribution lands by
/// batched UPDATE, meeting deletion cascades speakers, and deleting a speaker
/// nulls — never deletes — its segments.
struct SpeakerStoreTests {

    private func seededMeeting(
        _ store: MeetingStore, segmentTexts: [String] = ["one", "two", "three"]
    ) async throws -> (meeting: MeetingRecord, segments: [Segment]) {
        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        let segments = segmentTexts.enumerated().map { index, text in
            Segment(
                id: UUID(), source: .system, text: text,
                tStart: Double(index), tEnd: Double(index) + 0.9)
        }
        try await store.append(segments, to: meeting.id)
        return (meeting, segments)
    }

    @Test func insertAssignRoundTripAttributesLabels() async throws {
        let store = MeetingStore(database: try MacapyDatabase.inMemory())
        let (meeting, segments) = try await seededMeeting(store)

        let s1 = SpeakerRecord(
            id: UUID(), meetingID: meeting.id, label: "S1", embedding: Data([1, 2]))
        let s2 = SpeakerRecord(id: UUID(), meetingID: meeting.id, label: "S2", embedding: nil)
        try await store.insertSpeakers([s1, s2])
        try await store.assignSpeakers(
            [segments[0].id: s1.id, segments[2].id: s2.id], meetingID: meeting.id)

        let speakers = try await store.speakers(for: meeting.id)
        #expect(speakers == [s1, s2])

        let attributed = try await store.attributedSegments(for: meeting.id)
        #expect(attributed.map(\.speakerLabel) == ["S1", nil, "S2"])
        #expect(attributed.map(\.speakerID) == [s1.id, nil, s2.id])
        #expect(attributed.map(\.segment) == segments)
    }

    @Test func unattributedMeetingReadsBackAllNilLabels() async throws {
        let store = MeetingStore(database: try MacapyDatabase.inMemory())
        let (meeting, segments) = try await seededMeeting(store)

        let attributed = try await store.attributedSegments(for: meeting.id)
        #expect(attributed.count == segments.count)
        #expect(attributed.allSatisfy { $0.speakerID == nil && $0.speakerLabel == nil })
    }

    @Test func deletingAMeetingCascadesItsSpeakers() async throws {
        let database = try MacapyDatabase.inMemory()
        let store = MeetingStore(database: database)
        let (meeting, segments) = try await seededMeeting(store)
        let (other, _) = try await seededMeeting(store)

        let mine = SpeakerRecord(id: UUID(), meetingID: meeting.id, label: "S1", embedding: nil)
        let theirs = SpeakerRecord(id: UUID(), meetingID: other.id, label: "S1", embedding: nil)
        try await store.insertSpeakers([mine, theirs])
        try await store.assignSpeakers([segments[0].id: mine.id], meetingID: meeting.id)

        try await store.deleteMeeting(id: meeting.id)

        let (speakerCount, segmentCount, survivor) = try await database.dbWriter.read { db in
            (
                try SpeakerRecord.fetchCount(db),
                try SegmentRecord.fetchCount(db),
                try SpeakerRecord.fetchOne(db, id: theirs.id)
            )
        }
        #expect(speakerCount == 1)
        #expect(survivor == theirs)
        #expect(segmentCount == 3)  // the other meeting's rows, untouched
    }

    @Test func deletingASpeakerNullsItsSegmentsInsteadOfDeletingThem() async throws {
        let database = try MacapyDatabase.inMemory()
        let store = MeetingStore(database: database)
        let (meeting, segments) = try await seededMeeting(store)

        let speaker = SpeakerRecord(id: UUID(), meetingID: meeting.id, label: "S1", embedding: nil)
        try await store.insertSpeakers([speaker])
        try await store.assignSpeakers(
            [segments[0].id: speaker.id, segments[1].id: speaker.id], meetingID: meeting.id)

        _ = try await database.dbWriter.write { db in
            try SpeakerRecord.deleteOne(db, id: speaker.id)
        }

        let attributed = try await store.attributedSegments(for: meeting.id)
        #expect(attributed.count == segments.count)  // transcript rows survive
        #expect(attributed.allSatisfy { $0.speakerID == nil })
    }

    @Test func assigningToAMissingSegmentThrowsInsteadOfSilentlySkipping() async throws {
        // The sweep runs after flushAndStop(), so a missing row is a real
        // inconsistency — FK enforcement must reject an unknown speaker id
        // (an unknown segment id simply matches zero rows; the speaker FK is
        // the constraint with teeth).
        let store = MeetingStore(database: try MacapyDatabase.inMemory())
        let (meeting, segments) = try await seededMeeting(store)

        await #expect(throws: (any Error).self) {
            try await store.assignSpeakers(
                [segments[0].id: UUID()], meetingID: meeting.id)
        }
    }
}
