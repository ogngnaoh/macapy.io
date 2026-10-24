import Foundation
import GRDB
import Testing
import TranscribeKit
@testable import PersistKit

struct RecoveryTests {
    @Test func reopeningRecoversOnlyUnfinishedMeetingsFromCommittedText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = try MacapyDatabase.onDisk(at: url)
        let store = MeetingStore(database: database)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let unfinished = try await store.beginMeeting(startedAt: start, ephemeral: false)
        try await store.append([Segment(id: UUID(), source: .mic, text: "Synthetic recovery fixture", tStart: 0, tEnd: 12)], to: unfinished.id)
        let ended = try await store.beginMeeting(startedAt: start, ephemeral: false)
        try await store.endMeeting(id: ended.id, endedAt: start.addingTimeInterval(30))
        let reopened = MeetingStore(database: try MacapyDatabase.onDisk(at: url))
        let recovered = try #require(await reopened.meeting(id: unfinished.id))
        #expect(recovered.status == MeetingRecord.interruptedStatus)
        #expect(recovered.endedAt == start.addingTimeInterval(12))
        #expect(recovered.hasEnded)
        #expect(try await reopened.meeting(id: ended.id)?.status == MeetingRecord.endedStatus)
        #expect(try await reopened.segments(for: unfinished.id).count == 1)
        #expect(!FileManager.default.fileExists(atPath: database.migrationSnapshotURL!.path))
    }

    @Test func futureSchemaIsRefusedWithoutDeletingOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("future.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try MacapyDatabase.onDisk(at: url)
        try await database.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v999-future')")
        }
        #expect(throws: DatabaseRecoveryError.futureSchema) { try MacapyDatabase.onDisk(at: url) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try await database.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations WHERE identifier = 'v999-future'")
        } == "v999-future")
    }

    @Test func deletingMeetingPurgesAnyRecoverySnapshotFirst() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = try MacapyDatabase.onDisk(at: url)
        let store = MeetingStore(database: database)
        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        try Data("synthetic recovery content".utf8).write(to: database.migrationSnapshotURL!)
        try await store.deleteMeeting(id: meeting.id)
        #expect(!FileManager.default.fileExists(atPath: database.migrationSnapshotURL!.path))
        #expect(try await store.meeting(id: meeting.id) == nil)
    }
}
