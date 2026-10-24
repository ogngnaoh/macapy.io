import Foundation
import GRDB
import Testing

@testable import PersistKit

struct ArtifactEditingTests {
    private func fixture() async throws -> (MacapyDatabase, ArtifactStore, MeetingRecord, [ArtifactRecord]) {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let store = ArtifactStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        let rows = try await store.insertDrafts([
            try DraftArtifact(kind: .summary, encoding: SummaryPayload(text: "oldsummary")),
            try DraftArtifact(kind: .decision, encoding: DecisionPayload(text: "olddecision")),
            try DraftArtifact(kind: .actionItem, encoding: ActionItemPayload(
                title: "oldaction", owner: "oldowner", deadline: "olddeadline")),
        ], meetingID: meeting.id)
        return (database, store, meeting, rows)
    }

    @Test func correctionUpdatesPayloadSearchAndReviewAtomically() async throws {
        let (database, store, meeting, rows) = try await fixture()
        let search = SearchStore(database: database)
        try await store.setStatus(.approved, id: rows[2].id)
        _ = try await store.setCompletion(true, id: rows[2].id, expectedRevision: 0)
        let edited = try await store.edit(id: rows[2].id, expectedRevision: 0,
                                         content: .actionItem(title: "  newaction  ", owner: "newowner", deadline: nil))
        #expect(edited.revision == 1)
        #expect(edited.isUserEdited)
        #expect(edited.artifactStatus == .draft)
        #expect(edited.isComplete, "Content edits do not infer that an explicit completion was undone")
        #expect(edited.payload(as: ActionItemPayload.self) == .init(title: "newaction", owner: "newowner", deadline: nil))
        #expect(edited.searchText == "newaction newowner")
        #expect(try await search.search(matching: "oldaction").isEmpty)
        #expect(try await search.search(matching: "oldowner").isEmpty)
        #expect(try await search.search(matching: "olddeadline").isEmpty)
        #expect(try await search.search(matching: "newowner").artifacts.map(\.artifactID) == [edited.id])
        #expect(try await store.artifacts(for: meeting.id).count == 3)
    }

    @Test func staleEditReviewAndCompletionCannotChangeCorrectedContent() async throws {
        let (database, store, _, rows) = try await fixture()
        _ = try await store.edit(id: rows[2].id, expectedRevision: 0,
                                content: .actionItem(title: "corrected", owner: nil, deadline: nil))
        let before = try DatabaseDump.dump(database)
        await #expect(throws: ArtifactStoreError.revisionConflict) {
            try await store.edit(id: rows[2].id, expectedRevision: 0, content: .actionItem(title: "stale", owner: nil, deadline: nil))
        }
        await #expect(throws: ArtifactStoreError.revisionConflict) {
            try await store.setStatus(.approved, id: rows[2].id, expectedRevision: 0)
        }
        await #expect(throws: ArtifactStoreError.revisionConflict) {
            try await store.setCompletion(true, id: rows[2].id, expectedRevision: 0)
        }
        #expect(try DatabaseDump.dump(database) == before)
    }

    @Test func completionIsIndependentOfReviewAndRejectsNonTasks() async throws {
        let (_, store, _, rows) = try await fixture()
        try await store.setStatus(.approved, id: rows[2].id)
        let done = try await store.setCompletion(true, id: rows[2].id, expectedRevision: 0)
        #expect(done.artifactStatus == .approved)
        #expect(done.revision == 0)
        #expect(done.editedAt == nil)
        #expect(done.isComplete)
        let repeatDone = try await store.setCompletion(true, id: done.id, expectedRevision: 0)
        #expect(done == repeatDone, "Repeated completion must not alter its completion date")
        let reopened = try await store.setCompletion(false, id: done.id, expectedRevision: 0)
        #expect(!reopened.isComplete)
        #expect(reopened.artifactStatus == .approved)
        await #expect(throws: ArtifactStoreError.notAnActionItem) {
            try await store.setCompletion(true, id: rows[0].id, expectedRevision: 0)
        }
    }

    @Test func blankAndKindChangingEditsFailWithoutWrites() async throws {
        let (database, store, _, rows) = try await fixture()
        let before = try DatabaseDump.dump(database)
        await #expect(throws: ArtifactStoreError.emptyContent) {
            try await store.edit(id: rows[0].id, expectedRevision: 0, content: .summary(" \n "))
        }
        await #expect(throws: ArtifactStoreError.kindMismatch) {
            try await store.edit(id: rows[0].id, expectedRevision: 0, content: .decision("change kind"))
        }
        #expect(try DatabaseDump.dump(database) == before)
        let noChange = try await store.edit(id: rows[0].id, expectedRevision: 0, content: .summary("oldsummary"))
        #expect(noChange == rows[0])
    }

    @Test func newGenerationCannotOverwriteOrAppendToHumanCorrection() async throws {
        let (_, store, meeting, rows) = try await fixture()
        _ = try await store.edit(id: rows[0].id, expectedRevision: 0, content: .summary("human correction"))
        let before = try await store.artifacts(for: meeting.id)
        await #expect(throws: ArtifactStoreError.existingArtifacts) {
            try await store.insertDrafts([try DraftArtifact(kind: .summary, encoding: SummaryPayload(text: "new generation"))], meetingID: meeting.id)
        }
        #expect(try await store.artifacts(for: meeting.id) == before)
    }

    @Test func legacyRowsMigrateWithoutPayloadOrSearchLoss() async throws {
        let queue = try DatabaseQueue()
        try MacapyDatabase.migrator.migrate(queue, upTo: "v5-search")
        let meetingID = UUID(), artifactID = UUID()
        let payload = #"{"title":"retain this","owner":null,"deadline":null}"#
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO meetings(id,title,startedAt,endedAt,status,ephemeral) VALUES(?, ?, ?, ?, ?, ?)",
                           arguments: [meetingID, "legacy", Date(), Date(), "ended", false])
            try db.execute(sql: "INSERT INTO artifacts(id,meetingID,kind,payload,status,createdAt,searchText) VALUES(?, ?, ?, ?, ?, ?, ?)",
                           arguments: [artifactID, meetingID, "action_item", payload, "approved", Date(), "retain this"])
        }
        try MacapyDatabase.migrator.migrate(queue)
        let store = ArtifactStore(database: .init(dbWriter: queue))
        let row = try #require(try await store.artifacts(for: meetingID).first)
        #expect(row.payload == payload)
        #expect(row.revision == 0)
        #expect(!row.isUserEdited && !row.isComplete)
        #expect(row.artifactStatus == .approved)
        #expect(row.searchText == "retain this")
    }

    @Test func olderCodableArtifactDefaultsCorrectionMetadata() throws {
        let row = ArtifactRecord(id: UUID(), meetingID: UUID(), kind: "summary", payload: #"{"text":"old"}"#,
                                 status: "draft", createdAt: Date(timeIntervalSince1970: 100))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        object.removeValue(forKey: "revision")
        object.removeValue(forKey: "editedAt")
        object.removeValue(forKey: "completedAt")
        object.removeValue(forKey: "searchText")
        let decoded = try JSONDecoder().decode(ArtifactRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == row)
    }
}
