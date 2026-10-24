import Foundation
import GRDB
import Testing
import TranscribeKit

@testable import PersistKit

struct MeetingDiarizationPersistenceTests {
    private func fixture() async throws -> (MacapyDatabase, MeetingStore, UUID, Segment, SpeakerRecord) {
        let database = try MacapyDatabase.inMemory()
        let store = MeetingStore(database: database)
        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        let segment = Segment(id: UUID(), source: .system, text: "A fictional fixture.", tStart: 1, tEnd: 2)
        try await store.append([segment], to: meeting.id)
        let speaker = SpeakerRecord(id: UUID(), meetingID: meeting.id, label: "S1", embedding: nil)
        return (database, store, meeting.id, segment, speaker)
    }

    private func apply(_ store: MeetingStore, _ id: UUID, _ segment: Segment, _ speaker: SpeakerRecord,
                       fence: @escaping @Sendable () -> Bool = { true }) async throws {
        try await store.applyDiarization(speakers: [speaker], assignments: [segment.id: speaker.id], meetingID: id,
                                        expectedSegments: [.init(id: segment.id, tStart: segment.tStart, tEnd: segment.tEnd)],
                                        isCurrent: fence)
    }

    @Test func successfulCommitWritesSpeakersAndAssignmentsTogether() async throws {
        let (_, store, id, segment, speaker) = try await fixture()
        try await apply(store, id, segment, speaker)
        #expect(try await store.speakers(for: id) == [speaker])
        #expect(try await store.attributedSegments(for: id).first?.speakerID == speaker.id)
    }

    @Test(arguments: ["cancelled", "deleted", "retimed", "mic", "ended"])
    func staleOrChangedSourceWritesNothing(reason: String) async throws {
        let (database, store, id, segment, speaker) = try await fixture()
        switch reason {
        case "deleted": try await store.deleteMeeting(id: id)
        case "retimed": try await database.dbWriter.write { db in try db.execute(sql: "UPDATE segments SET tEnd=5 WHERE id=?", arguments: [segment.id]) }
        case "mic": try await database.dbWriter.write { db in try db.execute(sql: "UPDATE segments SET source='us' WHERE id=?", arguments: [segment.id]) }
        case "ended": try await store.endMeeting(id: id, endedAt: Date())
        default: break
        }
        await #expect(throws: (any Error).self) {
            try await apply(store, id, segment, speaker, fence: { reason != "cancelled" })
        }
        #expect(try await store.speakers(for: id).isEmpty)
        #expect(try await store.attributedSegments(for: id).allSatisfy { $0.speakerID == nil })
    }

    @Test func cancellationDuringTransactionRollsBackSpeakerRowsAndLabels() async throws {
        final class Fence: @unchecked Sendable {
            let lock = NSLock()
            var checks = 0
            func test() -> Bool { lock.withLock { checks += 1; return checks == 1 } }
        }
        let (_, store, id, segment, speaker) = try await fixture()
        let fence = Fence()
        await #expect(throws: CancellationError.self) {
            try await apply(store, id, segment, speaker, fence: { fence.test() })
        }
        #expect(try await store.speakers(for: id).isEmpty)
        #expect(try await store.attributedSegments(for: id).first?.speakerID == nil)
    }

    @Test func crossMeetingSpeakerCannotBeAssigned() async throws {
        let (_, store, id, segment, _) = try await fixture()
        let other = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        let speaker = SpeakerRecord(id: UUID(), meetingID: other.id, label: "S1", embedding: nil)
        await #expect(throws: DiarizationPersistenceError.self) { try await apply(store, id, segment, speaker) }
        #expect(try await store.speakers(for: id).isEmpty)
        #expect(try await store.speakers(for: other.id).isEmpty)
    }
}
