import Foundation
import MemoryKit
import Testing
import TranscribeKit
@testable import PersistKit

struct MemoryStoreTests {
    private func fixture() async throws -> (MacapyDatabase, MeetingRecord, SourceReference) {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(timeIntervalSince1970: 100), ephemeral: false)
        let segment = Segment(id: UUID(), source: .mic, text: "Cedar launch is Friday", tStart: 0, tEnd: 1)
        try await meetings.append([segment], to: meeting.id)
        try await meetings.endMeeting(id: meeting.id, endedAt: Date(timeIntervalSince1970: 200))
        return (database, meeting, .init(kind: .segment, sourceID: segment.id, revision: 0, meetingID: meeting.id,
                                         startCharacter: 0, endCharacter: segment.text.count))
    }

    @Test func consentAndReviewAreRequiredAndSourceDeletionInvalidatesSnapshots() async throws {
        let (database, meeting, source) = try await fixture()
        let store = MemoryStore(database: database)
        let candidate = MemoryCandidate(kind: .decision, text: "Cedar launches Friday", statedAt: meeting.startedAt, sources: [source])
        await #expect(throws: MemoryStoreError.notOptedIn) { try await store.insertCandidates([candidate], meetingID: meeting.id) }
        try await store.setOptIn(true, meetingID: meeting.id)
        let fact = try #require(try await store.insertCandidates([candidate], meetingID: meeting.id).first)
        let request = RetrievalRequest(query: "Cedar")
        #expect(try await store.retrieve(request).isEmpty)
        try await store.review(id: fact.id, expectedRevision: 0, status: .approved)
        let context = try await store.retrieve(request)
        #expect(context.excerpts.count == 1)
        #expect(try await store.validate(context, for: request))
        try await MeetingStore(database: database).deleteMeeting(id: meeting.id)
        #expect(try await store.retrieve(request).isEmpty)
        #expect(try await store.facts(meetingID: meeting.id).isEmpty)
        #expect(try await store.validate(context, for: request) == false)
    }

    @Test func correctionsRequireNewReviewAndStaleEditsFail() async throws {
        let (database, meeting, source) = try await fixture()
        let store = MemoryStore(database: database)
        try await store.setOptIn(true, meetingID: meeting.id)
        let fact = try #require(try await store.insertCandidates([
            .init(kind: .commitment, text: "Cedar Friday", statedAt: meeting.startedAt, sources: [source]),
        ], meetingID: meeting.id).first)
        try await store.review(id: fact.id, expectedRevision: 0, status: .approved)
        _ = try await store.edit(id: fact.id, expectedRevision: 0, text: "Cedar Monday")
        #expect(try await store.retrieve(.init(query: "Cedar")).isEmpty)
        await #expect(throws: MemoryStoreError.revisionConflict) { try await store.review(id: fact.id, expectedRevision: 0, status: .approved) }
        try await store.review(id: fact.id, expectedRevision: 1, status: .approved)
        #expect(try await store.retrieve(.init(query: "Monday")).excerpts.count == 1)
        #expect(try await store.retrieve(.init(query: "Friday")).isEmpty)
        try await store.setOptIn(false, meetingID: meeting.id)
        #expect(try await store.facts(meetingID: meeting.id).isEmpty)
    }

    @Test func aliasesCannotImplicitlyMergeDifferentPeople() async throws {
        let (database, meeting, _) = try await fixture()
        let store = MemoryStore(database: database)
        let first = try await store.createEntity(kind: .person, name: "Mina")
        let second = try await store.createEntity(kind: .person, name: "Jordan")
        try await store.addAlias("M", to: first.id)
        await #expect(throws: MemoryStoreError.aliasCollision) { try await store.addAlias(" m ", to: second.id) }
        try await store.linkEntity(first.id, to: meeting.id)
        #expect(try await store.entities(meetingID: meeting.id).map(\.id) == [first.id])
        try await store.mergeEntity(second.id, into: first.id)
        #expect(try await store.entities().count == 1)
        #expect(try await store.resolveEntity("Jordan", kind: .person)?.id == first.id)
    }

    @Test func rejectedSourcesAndForeignSourceIDsCannotEnterMemory() async throws {
        let (database, meeting, source) = try await fixture()
        let store = MemoryStore(database: database)
        try await store.setOptIn(true, meetingID: meeting.id)
        let forged = SourceReference(kind: .segment, sourceID: source.sourceID, revision: 0, meetingID: UUID(), startCharacter: 0, endCharacter: 1)
        await #expect(throws: MemoryStoreError.invalidSource) {
            try await store.insertCandidates([.init(kind: .decision, text: "forged", statedAt: meeting.startedAt, sources: [forged])], meetingID: meeting.id)
        }
        let artifactStore = ArtifactStore(database: database)
        let artifact = try #require(try await artifactStore.insertDrafts([
            try DraftArtifact(kind: .decision, encoding: DecisionPayload(text: "Cedar Friday")),
        ], meetingID: meeting.id).first)
        let ref = SourceReference(kind: .artifact, sourceID: artifact.id, revision: 0, meetingID: meeting.id, startCharacter: 0, endCharacter: 12)
        let fact = try #require(try await store.insertCandidates([.init(kind: .decision, text: "Cedar Friday", statedAt: meeting.startedAt, sources: [ref])], meetingID: meeting.id).first)
        try await store.review(id: fact.id, expectedRevision: 0, status: .approved)
        _ = try await artifactStore.edit(id: artifact.id, expectedRevision: 0, content: .decision("Cedar Monday"))
        #expect(try await store.facts(meetingID: meeting.id).isEmpty)
        await #expect(throws: MemoryStoreError.invalidSource) { try await store.insertCandidates([.init(kind: .decision, text: "old", statedAt: meeting.startedAt, sources: [ref])], meetingID: meeting.id) }
    }
}
