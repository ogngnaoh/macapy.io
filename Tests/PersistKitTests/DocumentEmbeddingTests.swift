import Foundation
import MemoryKit
import Testing
@testable import PersistKit

struct DocumentEmbeddingTests {
    @Test func storedVectorsBindToSourceGenerationAndModelCompatibility() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await meetings.endMeeting(id: meeting.id, endedAt: Date())
        let store = DocumentStore(database: database)
        let doc = try await store.importDocument(.init(name: "x.txt", mediaType: "text/plain", pages: [.init(number: nil, text: "Cedar snapshot")]), meetingID: meeting.id)
        let input = try #require(try await store.embeddingInputs(id: doc.id).first)
        let vector = EmbeddingVector(language: "en", modelRevision: 1, values: [1, 0])
        try await store.storeEmbedding(vector, for: input)
        #expect(try await store.embeddings(id: doc.id, language: "en", modelRevision: 1, dimension: 2).count == 1)
        #expect(try await store.embeddings(id: doc.id, language: "en", modelRevision: 2, dimension: 2).isEmpty)
        #expect(try await store.embeddings(id: doc.id, language: "en", modelRevision: 1, dimension: 3).isEmpty)
        _ = try await store.reimport(.init(name: "x.txt", mediaType: "text/plain", pages: [.init(number: nil, text: "Cedar updated")]), id: doc.id, expectedRevision: doc.revision)
        #expect(try await store.embeddings(id: doc.id, language: "en", modelRevision: 1, dimension: 2).isEmpty)
        await #expect(throws: MemoryStoreError.revisionConflict) { try await store.storeEmbedding(vector, for: input) }
        try await store.remove(id: doc.id)
        #expect(try await store.embeddingInputs(id: doc.id).isEmpty)
    }
}
