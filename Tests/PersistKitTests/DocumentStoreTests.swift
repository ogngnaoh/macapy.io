import Foundation
import MemoryKit
import Testing
@testable import PersistKit

struct DocumentStoreTests {
    private func fixture() async throws -> (MacapyDatabase, UUID, UUID) {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let first = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        let second = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await meetings.endMeeting(id: first.id, endedAt: Date())
        try await meetings.endMeeting(id: second.id, endedAt: Date())
        return (database, first.id, second.id)
    }
    private func document(_ text: String) -> ParsedDocument {
        .init(name: "release.md", mediaType: "text/markdown", pages: [.init(number: nil, text: text)])
    }

    @Test func importedSnapshotNeedsConsentAndLastDetachRemovesAllContent() async throws {
        let (database, first, second) = try await fixture()
        let store = DocumentStore(database: database)
        let doc = try await store.importDocument(document("Cedar launch Friday"), meetingID: first)
        let memory = MemoryStore(database: database)
        #expect(try await memory.retrieve(.init(query: "Cedar")).isEmpty)
        try await store.setAllowedForAI(true, id: doc.id)
        try await store.attach(id: doc.id, to: second)
        let context = try await memory.retrieve(.init(query: "Cedar"))
        #expect(context.excerpts.count == 1)
        #expect(try await memory.validate(context, for: .init(query: "Cedar")))
        try await store.detach(id: doc.id, from: first)
        #expect(try await store.documents(meetingID: second).count == 1)
        try await MeetingStore(database: database).deleteMeeting(id: second)
        #expect(try await store.documents().isEmpty)
        #expect(try await memory.retrieve(.init(query: "Cedar")).isEmpty)
        #expect(try await memory.validate(context, for: .init(query: "Cedar")) == false)
    }

    @Test func reimportIsAtomicRevisionBoundAndInvalidatesOldCitations() async throws {
        let (database, meeting, _) = try await fixture()
        let store = DocumentStore(database: database)
        let memory = MemoryStore(database: database)
        let doc = try await store.importDocument(document("Cedar Friday"), meetingID: meeting)
        try await store.setAllowedForAI(true, id: doc.id)
        let before = try await memory.retrieve(.init(query: "Cedar"))
        let replacement = try await store.reimport(document("Cedar Monday"), id: doc.id, expectedRevision: doc.revision)
        #expect(replacement.revision == doc.revision + 1)
        #expect(try await memory.retrieve(.init(query: "Friday")).isEmpty)
        #expect(try await memory.retrieve(.init(query: "Monday")).excerpts.count == 1)
        #expect(try await memory.validate(before, for: .init(query: "Cedar")) == false)
        await #expect(throws: MemoryStoreError.revisionConflict) { try await store.reimport(document("stale"), id: doc.id, expectedRevision: doc.revision) }
        #expect(try await store.snapshotText(id: doc.id) == "Cedar Monday")
    }

    @Test func sourceAndAsOfFiltersApplyBeforeSelectionAndBudgetsHold() async throws {
        let (database, first, second) = try await fixture()
        let store = DocumentStore(database: database)
        let a = try await store.importDocument(document(String(repeating: "cedar ", count: 2_000)), meetingID: first)
        let b = try await store.importDocument(document("cedar distinct second"), meetingID: second)
        try await store.setAllowedForAI(true, id: a.id)
        try await store.setAllowedForAI(true, id: b.id)
        let memory = MemoryStore(database: database)
        let onlyB = try await memory.retrieve(.init(query: "cedar", allowedMeetingIDs: [second], allowedDocumentIDs: [b.id]))
        #expect(onlyB.excerpts.count == 1)
        #expect(onlyB.excerpts.first?.text == "cedar distinct second")
        #expect(try await memory.retrieve(.init(query: "cedar", asOf: .distantPast)).isEmpty)
        #expect(try await memory.retrieve(.init(query: "cedar", allowedMeetingIDs: [])).isEmpty)
        let limited = try await memory.retrieve(.init(query: "cedar", maxExcerpts: 2, maxCharacters: 50))
        #expect(limited.excerpts.count <= 2)
        #expect(limited.excerpts.reduce(0, { $0 + $1.text.count }) <= 50)
        #expect(try await memory.validate(limited, for: .init(query: "cedar", maxExcerpts: 2, maxCharacters: 50)))
    }

    @Test func pausedAndCancelledImportsDoNotChangeExistingIndex() async throws {
        let (database, meeting, _) = try await fixture()
        let store = DocumentStore(database: database)
        await store.setIndexingPaused(true)
        await #expect(throws: MemoryStoreError.indexingPaused) { try await store.importDocument(document("content"), meetingID: meeting) }
        await store.setIndexingPaused(false)
        let doc = try await store.importDocument(document("kept"), meetingID: meeting)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.reimport(document("discard"), id: doc.id, expectedRevision: doc.revision)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.snapshotText(id: doc.id) == "kept")
    }
}
