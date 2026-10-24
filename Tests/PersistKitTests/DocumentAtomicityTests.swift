import Foundation
import GRDB
import MemoryKit
import Testing
@testable import PersistKit

struct DocumentAtomicityTests {
    @Test func failureAfterPartialGenerationInsertRestoresPreviousSnapshotAndIndex() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await meetings.endMeeting(id: meeting.id, endedAt: Date())
        let documents = DocumentStore(database: database)
        let doc = try await documents.importDocument(.init(name: "x.txt", mediaType: "text/plain", pages: [.init(number: nil, text: "original cedar snapshot")]), meetingID: meeting.id)
        try await documents.setAllowedForAI(true, id: doc.id)
        let memory = MemoryStore(database: database)
        let context = try await memory.retrieve(.init(query: "cedar"))
        try await database.dbWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_test_second_chunk BEFORE INSERT ON document_chunks WHEN NEW.ordinal=1
                BEGIN SELECT RAISE(ABORT, 'synthetic index failure'); END;
                """)
        }
        await #expect(throws: (any Error).self) {
            try await documents.reimport(.init(name: "x.txt", mediaType: "text/plain", pages: [.init(number: nil, text: String(repeating: "replacement ", count: 200))]), id: doc.id, expectedRevision: doc.revision)
        }
        #expect(try await documents.snapshotText(id: doc.id) == "original cedar snapshot")
        #expect(try await memory.retrieve(.init(query: "replacement")).isEmpty)
        #expect(try await memory.validate(context, for: .init(query: "cedar")))
        #expect(try await documents.documents().first?.revision == doc.revision)
    }
}
