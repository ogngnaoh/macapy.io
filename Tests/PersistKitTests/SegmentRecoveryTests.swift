import Foundation
import GRDB
import Testing
import TranscribeKit
@testable import PersistKit

struct SegmentRecoveryTests {
    @Test func failedBatchIsRetriedWithoutLosingWordsOrDuplicatingRows() async throws {
        let database = try MacapyDatabase.inMemory()
        let store = MeetingStore(database: database)
        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        try await database.dbWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER block_segments BEFORE INSERT ON segments BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        }
        let (stream, continuation) = AsyncStream<Segment>.makeStream()
        let writer = SegmentWriter(store: store, meetingID: meeting.id, batchThreshold: 1)
        let run = Task { await writer.run(consuming: stream) }
        continuation.yield(Segment(id: UUID(), source: .mic, text: "retained first", tStart: 0, tEnd: 1))
        for _ in 0..<200 where !(await writer.persistenceStatus.isDegraded) { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await writer.persistenceStatus.isDegraded)
        try await database.dbWriter.write { db in try db.execute(sql: "DROP TRIGGER block_segments") }
        continuation.yield(Segment(id: UUID(), source: .mic, text: "second", tStart: 1, tEnd: 2))
        continuation.finish()
        try await writer.flushAndStop()
        await run.value
        #expect(try await store.segments(for: meeting.id).map(\.text) == ["retained first", "second"])
        #expect(!(await writer.persistenceStatus.isDegraded))
    }

    @Test func persistentFailureRetainsOnlyBoundedTextAndReportsLoss() async throws {
        let database = try MacapyDatabase.inMemory()
        let store = MeetingStore(database: database)
        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        try await database.dbWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER block_segments BEFORE INSERT ON segments BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        }
        let (stream, continuation) = AsyncStream<Segment>.makeStream()
        let writer = SegmentWriter(store: store, meetingID: meeting.id, batchThreshold: 1, maximumBufferedSegments: 2)
        let run = Task { await writer.run(consuming: stream) }
        for index in 0..<5 { continuation.yield(Segment(id: UUID(), source: .mic, text: "line \(index)", tStart: Double(index), tEnd: Double(index+1))) }
        continuation.finish()
        await run.value
        await #expect(throws: (any Error).self) { try await writer.flushAndStop() }
        let status = await writer.persistenceStatus
        #expect(status.isDegraded)
        #expect(status.bufferedSegments == 2)
        #expect(status.droppedSegments == 3)
    }
}
