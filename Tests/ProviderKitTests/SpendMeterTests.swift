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

    private struct StructuredReply: Decodable {
        let answer: String
    }

    enum StructuredFailureFixture: CaseIterable, Sendable {
        case length
        case contentFilter
        case missingFinishReason
        case schemaDecode

        var response: FakeOpenAIServer.Response {
            switch self {
            case .length:
                .json(status: 200, body: OpenAIFixtures.completionBody(
                    content: #"{"answer":"partial"}"#,
                    promptTokens: 2_000,
                    completionTokens: 500,
                    finishReason: "length"
                ))
            case .contentFilter:
                .json(status: 200, body: OpenAIFixtures.completionBody(
                    content: #"{"answer":"filtered"}"#,
                    promptTokens: 2_000,
                    completionTokens: 500,
                    finishReason: "content_filter"
                ))
            case .missingFinishReason:
                .json(
                    status: 200,
                    body: #"{"choices":[{"message":{"content":"{\"answer\":\"unterminated\"}"}}],"usage":{"prompt_tokens":2000,"completion_tokens":500,"total_tokens":2500}}"#
                )
            case .schemaDecode:
                .json(status: 200, body: OpenAIFixtures.completionBody(
                    content: #"{"wrong_field":"not an answer"}"#,
                    promptTokens: 2_000,
                    completionTokens: 500
                ))
            }
        }
    }

    private struct StructuredTransportFailure: LLMProvider {
        func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func completeReportingUsage<T: Decodable>(
            _ request: CompletionRequest,
            as type: T.Type
        ) async throws -> CompletedCall<T> {
            throw ProviderError.transport("connection lost after request upload")
        }
    }

    private actor FailingRecordLedger: SpendLedger {
        struct WriteFailure: Error {}

        func record(_ entry: SpendEntry) async throws {
            throw WriteFailure()
        }

        func totalCostUSD(meetingID: UUID) async throws -> Double { 0 }
    }

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

    @Test(arguments: StructuredFailureFixture.allCases)
    func aStructuredFailureRetainsItsCeilingAndCannotBypassTheCap(
        failure: StructuredFailureFixture
    ) async throws {
        let request = Self.expensiveRequest
        let ledger = InMemorySpendLedger()
        let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: nil)
        let held = try #require(await meter.requestCostCeilingUSD(request))
        await meter.updateCapUSD(held * 1.5)
        let server = try FakeOpenAIServer.start(responses: [failure.response])
        defer { server.stop() }
        let provider = MeteredProvider(
            upstream: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            meter: meter,
            meetingID: Self.meeting
        )

        var thrown: Error?
        do {
            _ = try await provider.complete(request, as: StructuredReply.self)
        } catch {
            thrown = error
        }

        switch failure {
        case .length:
            #expect(thrown as? ProviderError == .truncated(finishReason: "length"))
        case .contentFilter:
            #expect(thrown as? ProviderError == .truncated(finishReason: "content_filter"))
        case .missingFinishReason:
            #expect(thrown as? ProviderError == .truncated(finishReason: "unknown"))
        case .schemaDecode:
            guard case .decodingFailed = thrown as? ProviderError else {
                Issue.record("expected ProviderError.decodingFailed, got \(String(describing: thrown))")
                return
            }
        }

        #expect(await ledger.entries.isEmpty,
                "unknown failed-call usage must not create a fabricated ledger row")
        #expect(await meter.reservedUSD(meetingID: Self.meeting) == 0)
        #expect(await meter.uncertainUSD(meetingID: Self.meeting) >= held)

        await #expect(throws: ProviderError.self) {
            _ = try await provider.complete(request, as: StructuredReply.self)
        }
        #expect(server.recordedRequests.count == 1,
                "the retained debit must reject the next call before the network")
    }

    @Test func aStructuredTransportFailureRetainsItsCeilingAndBlocksTheNextCall() async throws {
        let request = Self.expensiveRequest
        let ledger = InMemorySpendLedger()
        let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: nil)
        let held = try #require(await meter.requestCostCeilingUSD(request))
        await meter.updateCapUSD(held * 1.5)
        let provider = MeteredProvider(
            upstream: StructuredTransportFailure(),
            meter: meter,
            meetingID: Self.meeting
        )

        await #expect(throws: ProviderError.transport("connection lost after request upload")) {
            _ = try await provider.complete(request, as: StructuredReply.self)
        }
        #expect(await ledger.entries.isEmpty)
        #expect(await meter.reservedUSD(meetingID: Self.meeting) == 0)
        #expect(await meter.uncertainUSD(meetingID: Self.meeting) >= held)
        await #expect(throws: ProviderError.self) {
            _ = try await provider.complete(request, as: StructuredReply.self)
        }
    }

    @Test func structuredCancellationReleasesItsCeilingForTheNextCall() async throws {
        let request = Self.expensiveRequest
        let ledger = InMemorySpendLedger()
        let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: nil)
        let held = try #require(await meter.requestCostCeilingUSD(request))
        await meter.updateCapUSD(held * 1.5)
        let slowFrames = Array(repeating: #"{"still":"streaming"}"#, count: 1_000)
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: slowFrames),
        ])
        defer { server.stop() }
        let provider = MeteredProvider(
            upstream: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            meter: meter,
            meetingID: Self.meeting
        )

        let call = Task {
            try await provider.complete(request, as: StructuredReply.self)
        }
        while server.recordedRequests.isEmpty {
            await Task.yield()
        }
        call.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await call.value
        }
        #expect(await meter.reservedUSD(meetingID: Self.meeting) == 0)
        #expect(await meter.uncertainUSD(meetingID: Self.meeting) == 0)
        #expect(await ledger.entries.isEmpty)

        let next = try await meter.reserve(request, meetingID: Self.meeting)
        await meter.cancel(next)
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

    // MARK: - In-flight reservations

    @Test func concurrentReservationsCannotAmplifyACapOverrun() async throws {
        let ledger = InMemorySpendLedger()
        let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: 0.20)
        let request = Self.expensiveRequest

        let reservations = await withTaskGroup(of: SpendReservation?.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try? await meter.reserve(request, meetingID: Self.meeting)
                }
            }
            var values: [SpendReservation] = []
            for await reservation in group {
                if let reservation { values.append(reservation) }
            }
            return values
        }

        #expect(reservations.count == 1,
                "only one concurrent maximum-cost call may claim the remaining cap")
        #expect(await meter.reservedUSD(meetingID: Self.meeting) > 0.15)
        for reservation in reservations { await meter.cancel(reservation) }
        #expect(await meter.reservedUSD(meetingID: Self.meeting) == 0)
    }

    @Test func anUnpricedCappedCallClaimsAllRemainingCapacity() async throws {
        let meter = SpendMeter(
            ledger: InMemorySpendLedger(),
            pricing: PricingTable(rates: [:]),
            capUSD: 0.20
        )

        let reservations = await withTaskGroup(of: SpendReservation?.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try? await meter.reserve(.hello, meetingID: Self.meeting)
                }
            }
            var values: [SpendReservation] = []
            for await reservation in group {
                if let reservation { values.append(reservation) }
            }
            return values
        }

        #expect(reservations.count == 1)
        #expect(reservations.first?.estimatedCostUSD == nil)
        #expect(await meter.reservedUSD(meetingID: Self.meeting) == 0.20)
        for reservation in reservations { await meter.cancel(reservation) }
    }

    @Test func settlementBooksActualUsageAndReleasesTheReservation() async throws {
        let ledger = InMemorySpendLedger()
        let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: 0.20)
        var request = Self.expensiveRequest
        request.purpose = .classifier
        let reservation = try await meter.reserve(request, meetingID: Self.meeting)

        let usage = TokenUsage(promptTokens: 1_000, cachedTokens: 800, completionTokens: 500)
        let entry = try await meter.settle(reservation, usage: usage)

        #expect(entry?.usage == usage)
        #expect(entry?.purpose == .classifier)
        #expect(await meter.reservedUSD(meetingID: Self.meeting) == 0)
        #expect(await ledger.entries.count == 1)
    }

    @Test func successfulCallWithoutUsageRetainsItsReservationAsAnUncertainDebit() async throws {
        let meter = SpendMeter(
            ledger: InMemorySpendLedger(),
            pricing: Self.pricing,
            capUSD: 1.0
        )
        let reservation = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)
        let held = try #require(reservation.estimatedCostUSD)

        let entry = try await meter.settle(reservation, usage: nil)

        #expect(entry == nil)
        #expect(await meter.reservedUSD(meetingID: Self.meeting) == 0)
        #expect(await meter.uncertainUSD(meetingID: Self.meeting) >= held)
        await meter.updateCapUSD(held * 1.5)
        await #expect(throws: ProviderError.self) {
            _ = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)
        }
    }

    @Test func normalStreamWithoutUsageCannotMakeASequentialCallFailOpen() async throws {
        let ledger = InMemorySpendLedger()
        let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: 1.0)
        var request = CompletionRequest.hello
        request.maxTokens = 5_000
        let held = try #require(await meter.requestCostCeilingUSD(request))
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.contentDelta("complete answer"),
                OpenAIFixtures.finish(reason: "stop"),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }
        let provider = MeteredProvider(
            upstream: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            meter: meter,
            meetingID: Self.meeting
        )

        for try await _ in provider.stream(request) {}

        #expect(await ledger.entries.isEmpty)
        #expect(await meter.uncertainUSD(meetingID: Self.meeting) >= held)
        await meter.updateCapUSD(held * 1.5)
        await #expect(throws: ProviderError.self) {
            _ = try await meter.reserve(request, meetingID: Self.meeting)
        }
    }

    @Test func successfulUnpricedCallCannotFailOpenAndCapRaisingAddsCapacity() async throws {
        let meter = SpendMeter(
            ledger: InMemorySpendLedger(),
            pricing: PricingTable(rates: [:]),
            capUSD: 0.20
        )
        let first = try await meter.reserve(.hello, meetingID: Self.meeting)

        _ = try await meter.settle(
            first,
            usage: TokenUsage(promptTokens: 10, completionTokens: 5)
        )

        #expect(await meter.uncertainUSD(meetingID: Self.meeting) == 0.20)
        await #expect(throws: ProviderError.self) {
            _ = try await meter.reserve(.hello, meetingID: Self.meeting)
        }

        await meter.updateCapUSD(0.40)
        let second = try await meter.reserve(.hello, meetingID: Self.meeting)
        #expect(await meter.reservedUSD(meetingID: Self.meeting) == 0.20)
        await meter.cancel(second)
    }

    @Test func failedLedgerWriteRetainsAConservativeDebit() async throws {
        let meter = SpendMeter(
            ledger: FailingRecordLedger(),
            pricing: Self.pricing,
            capUSD: 0.20
        )
        let reservation = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)
        let held = try #require(reservation.estimatedCostUSD)

        await #expect(throws: FailingRecordLedger.WriteFailure.self) {
            _ = try await meter.settle(
                reservation,
                usage: TokenUsage(promptTokens: 10, completionTokens: 5)
            )
        }

        #expect(await meter.uncertainUSD(meetingID: Self.meeting) >= held)
        await #expect(throws: ProviderError.self) {
            _ = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)
        }
    }

    @Test func waitForSettlementsIsAwaitableAndCancellationSafe() async throws {
        let meter = SpendMeter(
            ledger: InMemorySpendLedger(),
            pricing: Self.pricing,
            capUSD: 0.20
        )
        let reservation = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)
        let waiter = Task {
            try await meter.waitForSettlements()
            return true
        }
        await Task.yield()

        await meter.cancel(reservation)
        #expect(try await waiter.value)

        let second = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)
        let cancelledWaiter = Task { try await meter.waitForSettlements() }
        await Task.yield()
        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledWaiter.value }
        await meter.cancel(second)
        try await meter.waitForSettlements()
    }

    @Test func transportFailureWithoutUsageReleasesTheReservation() async throws {
        let ledger = InMemorySpendLedger()
        let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: 0.20)
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 503, body: OpenAIFixtures.errorBody(message: "down"))
        ])
        defer { server.stop() }
        let provider = MeteredProvider(
            upstream: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            meter: meter,
            meetingID: Self.meeting
        )

        do {
            for try await _ in provider.stream(Self.expensiveRequest) {}
        } catch {}

        #expect(await meter.reservedUSD(meetingID: Self.meeting) == 0)
        #expect(await meter.uncertainUSD(meetingID: Self.meeting) == 0)
        let next = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)
        await meter.cancel(next)
    }

    @Test func cancellationReleasesCapacityForTheNextCall() async throws {
        let meter = SpendMeter(
            ledger: InMemorySpendLedger(),
            pricing: Self.pricing,
            capUSD: 0.20
        )
        let first = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)

        await meter.cancel(first)
        let second = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)

        #expect(second.estimatedCostUSD == first.estimatedCostUSD)
        await meter.cancel(second)
    }

    @Test func raisingTheLiveCapAllowsAPreviouslyRefusedCall() async throws {
        let meter = SpendMeter(
            ledger: InMemorySpendLedger(),
            pricing: Self.pricing,
            capUSD: 0.10
        )
        var refused = false
        do {
            _ = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)
        } catch ProviderError.capReached {
            refused = true
        }
        #expect(refused)

        await meter.updateCapUSD(0.20)
        let reservation = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)

        #expect(await meter.capUSD == 0.20)
        await meter.cancel(reservation)
    }

    @Test func nilMaxTokensUsesTheDocumentedCompatibilityCeiling() async throws {
        let meter = SpendMeter(
            ledger: InMemorySpendLedger(),
            pricing: Self.pricing,
            capUSD: nil
        )
        var request = CompletionRequest.hello
        request.maxTokens = nil

        let nilEstimate = await meter.requestCostCeilingUSD(request)
        request.maxTokens = SpendMeter.fallbackMaxTokens
        let explicitEstimate = await meter.requestCostCeilingUSD(request)

        #expect(nilEstimate == explicitEstimate)
        #expect((nilEstimate ?? 0) > 0)
    }

    @Test func streamedCallRefusedByReservationNeverReachesTheNetwork() async throws {
        let ledger = InMemorySpendLedger()
        let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: 0.20)
        let held = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)
        RecordingURLProtocol.reset()
        let provider = MeteredProvider(
            upstream: OpenAICompatibleClient(
                profile: .fake(baseURL: URL(string: "https://example.invalid/v1")!),
                apiKey: "sk-test",
                session: RecordingURLProtocol.session()
            ),
            meter: meter,
            meetingID: Self.meeting
        )

        var thrown: Error?
        do {
            for try await _ in provider.stream(Self.expensiveRequest) {}
        } catch {
            thrown = error
        }
        await meter.cancel(held)

        guard case .capReached = thrown as? ProviderError else {
            Issue.record("expected ProviderError.capReached, got \(String(describing: thrown))")
            return
        }
        #expect(RecordingURLProtocol.recordedRequests.isEmpty)
    }

    @Test func structuredCallRefusedByReservationNeverReachesTheNetwork() async throws {
        struct Reply: Decodable { let answer: String }
        let ledger = InMemorySpendLedger()
        let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: 0.20)
        let held = try await meter.reserve(Self.expensiveRequest, meetingID: Self.meeting)
        RecordingURLProtocol.reset()
        let provider = MeteredProvider(
            upstream: OpenAICompatibleClient(
                profile: .fake(baseURL: URL(string: "https://example.invalid/v1")!),
                apiKey: "sk-test",
                session: RecordingURLProtocol.session()
            ),
            meter: meter,
            meetingID: Self.meeting
        )

        var thrown: Error?
        do {
            _ = try await provider.complete(Self.expensiveRequest, as: Reply.self)
        } catch {
            thrown = error
        }
        await meter.cancel(held)

        guard case .capReached = thrown as? ProviderError else {
            Issue.record("expected ProviderError.capReached, got \(String(describing: thrown))")
            return
        }
        #expect(RecordingURLProtocol.recordedRequests.isEmpty)
    }

    private static var expensiveRequest: CompletionRequest {
        CompletionRequest(
            model: "fake-model",
            messages: [.user("reserve this request")],
            purpose: .generation,
            maxTokens: 50_000
        )
    }

    private static func drain(_ provider: MeteredProvider) async throws -> [LLMEvent] {
        var events: [LLMEvent] = []
        for try await event in provider.stream(.hello) { events.append(event) }
        return events
    }
}
