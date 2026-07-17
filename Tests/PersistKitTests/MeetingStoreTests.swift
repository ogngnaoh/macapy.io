import CaptureKit
import Foundation
import Testing
import TranscribeKit

@testable import PersistKit

/// Checks 2 and 4: begin → append → end lifecycle round-trips through
/// `listMeetings`/`segments(for:)` with correct us/them mapping and ordering;
/// `deleteMeeting` cascades.
struct MeetingStoreTests {
    private func seg(_ text: String, _ source: AudioSource, _ t: TimeInterval) -> Segment {
        Segment(id: UUID(), source: source, text: text, tStart: t, tEnd: t + 1)
    }

    @Test func beginAppendEndRoundTripsWithSourceMappingAndOrder() async throws {
        let store = MeetingStore(database: try MacapyDatabase.inMemory())
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        let meeting = try await store.beginMeeting(startedAt: startedAt, ephemeral: false)
        #expect(meeting.status == MeetingRecord.activeStatus)
        #expect(meeting.endedAt == nil)
        #expect(meeting.ephemeral == false)

        try await store.append(
            [seg("hello", .mic, 0), seg("hi there", .system, 1), seg("bye", .mic, 2)],
            to: meeting.id
        )

        let endedAt = startedAt.addingTimeInterval(60)
        try await store.endMeeting(id: meeting.id, endedAt: endedAt)

        let meetings = try await store.listMeetings()
        #expect(meetings.count == 1)
        #expect(meetings[0].status == MeetingRecord.endedStatus)
        #expect(meetings[0].endedAt == endedAt)

        let segments = try await store.segments(for: meeting.id)
        #expect(segments.map(\.text) == ["hello", "hi there", "bye"])
        #expect(segments.map(\.source) == [.mic, .system, .mic])
        #expect(segments.map(\.tStart) == [0, 1, 2])
    }

    @Test func segmentsAreOrderedByTStartRegardlessOfInsertOrder() async throws {
        let store = MeetingStore(database: try MacapyDatabase.inMemory())
        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)

        // Insert out of tStart order; the read must still come back ordered.
        try await store.append([seg("third", .mic, 2)], to: meeting.id)
        try await store.append([seg("first", .system, 0)], to: meeting.id)
        try await store.append([seg("second", .mic, 1)], to: meeting.id)

        let segments = try await store.segments(for: meeting.id)
        #expect(segments.map(\.text) == ["first", "second", "third"])
    }

    @Test func listMeetingsReturnsMostRecentlyStartedFirst() async throws {
        let store = MeetingStore(database: try MacapyDatabase.inMemory())
        let older = try await store.beginMeeting(startedAt: Date(timeIntervalSinceReferenceDate: 0), ephemeral: false)
        let newer = try await store.beginMeeting(startedAt: Date(timeIntervalSinceReferenceDate: 1_000), ephemeral: false)

        let meetings = try await store.listMeetings()
        #expect(meetings.map(\.id) == [newer.id, older.id])
    }

    @Test func appendOfEmptyBatchIsANoOp() async throws {
        let store = MeetingStore(database: try MacapyDatabase.inMemory())
        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        try await store.append([], to: meeting.id)
        let segments = try await store.segments(for: meeting.id)
        #expect(segments.isEmpty)
    }

    @Test func deleteMeetingCascadesToSegments() async throws {
        let store = MeetingStore(database: try MacapyDatabase.inMemory())
        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        try await store.append([seg("hello", .mic, 0), seg("hi", .system, 1)], to: meeting.id)

        try await store.deleteMeeting(id: meeting.id)

        let meetings = try await store.listMeetings()
        #expect(meetings.isEmpty)
        let segments = try await store.segments(for: meeting.id)
        #expect(segments.isEmpty, "cascade delete must remove the meeting's segments rows")
    }

    @Test func deletingAMeetingDoesNotAffectOthers() async throws {
        let store = MeetingStore(database: try MacapyDatabase.inMemory())
        let toDelete = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        let toKeep = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        try await store.append([seg("keep me", .mic, 0)], to: toKeep.id)

        try await store.deleteMeeting(id: toDelete.id)

        let meetings = try await store.listMeetings()
        #expect(meetings.map(\.id) == [toKeep.id])
        let segments = try await store.segments(for: toKeep.id)
        #expect(segments.map(\.text) == ["keep me"])
    }
}
