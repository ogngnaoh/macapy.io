import AgentKit
import Foundation
import MemoryKit
import PersistKit
import ProviderKit
import Testing
import TranscribeKit
@testable import AppShell

@MainActor struct LiveAskSourcesTests {
    private func setup(gate: LiveSourcesReplyGate? = nil, external: Bool = true) async throws -> (SampleSession, LiveCopilotModel, LiveSourcesProvider) {
        let sample = try await SampleSession.make(), provider = LiveSourcesProvider(gate: gate)
        let model = LiveCopilotModel()
        model.beginMeeting(meetingID: sample.featuredMeeting.id, provider: provider, fastModel: "scripted", deepModel: "scripted",
            settings: .init(sensitivity: .off), sourceDatabase: external ? sample.database : nil)
        for segment in SampleScenario.segments {
            await model.receive(.init(id: segment.id, source: segment.source, text: segment.text, segmentIDs: [segment.id], tStart: segment.tStart, tEnd: segment.tEnd), userSpeaking: false)
        }
        model.requestAsk(); model.queryText = "Atlas launch"
        return (sample, model, provider)
    }
    private func picker(_ model: LiveCopilotModel) async throws -> LiveAskSourcesModel {
        model.openSources()
        try await waitUntil { model.sourcePicker != nil }
        let picker = try #require(model.sourcePicker)
        await picker.load()
        return picker
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func previewIsLocalAndExplicitSendUsesExistingLiveRequestWithCitations() async throws {
        let (sample, model, provider) = try await setup()
        defer { sample.close(); model.stopMeeting() }
        let picker = try await picker(model)
        #expect(picker.selectedMeetingIDs.isEmpty && picker.selectedDocumentIDs.isEmpty)
        picker.search(); await picker.waitForSearch()
        #expect(picker.results?.isEmpty == true)
        picker.selectedMeetingIDs = [sample.featuredMeeting.id]
        picker.selectedDocumentIDs = Set(picker.documents.map(\.id))
        picker.search(); await picker.waitForSearch()
        #expect(picker.results?.isEmpty == false)
        #expect(provider.calls == 0)
        #expect(picker.selectedCharacters <= 8_000)
        #expect(await picker.send())
        try await waitUntil { model.card?.isStreaming == false }
        let card = try #require(model.card)
        #expect(!card.evidence.isEmpty)
        #expect(provider.calls == 1)
        let request = try #require(provider.requests.first)
        #expect(request.purpose == .generation)
        #expect(request.maxTokens == 400)
        #expect(request.contextSources.contains(.transcript))
        #expect(request.contextSources.contains(.reviewedMemory))
        #expect(request.contextSources.contains(.selectedDocuments))
        let ownership = await model.arbiterOwnershipForTesting()
        #expect(ownership.active == nil && ownership.retained?.priority == .userRequest)
        await model.previewGrounding(try #require(card.evidence.first))
        #expect(model.groundingPreview != nil)
        model.invalidateGrounding()
        #expect(model.card == nil && model.groundingPreview == nil)
    }

    @Test func sourceRevocationWhileProviderWaitsDropsAnswerAndDoesNotBlockTranscript() async throws {
        let gate = LiveSourcesReplyGate()
        let (sample, model, _) = try await setup(gate: gate)
        defer { sample.close(); model.stopMeeting() }
        let picker = try await picker(model)
        picker.selectedMeetingIDs = [sample.featuredMeeting.id]
        picker.selectedDocumentIDs = Set(picker.documents.map(\.id))
        picker.search(); await picker.waitForSearch()
        #expect(await picker.send())
        await gate.waitForCall()
        let before = ContinuousClock.now
        await model.receive(.init(id: UUID(), source: .mic, text: "Capture continues while AI waits", segmentIDs: [], tStart: 200, tEnd: 202), userSpeaking: false)
        #expect(before.duration(to: ContinuousClock.now) < .seconds(1))
        #expect(model.latestTranscriptTime == 202)
        let document = try #require(picker.documents.first)
        try await DocumentStore(database: sample.database).setAllowedForAI(false, id: document.id)
        await gate.release()
        try await waitUntil { model.card == nil }
        #expect(model.groundingPreview == nil)
    }

    @Test func aiOffAndStopClearPreparedSourcesWithoutProviderDispatch() async throws {
        let (sample, model, provider) = try await setup()
        defer { sample.close(); model.stopMeeting() }
        _ = try await picker(model)
        await model.applyLiveSettings(.init(aiFeaturesEnabled: false))
        #expect(model.sourcePicker == nil && model.groundingPreview == nil)
        #expect(provider.calls == 0)
        await model.applyLiveSettings(.init(aiFeaturesEnabled: true, sensitivity: .off))
        model.requestAsk(); model.queryText = "Atlas"
        _ = try await picker(model)
        await model.stopMeetingAndWait()
        #expect(model.sourcePicker == nil && !model.sourceLookupAvailable)
        #expect(provider.calls == 0)
    }

    @Test func ephemeralCompositionNeverOffersPersistedSourceLookup() async throws {
        let (sample, model, provider) = try await setup(external: false)
        defer { sample.close(); model.stopMeeting() }
        #expect(model.canSubmitAsk)
        #expect(!model.canOpenSources && !model.sourceLookupAvailable)
        model.openSources()
        #expect(model.sourcePicker == nil && provider.calls == 0)
        #expect(await model.submitAsk())
        try await waitUntil { model.card?.isStreaming == false }
        #expect(model.card?.evidence.isEmpty == true)
    }
}

private final class LiveSourcesProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [CompletionRequest] = []
    private let gate: LiveSourcesReplyGate?
    init(gate: LiveSourcesReplyGate? = nil) { self.gate = gate }
    var calls: Int { lock.withLock { captured.count } }
    var requests: [CompletionRequest] { lock.withLock { captured } }
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.withLock { captured.append(request) }
        return SampleProvider().stream(request)
    }
    func completeReportingUsage<T: Decodable>(_ request: CompletionRequest, as type: T.Type) async throws -> CompletedCall<T> {
        lock.withLock { captured.append(request) }
        await gate?.hold()
        return try await SampleProvider().completeReportingUsage(request, as: type)
    }
}
private actor LiveSourcesReplyGate {
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
