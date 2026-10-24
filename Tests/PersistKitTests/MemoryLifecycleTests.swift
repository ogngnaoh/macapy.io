import Foundation
import GRDB
import MemoryKit
import Testing
import TranscribeKit
@testable import PersistKit

struct MemoryLifecycleTests {
    @Test func ephemeralAndActiveMeetingsCannotOptInOrAttachDocuments() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let memory = MemoryStore(database: database)
        let docs = DocumentStore(database: database)
        let active = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        let ephemeral = try await meetings.beginMeeting(startedAt: Date(), ephemeral: true)
        try await meetings.endMeeting(id: ephemeral.id, endedAt: Date())
        let doc = ParsedDocument(name: "x.txt", mediaType: "text/plain", pages: [.init(number: nil, text: "private context")])
        for id in [active.id, ephemeral.id] {
            await #expect(throws: MemoryStoreError.ineligibleMeeting) { try await memory.setOptIn(true, meetingID: id) }
            await #expect(throws: MemoryStoreError.ineligibleMeeting) { try await docs.importDocument(doc, meetingID: id) }
        }
        #expect(try await docs.documents().isEmpty)
    }

    @Test func rejectedFactsAndAmbiguousDatesRemainSeparateUntilExplicitSupersession() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let memory = MemoryStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(timeIntervalSince1970: 100), ephemeral: false)
        let segments = [
            Segment(id: UUID(), source: .mic, text: "Cedar releases Friday", tStart: 0, tEnd: 2),
            Segment(id: UUID(), source: .system, text: "Cedar releases Monday", tStart: 3, tEnd: 4),
        ]
        try await meetings.append(segments, to: meeting.id)
        try await meetings.endMeeting(id: meeting.id, endedAt: Date(timeIntervalSince1970: 200))
        try await memory.setOptIn(true, meetingID: meeting.id)
        let facts = try await memory.insertCandidates(segments.enumerated().map { index, segment in
            .init(kind: .decision, text: segment.text, statedAt: Date(timeIntervalSince1970: 101 + Double(index)),
                  sources: [.init(kind: .segment, sourceID: segment.id, revision: 0, meetingID: meeting.id,
                                  startCharacter: 0, endCharacter: segment.text.count)])
        }, meetingID: meeting.id)
        for fact in facts { try await memory.review(id: fact.id, expectedRevision: 0, status: .approved) }
        #expect(try await memory.retrieve(.init(query: "Cedar")).excerpts.count == 2, "Conflicting source statements are both retained")
        #expect(try await memory.retrieve(.init(query: "Cedar", asOf: Date(timeIntervalSince1970: 101))).excerpts.count == 1)
        let before = try await memory.retrieve(.init(query: "Cedar"))
        try await memory.supersede(id: facts[0].id, expectedRevision: 0)
        #expect(try await memory.retrieve(.init(query: "Friday")).isEmpty)
        #expect(try await memory.validate(before, for: .init(query: "Cedar")) == false)
        try await memory.review(id: facts[1].id, expectedRevision: 0, status: .rejected)
        #expect(try await memory.retrieve(.init(query: "Cedar")).isEmpty)
    }

    @Test func sourceDeletionAndDeleteEverythingRemoveAllNewNamespaces() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let memory = MemoryStore(database: database)
        let docs = DocumentStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(timeIntervalSince1970: 100), ephemeral: false)
        let segment = Segment(id: UUID(), source: .mic, text: "specific deletion canary", tStart: 0, tEnd: 1)
        try await meetings.append([segment], to: meeting.id)
        try await meetings.endMeeting(id: meeting.id, endedAt: Date(timeIntervalSince1970: 200))
        try await memory.setOptIn(true, meetingID: meeting.id)
        let entity = try await memory.createEntity(kind: .project, name: "Cedar")
        try await memory.linkEntity(entity.id, to: meeting.id)
        _ = try await memory.insertCandidates([
            .init(kind: .decision, text: segment.text, statedAt: Date(timeIntervalSince1970: 101),
                  sources: [.init(kind: .segment, sourceID: segment.id, revision: 0, meetingID: meeting.id, startCharacter: 0, endCharacter: segment.text.count)], entityIDs: [entity.id]),
        ], meetingID: meeting.id)
        _ = try await docs.importDocument(.init(name: "canary.txt", mediaType: "text/plain", pages: [.init(number: nil, text: "document deletion canary")]), meetingID: meeting.id)
        try await database.dbWriter.write { db in try db.execute(sql: "DELETE FROM segments WHERE id=?", arguments: [segment.id]) }
        #expect(try await memory.facts(meetingID: meeting.id).isEmpty)
        try await meetings.deleteAllUserData()
        #expect(try await memory.entities().isEmpty)
        #expect(try await docs.documents().isEmpty)
        let counts = try await database.dbWriter.read { db in
            try ["memory_meeting_optins", "memory_entities", "memory_aliases", "memory_meeting_entities", "memory_facts", "memory_fact_entities", "memory_fact_sources", "documents", "document_links", "document_chunks", "document_embeddings"].map {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)") ?? -1
            }
        }
        #expect(counts.allSatisfy { $0 == 0 })
    }

    @Test func duplicateImportsAndFailedReimportsKeepOneValidSnapshot() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await meetings.endMeeting(id: meeting.id, endedAt: Date())
        var limits = DocumentLimits(); limits.maximumCharacters = 20
        let docs = DocumentStore(database: database, limits: limits)
        let parsed = ParsedDocument(name: "x.txt", mediaType: "text/plain", pages: [.init(number: nil, text: "kept snapshot")])
        let first = try await docs.importDocument(parsed, meetingID: meeting.id)
        let again = try await docs.importDocument(parsed, meetingID: meeting.id)
        #expect(first.id == again.id)
        #expect(try await docs.documents().count == 1)
        await #expect(throws: MemoryStoreError.capacityExceeded) {
            try await docs.reimport(.init(name: "x.txt", mediaType: "text/plain", pages: [.init(number: nil, text: String(repeating: "oversized", count: 5))]), id: first.id, expectedRevision: first.revision)
        }
        #expect(try await docs.snapshotText(id: first.id) == "kept snapshot")
        try await docs.setAllowedForAI(true, id: first.id)
        let request = RetrievalRequest(query: "kept")
        let memory = MemoryStore(database: database)
        let held = try await memory.retrieve(request)
        try await docs.setAllowedForAI(false, id: first.id)
        #expect(try await memory.validate(held, for: request) == false)
    }
}
