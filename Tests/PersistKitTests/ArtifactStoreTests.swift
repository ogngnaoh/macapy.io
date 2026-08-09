import Foundation
import GRDB
import Testing

@testable import PersistKit

/// Schema v3 + `ArtifactStore`: drafts land transactionally, status flips
/// touch exactly one cell (acceptance check 3's row-diff-only oracle), and
/// deleting a meeting cascades its artifacts (SPEC §6.2 invariant).
struct ArtifactStoreTests {

    private func drafts() throws -> [DraftArtifact] {
        [
            try DraftArtifact(kind: .summary, encoding: SummaryPayload(text: "we agreed the plan")),
            try DraftArtifact(kind: .decision, encoding: DecisionPayload(text: "cut over Aug 3")),
            try DraftArtifact(
                kind: .actionItem,
                encoding: ActionItemPayload(title: "draft runbook", owner: "You", deadline: "Thursday")),
        ]
    }

    @Test func insertedDraftsRoundTripInOrderWithDraftStatus() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let store = ArtifactStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)

        try await store.insertDrafts(try drafts(), meetingID: meeting.id)

        let rows = try await store.artifacts(for: meeting.id)
        #expect(rows.map(\.artifactKind) == [.summary, .decision, .actionItem])
        #expect(rows.allSatisfy { $0.artifactStatus == .draft })
        #expect(rows[0].payload(as: SummaryPayload.self) == SummaryPayload(text: "we agreed the plan"))
        #expect(rows[1].payload(as: DecisionPayload.self) == DecisionPayload(text: "cut over Aug 3"))
        #expect(rows[2].payload(as: ActionItemPayload.self)
            == ActionItemPayload(title: "draft runbook", owner: "You", deadline: "Thursday"))
    }

    @Test func actionItemWithNothingStatedKeepsNilOwnerAndDeadline() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let store = ArtifactStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)

        try await store.insertDrafts(
            [try DraftArtifact(
                kind: .actionItem,
                encoding: ActionItemPayload(title: "share the report", owner: nil, deadline: nil))],
            meetingID: meeting.id)

        let payload = try #require(
            try await store.artifacts(for: meeting.id).first?.payload(as: ActionItemPayload.self))
        #expect(payload.owner == nil)
        #expect(payload.deadline == nil)
    }

    /// Acceptance check 3 (and live check 10's machine half): approve flips
    /// status to `approved`, reject to `rejected`, and **nothing else in the
    /// database changes** — asserted against a full dump of every user table,
    /// not just the artifacts table.
    @Test func statusFlipChangesExactlyThatOneCell() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let store = ArtifactStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        let inserted = try await store.insertDrafts(try drafts(), meetingID: meeting.id)

        let before = try dump(database)
        let hitsBefore = try searchHits(database)
        try await store.setStatus(.approved, id: inserted[1].id)
        let afterApprove = try dump(database)

        var expected = before
        expected["artifacts"]![key(for: inserted[1].id)]!["status"] = Self.describe("approved".databaseValue)
        #expect(afterApprove == expected)

        try await store.setStatus(.rejected, id: inserted[2].id)
        expected["artifacts"]![key(for: inserted[2].id)]!["status"] = Self.describe("rejected".databaseValue)
        #expect(try dump(database) == expected)

        // Slice-5 check 12: flips are index-inert — `searchText` is covered
        // by the row-diff above; the FTS hits themselves are pinned here.
        #expect(try searchHits(database) == hitsBefore)
        #expect(!hitsBefore.isEmpty)
    }

    /// Every artifact rowid matching this suite's payload vocabulary, in
    /// rowid order — a stable fingerprint of the artifacts FTS index.
    private func searchHits(_ database: MacapyDatabase) throws -> [Int64] {
        try database.dbWriter.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT rowid FROM artifacts_fts
                    WHERE artifacts_fts MATCH 'plan OR cut OR runbook OR Thursday'
                    ORDER BY rowid
                    """)
        }
    }

    @Test func settingStatusForAnUnknownIDChangesNothing() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let store = ArtifactStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await store.insertDrafts(try drafts(), meetingID: meeting.id)

        let before = try dump(database)
        try await store.setStatus(.approved, id: UUID())
        #expect(try dump(database) == before)
    }

    @Test func deletingAMeetingCascadesItsArtifacts() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let store = ArtifactStore(database: database)
        let kept = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        let deleted = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await store.insertDrafts(try drafts(), meetingID: kept.id)
        try await store.insertDrafts(try drafts(), meetingID: deleted.id)

        try await meetings.deleteMeeting(id: deleted.id)

        #expect(try await store.artifacts(for: deleted.id).isEmpty)
        #expect(try await store.artifacts(for: kept.id).count == 3)
    }

    @Test func artifactsForAMeetingWithNoneIsEmpty() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let store = ArtifactStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)

        #expect(try await store.artifacts(for: meeting.id).isEmpty)
    }

    // Row-diff plumbing lives in the shared DatabaseDump helper since slice 5
    // (the deletion oracles use it too); these wrappers keep the existing
    // assertions reading as before.
    private func dump(_ database: MacapyDatabase) throws -> [String: [String: [String: String]]] {
        try DatabaseDump.dump(database)
    }

    private func key(for id: UUID) -> String {
        DatabaseDump.key(for: id)
    }

    private static func describe(_ value: DatabaseValue) -> String {
        DatabaseDump.describe(value)
    }
}
