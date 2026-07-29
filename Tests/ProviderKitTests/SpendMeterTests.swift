import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// Acceptance check 6: every call writes one ledger row with the right purpose
/// and token counts; est-cost math is exact; a call attempted past the cap is
/// refused with the typed cap error and writes no row.
///
/// The cap is PRD FR-015's promise and SPEC §9's kill switch: it halts AI, and
/// only AI. Nothing here can reach capture or transcription — the meter is
/// consulted by the provider decorator alone.
struct SpendMeterTests {

    private static let meeting = UUID()
    private static let otherMeeting = UUID()

    /// Explicit rates, never the shipped defaults: this test must pin the
    /// arithmetic, not whatever price list is current.
    private static let pricing = PricingTable(rates: [
        "fake-model": ModelPricing(
            inputPerMillionUSD: 1.00,
            cachedInputPerMillionUSD: 0.10,
            outputPerMillionUSD: 3.00
        )
    ])

    private func fixture(
        capUSD: Double? = nil,
        responses: [FakeOpenAIServer.Response]
    ) throws -> (server: FakeOpenAIServer, provider: MeteredProvider, ledger: InMemorySpendLedger) {
        let server = try FakeOpenAIServer.start(responses: responses)
        let ledger = InMemorySpendLedger()
        let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: capUSD)
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
        let provider = MeteredProvider(upstream: client, meter: meter, meetingID: Self.meeting)
        return (server, provider, ledger)
    }

    private static var streamedReply: FakeOpenAIServer.Response {
        .sse(frames: [
            OpenAIFixtures.contentDelta("hello"),
            OpenAIFixtures.finish(reason: "stop", promptTokens: 1_000, completionTokens: 500, cachedTokens: 800),
            OpenAIFixtures.done,
        ])
    }

    // MARK: - Cost math

    @Test func estimatedCostBillsCachedPromptTokensAtTheCachedRate() {
        let usage = TokenUsage(promptTokens: 1_000, cachedTokens: 800, completionTokens: 500)

        let cost = Self.pricing.estimatedCostUSD(model: "fake-model", usage: usage)

        // 200 fresh input @ $1/M = 0.0002; 800 cached @ $0.10/M = 0.00008;
        // 500 output @ $3/M = 0.0015 → 0.00178
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - 0.00178) < 1e-9)
    }

    @Test func costIsUnknownRatherThanZeroForAModelWithNoPublishedRate() {
        let usage = TokenUsage(promptTokens: 1_000, cachedTokens: 0, completionTokens: 500)

        #expect(Self.pricing.estimatedCostUSD(model: "some-new-model", usage: usage) == nil)
    }

    // MARK: - Ledger rows

    @Test func aStreamedCallWritesExactlyOneLedgerRow() async throws {
        let (server, provider, ledger) = try fixture(responses: [Self.streamedReply])
        defer { server.stop() }

        var request = CompletionRequest.hello
        request.purpose = .artifact
        for try await _ in provider.stream(request) {}

        let entries = await ledger.entries
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.meetingID == Self.meeting)
        #expect(entry.model == "fake-model")
        #expect(entry.purpose == .artifact)
        #expect(entry.usage == TokenUsage(promptTokens: 1_000, cachedTokens: 800, completionTokens: 500))
        #expect(abs((entry.estCostUSD ?? 0) - 0.00178) < 1e-9)
    }

    @Test func aStructuredCallWritesItsOwnLedgerRow() async throws {
        let (server, provider, ledger) = try fixture(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"answer":"yes"}"#,
                promptTokens: 200,
                completionTokens: 20
            ))
        ])
        defer { server.stop() }

        struct Reply: Codable { let answer: String }
        var request = CompletionRequest.hello
        request.purpose = .classifier
        _ = try await provider.complete(request, as: Reply.self)

        let entries = await ledger.entries
        #expect(entries.count == 1)
        #expect(entries.first?.purpose == .classifier)
        #expect(entries.first?.usage == TokenUsage(promptTokens: 200, cachedTokens: 0, completionTokens: 20))
    }

    @Test func aFailedCallThatReportedNoUsageWritesNoRow() async throws {
        let (server, provider, ledger) = try fixture(responses: [
            .json(status: 503, body: OpenAIFixtures.errorBody(message: "down"))
        ])
        defer { server.stop() }

        _ = try? await Self.drain(provider)

        let entries = await ledger.entries
        #expect(entries.isEmpty, "nothing was billed, so nothing may appear in the ledger")
    }

    // MARK: - The cap

    @Test func aCallPastTheCapIsRefusedWithTheTypedErrorAndWritesNoRow() async throws {
        let ledger = InMemorySpendLedger()
        try await ledger.record(SpendEntry(
            id: UUID(),
            meetingID: Self.meeting,
            model: "fake-model",
            usage: TokenUsage(promptTokens: 1_000, cachedTokens: 0, completionTokens: 1_000),
            estCostUSD: 0.30,
            purpose: .generation,
            at: Date()
        ))
        let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: 0.25)
        // A session that records any attempt: the refusal must happen *before*
        // a request exists, not after a wasted round trip.
        RecordingURLProtocol.reset()
        let client = OpenAICompatibleClient(
            profile: .fake(baseURL: URL(string: "https://example.invalid/v1")!),
            apiKey: "sk-test",
            session: RecordingURLProtocol.session()
        )
        let provider = MeteredProvider(upstream: client, meter: meter, meetingID: Self.meeting)

        var thrown: Error?
        do { _ = try await Self.drain(provider) } catch { thrown = error }

        guard case .capReached = thrown as? ProviderError else {
            Issue.record("expected ProviderError.capReached, got \(String(describing: thrown))")
            return
        }
        let entries = await ledger.entries
        #expect(entries.count == 1, "the refused call must not add a row")
        #expect(RecordingURLProtocol.recordedRequests.isEmpty, "a capped call must not reach the network")
    }

    @Test func spendFromOtherMeetingsDoesNotCountTowardThisMeetingsCap() async throws {
        let ledger = InMemorySpendLedger()
        try await ledger.record(SpendEntry(
            id: UUID(),
            meetingID: Self.otherMeeting,
            model: "fake-model",
            usage: TokenUsage(promptTokens: 1_000, cachedTokens: 0, completionTokens: 1_000),
            estCostUSD: 5.00,
            purpose: .generation,
            at: Date()
        ))
        let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: 0.25)
        let server = try FakeOpenAIServer.start(responses: [Self.streamedReply])
        defer { server.stop() }
        let provider = MeteredProvider(
            upstream: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            meter: meter,
            meetingID: Self.meeting
        )

        let events = try await Self.drain(provider)

        #expect(events.contains(.token("hello")))
    }

    @Test func withNoCapSetCallsAreNeverRefused() async throws {
        let (server, provider, _) = try fixture(capUSD: nil, responses: [Self.streamedReply])
        defer { server.stop() }

        let events = try await Self.drain(provider)

        #expect(events.contains(.token("hello")))
    }

    private static func drain(_ provider: MeteredProvider) async throws -> [LLMEvent] {
        var events: [LLMEvent] = []
        for try await event in provider.stream(.hello) { events.append(event) }
        return events
    }
}
