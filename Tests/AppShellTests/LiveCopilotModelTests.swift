import AgentKit
import CaptureKit
import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing
import TranscribeKit

@testable import AppShell

@MainActor
struct LiveCopilotModelTests {
    private func client(_ server: FakeOpenAIServer) -> OpenAICompatibleClient {
        OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
    }

    private func turn(
        source: AudioSource = .system,
        text: String = "Hoang, can you explain the migration risk?",
        start: TimeInterval = 60,
        end: TimeInterval = 62
    ) -> TranscriptTurn {
        TranscriptTurn(
            source: source,
            text: text,
            segmentIDs: [UUID()],
            tStart: start,
            tEnd: end
        )
    }

    @discardableResult
    private func waitUntil(
        _ label: String,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(label)")
        return false
    }

    private static func decision(
        action: String = "suggest_answer",
        confidence: Double = 0.96,
        target: String? = "migration risk"
    ) -> String {
        let targetJSON = target.map { "\"\($0)\"" } ?? "null"
        return "{\"action\":\"\(action)\",\"confidence\":\(confidence),\"target\":\(targetJSON)}"
    }

    private static func answer(_ text: String = "Mention the rollback plan.") -> FakeOpenAIServer.Response {
        .sse(frames: [
            OpenAIFixtures.contentDelta(text),
            OpenAIFixtures.finish(
                reason: "stop", promptTokens: 30, completionTokens: 6),
            OpenAIFixtures.done,
        ])
    }

    @Test func quietSystemTurnClassifiesThenStreamsOneProactiveCard() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: Self.decision())),
            Self.answer(),
        ])
        defer { server.stop() }
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: client(server),
            fastModel: "fake-fast",
            deepModel: "fake-deep",
            settings: LiveAISettings(preferredName: "Hoang")
        )

        model.receive(turn(), userSpeaking: false, now: Date(timeIntervalSince1970: 100))
        await waitUntil("completed suggestion") { model.card?.isStreaming == false }

        #expect(model.card?.action == .suggestAnswer)
        #expect(model.card?.text == "Mention the rollback plan.")
        #expect(model.card?.requested == false)
        #expect(server.recordedRequests.count == 2)
        #expect(server.recordedRequests[0].jsonBody?["model"] as? String == "fake-fast")
        #expect(server.recordedRequests[1].jsonBody?["model"] as? String == "fake-deep")
    }

    @Test func micUserSpeakingAndBelowQuietThresholdNeverGenerate() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: Self.decision(confidence: 0.89)))
        ])
        defer { server.stop() }
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: client(server), fastModel: "fast", deepModel: "deep",
            settings: LiveAISettings()
        )

        model.receive(turn(source: .mic), userSpeaking: false)
        model.receive(turn(text: "Could you repeat that?", start: 63, end: 64), userSpeaking: true)
        #expect(server.recordedRequests.isEmpty)

        model.receive(turn(text: "Could you repeat that?", start: 65, end: 66), userSpeaking: false)
        await waitUntil("classifier request") { server.recordedRequests.count == 1 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.card == nil)
        #expect(server.recordedRequests.count == 1)
    }

    @Test func explicitUserCommitmentStreamsACommitmentCard() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: Self.decision(
                    action: "flag_commitment",
                    target: "Send the runbook by Friday"))),
            Self.answer("Send the runbook by Friday."),
        ])
        defer { server.stop() }
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: client(server), fastModel: "fast", deepModel: "deep",
            settings: LiveAISettings(preferredName: "Hoang")
        )

        model.receive(turn(text: "Hoang, please send the runbook by Friday."), userSpeaking: false)
        await waitUntil("commitment completion") { model.card?.isStreaming == false }

        #expect(model.card?.action == .flagCommitment)
        #expect(model.card?.text == "Send the runbook by Friday.")
    }

    @Test func pauseRaceDoesNotCancelExplicitCatchUpAndRequestedCardDoesNotExpire() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.answer("Recent decisions and owners.")])
        defer { server.stop() }
        let model = LiveCopilotModel(proactiveLifetime: 0.02)
        model.beginMeeting(
            provider: client(server), fastModel: "fast", deepModel: "deep",
            settings: LiveAISettings(sensitivity: .off)
        )
        model.receive(turn(source: .mic, text: "context", start: 0, end: 61), userSpeaking: false)
        #expect(model.canCatchUp)

        model.requestCatchUp()
        // Deliberately synchronous with request admission, before its Task is
        // guaranteed an executor turn: this is the regression boundary.
        model.setAutomaticSuppressed(true)
        await waitUntil("catch-up completion") { model.card?.isStreaming == false }
        try? await Task.sleep(for: .milliseconds(60))

        #expect(model.card?.action == .catchUp)
        #expect(model.card?.requested == true)
        #expect(model.card?.text == "Recent decisions and owners.")
    }

    @Test func pausePreservesRequestedAskPlaceholder() async throws {
        let server = try FakeOpenAIServer.start(responses: [])
        defer { server.stop() }
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: client(server), fastModel: "fast", deepModel: "deep",
            settings: LiveAISettings()
        )

        model.requestAsk()
        model.setAutomaticSuppressed(true)

        #expect(model.askPlaceholderVisible)
        #expect(server.recordedRequests.isEmpty)
    }

    @Test func sensitivityOffClearsProactiveButPreservesRequestedCatchUp() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: Self.decision())),
            Self.answer(),
            Self.answer("The migration remains the open topic."),
        ])
        defer { server.stop() }
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: client(server), fastModel: "fast", deepModel: "deep",
            settings: LiveAISettings(sensitivity: .quiet)
        )
        model.receive(turn(), userSpeaking: false)
        await waitUntil("proactive completion") { model.card?.isStreaming == false }

        model.applyLiveSettings(LiveAISettings(sensitivity: .off))
        #expect(model.card == nil)

        model.requestCatchUp()
        model.applyLiveSettings(LiveAISettings(sensitivity: .off))
        await waitUntil("requested completion") { model.card?.isStreaming == false }
        #expect(model.card?.requested == true)
        #expect(model.card?.action == .catchUp)
    }

    @Test func globalAIOffCancelsAndClearsRequestedContent() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.answer("Catch-up")])
        defer { server.stop() }
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: client(server), fastModel: "fast", deepModel: "deep",
            settings: LiveAISettings()
        )
        model.receive(turn(source: .mic, text: "context", start: 0, end: 61), userSpeaking: false)
        model.requestCatchUp()
        model.applyLiveSettings(LiveAISettings(aiFeaturesEnabled: false))

        #expect(model.card == nil)
        #expect(model.availability == .disabled)
        #expect(!model.canCatchUp)
    }

    @Test func hoverOrFocusPausesThenResumesProactiveExpiry() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: Self.decision())),
            Self.answer(),
        ])
        defer { server.stop() }
        let model = LiveCopilotModel(proactiveLifetime: 0.08)
        model.beginMeeting(
            provider: client(server), fastModel: "fast", deepModel: "deep",
            settings: LiveAISettings()
        )
        model.receive(turn(), userSpeaking: false)
        await waitUntil("proactive completion") { model.card?.isStreaming == false }

        model.setCardInteractionActive(true)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(model.card != nil)

        model.setCardInteractionActive(false)
        await waitUntil("expiry after interaction") { model.card == nil }
    }

    @Test func capFailureShowsQuietPauseWithoutAProviderRequest() async throws {
        let server = try FakeOpenAIServer.start(responses: [])
        defer { server.stop() }
        let pricing = PricingTable(rates: [
            "fast": ModelPricing(
                inputPerMillionUSD: 1_000,
                cachedInputPerMillionUSD: 1_000,
                outputPerMillionUSD: 1_000),
        ])
        let meter = SpendMeter(
            ledger: InMemorySpendLedger(), pricing: pricing, capUSD: 0.000_001)
        let provider = MeteredProvider(upstream: client(server), meter: meter, meetingID: UUID())
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: provider, fastModel: "fast", deepModel: "deep",
            settings: LiveAISettings()
        )

        model.receive(turn(), userSpeaking: false)
        await waitUntil("cap pause") {
            if case .paused = model.availability { return true }
            return false
        }

        #expect(server.recordedRequests.isEmpty)
        guard case .paused(let message) = model.availability else {
            Issue.record("expected paused")
            return
        }
        #expect(message.contains("cap"))
    }
}
