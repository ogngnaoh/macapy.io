import AgentKit
import Foundation
import MemoryKit
import PersistKit
import ProviderKit
import Testing
import TranscribeKit
@testable import AppShell

@MainActor struct MemoryWorkspaceTests {
    private struct World {
        let database: MacapyDatabase
        let meeting: MeetingRecord
        let segment: Segment
        var memory: MemoryStore { .init(database: database) }
        var source: SourceReference { .init(kind: .segment, sourceID: segment.id, revision: 0, meetingID: meeting.id, startCharacter: 0, endCharacter: segment.text.count) }
        func addFact() async throws -> MemoryFact {
            try await memory.setOptIn(true, meetingID: meeting.id)
            let fact = try #require(try await memory.insertCandidates([
                .init(kind: .decision, text: "Cedar launches Friday", statedAt: meeting.startedAt, sources: [source]),
            ], meetingID: meeting.id).first)
            try await memory.review(id: fact.id, expectedRevision: fact.revision, status: .approved)
            return try #require(try await memory.facts(meetingID: meeting.id).first)
        }
    }
    private func world() async throws -> World {
        let database = try MacapyDatabase.inMemory(), store = MeetingStore(database: database)
        let meeting = try await store.beginMeeting(startedAt: Date(timeIntervalSince1970: 100), ephemeral: false)
        let segment = Segment(id: UUID(), source: .mic, text: "Cedar launches Friday", tStart: 0, tEnd: 1)
        try await store.append([segment], to: meeting.id)
        try await store.endMeeting(id: meeting.id, endedAt: Date(timeIntervalSince1970: 200))
        return .init(database: database, meeting: try #require(try await store.meeting(id: meeting.id)), segment: segment)
    }
    private func makeModel(_ world: World, provider: WorkspaceScriptProvider, changed: @escaping @MainActor () -> Void = {}) -> MemoryWorkspaceModel {
        .init(database: world.database, onSensitiveContentChanged: changed, makeProviderContext: { _ in
            .init(provider: provider, model: "synthetic", isCurrent: { true })
        })
    }

    @Test func extractionRequiresPreviewAndExplicitSendThenReview() async throws {
        let world = try await world()
        let provider = WorkspaceScriptProvider(json: """
            {"candidates":[{"kind":"decision","text":"Cedar launches Friday","source_ids":["\(world.segment.id.uuidString.lowercased())"]}]}
            """)
        let model = makeModel(world, provider: provider)
        await model.load()
        #expect(model.selectedMeetingID == world.meeting.id)
        #expect(!model.isOptedIn)
        await model.setOptIn(true)
        await model.prepareExtraction()
        #expect(model.extractionPreview.count == 1)
        #expect(provider.requestCount == 0)
        model.sendExtraction()
        await model.waitForOperations()
        #expect(provider.requestCount == 1)
        let fact = try #require(model.facts.first)
        #expect(fact.status == .pending)
        #expect(try await world.memory.retrieve(.init(query: "Cedar")).isEmpty)
        await model.review(fact, status: .approved)
        #expect(try await world.memory.retrieve(.init(query: "Cedar")).excerpts.count == 1)
        await model.showSource(try #require(fact.sources.first))
        #expect(model.sourcePreview?.text == world.segment.text)
    }

    @Test func localSearchDoesNotNeedProviderAndFilterChangesRequireNewPreview() async throws {
        let world = try await world()
        _ = try await world.addFact()
        let model = MemoryWorkspaceModel(database: world.database)
        await model.load()
        model.query = "Cedar"
        model.search(); await model.waitForOperations()
        #expect(model.contextPreview?.excerpts.count == 1)
        #expect(model.canSendAnswer)
        model.queryMeetingIDs = []
        #expect(!model.canSendAnswer)
        model.queryMeetingIDs = [world.meeting.id]
        model.sendQuestion(); await model.waitForOperations()
        #expect(model.answer == nil)
        #expect(model.notice?.contains("AI is unavailable") == true)
        model.query = "nonexistent"
        model.search(); await model.waitForOperations()
        #expect(model.answer == .insufficient)
    }

    @Test func deletedEvidenceCannotAppearAfterProviderReturns() async throws {
        let world = try await world(), fact = try await world.addFact()
        let citation = try #require(try await world.memory.retrieve(.init(query: "Cedar")).excerpts.first?.citationID)
        let gate = WorkspaceReplyGate()
        let provider = WorkspaceScriptProvider(json: answerJSON(citation), gate: gate)
        let model = makeModel(world, provider: provider)
        await model.load(); model.query = "Cedar"; model.search(); await model.waitForOperations()
        model.sendQuestion(); await gate.waitForCall()
        try await world.memory.deleteFact(id: fact.id)
        await gate.release(); await model.waitForOperations()
        #expect(model.answer == nil)
        #expect(model.errorMessage != nil)
    }

    @Test func revokedDocumentConsentIsRevalidatedAfterGeneration() async throws {
        let world = try await world()
        let docs = DocumentStore(database: world.database)
        let parsed = try await LocalDocumentParser().parse(data: Data("Cedar launches Friday".utf8), name: "Cedar.md", extension: "md")
        let document = try await docs.importDocument(parsed, meetingID: world.meeting.id)
        #expect(!document.allowedForAI)
        try await docs.setAllowedForAI(true, id: document.id)
        let citation = try #require(try await world.memory.retrieve(.init(query: "Cedar")).excerpts.first?.citationID)
        let gate = WorkspaceReplyGate(), provider = WorkspaceScriptProvider(json: answerJSON(citation), gate: gate)
        let model = makeModel(world, provider: provider)
        await model.load(); model.query = "Cedar"; model.search(); await model.waitForOperations()
        model.sendQuestion(); await gate.waitForCall()
        try await docs.setAllowedForAI(false, id: document.id)
        await gate.release(); await model.waitForOperations()
        #expect(model.answer == nil)
        #expect(model.errorMessage != nil)
    }

    @Test func turningOffMemoryCancelsLateExtractionAndClearsInspector() async throws {
        let world = try await world(), gate = WorkspaceReplyGate()
        let provider = WorkspaceScriptProvider(json: """
            {"candidates":[{"kind":"decision","text":"Cedar launches Friday","source_ids":["\(world.segment.id.uuidString.lowercased())"]}]}
            """, gate: gate)
        var clearCount = 0
        let model = makeModel(world, provider: provider, changed: { clearCount += 1 })
        await model.load(); await model.setOptIn(true); await model.prepareExtraction()
        model.sendExtraction(); await gate.waitForCall()
        let before = clearCount
        await model.setOptIn(false)
        #expect(clearCount > before)
        #expect(model.contextPreview == nil && model.extractionPreview.isEmpty)
        await gate.release(); await model.cancelAndDrain()
        #expect(try await world.memory.facts(meetingID: world.meeting.id).isEmpty)
        #expect(model.answer == nil && model.errorMessage == nil)
    }

    @Test func staleEditorDoesNotOverwriteAConcurrentCorrection() async throws {
        let world = try await world(), fact = try await world.addFact()
        let model = MemoryWorkspaceModel(database: world.database)
        await model.load()
        _ = try await world.memory.edit(id: fact.id, expectedRevision: fact.revision, text: "Cedar launches Monday")
        #expect(await model.edit(fact, text: "Cedar launches Tuesday") == false)
        #expect(model.errorMessage?.contains("changed while") == true)
        #expect(try await world.memory.facts(meetingID: world.meeting.id).first?.text == "Cedar launches Monday")
    }

    @Test func changedQuestionCannotReceiveOldAnswer() async throws {
        let world = try await world()
        _ = try await world.addFact()
        let citation = try #require(try await world.memory.retrieve(.init(query: "Cedar")).excerpts.first?.citationID)
        let gate = WorkspaceReplyGate(), provider = WorkspaceScriptProvider(json: answerJSON(citation), gate: gate)
        let model = makeModel(world, provider: provider)
        await model.load(); model.query = "Cedar"; model.search(); await model.waitForOperations()
        model.sendQuestion(); await gate.waitForCall()
        model.query = "Different question"
        await gate.release(); await model.waitForOperations()
        #expect(model.answer == nil)
        #expect(!model.canSendAnswer)
    }

    @Test func forgetAllContentPurgesSnapshotsAndFencesLateAnswers() async throws {
        let world = try await world()
        _ = try await world.addFact()
        let entity = try await world.memory.createEntity(kind: .project, name: "Cedar")
        try await world.memory.linkEntity(entity.id, to: world.meeting.id)
        let docs = DocumentStore(database: world.database)
        let parsed = try await LocalDocumentParser().parse(data: Data("Cedar context".utf8), name: "Cedar.md", extension: "md")
        _ = try await docs.importDocument(parsed, meetingID: world.meeting.id)
        let citation = try #require(try await world.memory.retrieve(.init(query: "Cedar")).excerpts.first?.citationID)
        let gate = WorkspaceReplyGate(), provider = WorkspaceScriptProvider(json: answerJSON(citation), gate: gate)
        let model = makeModel(world, provider: provider)
        await model.load(); model.query = "Cedar"; model.search(); await model.waitForOperations()
        model.sendQuestion(); await gate.waitForCall()
        model.forgetAllContent()
        #expect(model.meetings.isEmpty && model.selectedMeetingID == nil)
        #expect(model.facts.isEmpty && model.entities.isEmpty && model.linkedEntities.isEmpty)
        #expect(model.documents.isEmpty && model.documentLibrary.isEmpty)
        #expect(model.query.isEmpty && model.queryMeetingIDs.isEmpty && model.queryDocumentIDs.isEmpty)
        #expect(model.queryEntityID == nil && !model.useAsOfDate)
        #expect(model.contextPreview == nil && model.sourcePreview == nil && model.extractionPreview.isEmpty)
        await gate.release(); await model.waitForOperations()
        #expect(model.answer == nil && model.contextPreview == nil && model.errorMessage == nil)
        #expect(model.meetings.isEmpty && model.facts.isEmpty)
    }

    @Test func activeCaptureRejectsImportBeforeFileAccess() async throws {
        let world = try await world()
        let model = MemoryWorkspaceModel(database: world.database, isMeetingActive: { true })
        await model.load()
        model.importDocument(url: URL(fileURLWithPath: "/does-not-exist/Cedar.md"))
        #expect(model.errorMessage?.contains("paused") == true)
        #expect(!model.isWorking)
        #expect(model.documents.isEmpty)
    }

    private func answerJSON(_ citation: String) -> String {
        "{\"answer\":\"Cedar launches Friday\",\"insufficient_evidence\":false,\"citation_ids\":[\"\(citation)\"]}"
    }
}

private final class WorkspaceScriptProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let json: String
    private let gate: WorkspaceReplyGate?
    init(json: String, gate: WorkspaceReplyGate? = nil) { self.json = json; self.gate = gate }
    var requestCount: Int { lock.withLock { calls } }
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> { .init { $0.finish() } }
    func completeReportingUsage<T: Decodable>(_ request: CompletionRequest, as type: T.Type) async throws -> CompletedCall<T> {
        lock.withLock { calls += 1 }
        await gate?.hold()
        return .init(value: try JSONDecoder().decode(type, from: Data(json.utf8)), usage: nil)
    }
}
private actor WorkspaceReplyGate {
    private var reply: CheckedContinuation<Void, Never>?
    private var arrival: [CheckedContinuation<Void, Never>] = []
    private var called = false
    func hold() async {
        called = true
        for waiter in arrival { waiter.resume() }; arrival = []
        await withCheckedContinuation { reply = $0 }
    }
    func waitForCall() async { if !called { await withCheckedContinuation { arrival.append($0) } } }
    func release() { reply?.resume(); reply = nil }
}
