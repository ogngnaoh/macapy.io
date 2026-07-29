import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// FR-015's "every completed call books exactly one ledger row" must hold
/// against consumers that stop reading at the terminal event and against task
/// cancellation. GRDB 7's async accesses throw `CancellationError` when their
/// surrounding task is cancelled, and `MeteredProvider`'s booking used to ride
/// the very task the stream's `onTermination` cancels — so a fully billed call
/// could book nothing, silently (slice-2 critic pass, confirmed interleaving).
struct MeteredBookingTests {

    private static let meeting = UUID()

    private static var streamedReply: FakeOpenAIServer.Response {
        .sse(frames: [
            OpenAIFixtures.contentDelta("hello"),
            OpenAIFixtures.finish(reason: "stop", promptTokens: 1_000, completionTokens: 500),
            OpenAIFixtures.done,
        ])
    }

    /// Mirrors GRDB 7's cancellation contract — an async database access throws
    /// `CancellationError` when its task is already cancelled — and gates the
    /// write open so the test can *guarantee* cancellation lands first, rather
    /// than racing it (a test that needs scheduling slack is hiding a race —
    /// M1 slice-4 lesson).
    private actor GatedCancellationHonoringLedger: SpendLedger {
        private(set) var entries: [SpendEntry] = []
        private var recordEntered: CheckedContinuation<Void, Never>?
        private var recordEnteredAlready = false
        private var releaseRecord: CheckedContinuation<Void, Never>?
        private var releasedAlready = false
        private var recordExited: CheckedContinuation<Void, Never>?
        private var recordExitedAlready = false

        func record(_ entry: SpendEntry) async throws {
            recordEnteredAlready = true
            recordEntered?.resume()
            recordEntered = nil
            if !releasedAlready {
                await withCheckedContinuation { releaseRecord = $0 }
            }
            defer {
                recordExitedAlready = true
                recordExited?.resume()
                recordExited = nil
            }
            try Task.checkCancellation()
            entries.append(entry)
        }

        func totalCostUSD(meetingID: UUID) async throws -> Double {
            entries.filter { $0.meetingID == meetingID }.compactMap(\.estCostUSD).reduce(0, +)
        }

        func waitUntilRecordEntered() async {
            if recordEnteredAlready { return }
            await withCheckedContinuation { recordEntered = $0 }
        }

        func release() {
            releasedAlready = true
            releaseRecord?.resume()
            releaseRecord = nil
        }

        func waitUntilRecordExited() async {
            if recordExitedAlready { return }
            await withCheckedContinuation { recordExited = $0 }
        }
    }

    @Test func bookingSurvivesTheConsumerBeingCancelledAtTheTerminalEvent() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.streamedReply])
        defer { server.stop() }
        let ledger = GatedCancellationHonoringLedger()
        let meter = SpendMeter(ledger: ledger, pricing: PricingTable(rates: [:]), capUSD: nil)
        let provider = MeteredProvider(
            upstream: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            meter: meter,
            meetingID: Self.meeting
        )

        let consumer = Task {
            for try await _ in provider.stream(.hello) {}
        }
        await ledger.waitUntilRecordEntered()
        consumer.cancel()
        _ = await consumer.result // iterator torn down → onTermination has cancelled the producer
        await ledger.release()
        await ledger.waitUntilRecordExited()

        let entries = await ledger.entries
        #expect(entries.count == 1,
                "the provider billed this call; consumer cancellation must not unbook it")
    }

    @Test func theTerminalEventArrivesOnlyAfterTheBookingIsWritten() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.streamedReply])
        defer { server.stop() }
        let ledger = InMemorySpendLedger()
        let meter = SpendMeter(ledger: ledger, pricing: PricingTable(rates: [:]), capUSD: nil)
        let provider = MeteredProvider(
            upstream: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            meter: meter,
            meetingID: Self.meeting
        )

        var rowsAtTerminalEvent: Int?
        for try await event in provider.stream(.hello) {
            if case .completed = event { rowsAtTerminalEvent = await ledger.entries.count }
        }

        #expect(rowsAtTerminalEvent == 1,
                "a consumer is contractually free to stop at .completed — the row must already exist")
    }

    // MARK: - Structured calls

    /// Checks cancellation exactly where GRDB would: at the write.
    private actor CancellationCheckingLedger: SpendLedger {
        private(set) var entries: [SpendEntry] = []

        func record(_ entry: SpendEntry) async throws {
            try Task.checkCancellation()
            entries.append(entry)
        }

        func totalCostUSD(meetingID: UUID) async throws -> Double {
            entries.filter { $0.meetingID == meetingID }.compactMap(\.estCostUSD).reduce(0, +)
        }
    }

    private actor UpstreamGate {
        private var entered: CheckedContinuation<Void, Never>?
        private var enteredAlready = false
        private var release: CheckedContinuation<Void, Never>?
        private var releasedAlready = false

        func didEnter() {
            enteredAlready = true
            entered?.resume()
            entered = nil
        }

        func waitUntilEntered() async {
            if enteredAlready { return }
            await withCheckedContinuation { entered = $0 }
        }

        func releaseUpstream() {
            releasedAlready = true
            release?.resume()
            release = nil
        }

        func waitForRelease() async {
            if releasedAlready { return }
            await withCheckedContinuation { release = $0 }
        }
    }

    /// An upstream that bills (returns usage) only after the test lets it — so
    /// the test can cancel the caller *while the provider call is in flight*.
    private struct GatedUpstream: LLMProvider {
        let gate: UpstreamGate

        func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func completeReportingUsage<T: Decodable>(
            _ request: CompletionRequest,
            as type: T.Type
        ) async throws -> CompletedCall<T> {
            await gate.didEnter()
            await gate.waitForRelease()
            let value = try JSONDecoder().decode(T.self, from: Data(#""ok""#.utf8))
            return CompletedCall(value: value, usage: TokenUsage(promptTokens: 10, completionTokens: 2))
        }
    }

    @Test func structuredCallBookingSurvivesCallerCancellationAfterTheProviderBilled() async throws {
        let ledger = CancellationCheckingLedger()
        let meter = SpendMeter(ledger: ledger, pricing: PricingTable(rates: [:]), capUSD: nil)
        let gate = UpstreamGate()
        let provider = MeteredProvider(upstream: GatedUpstream(gate: gate), meter: meter, meetingID: nil)

        let caller = Task {
            _ = try await provider.complete(.hello, as: String.self)
        }
        await gate.waitUntilEntered()
        caller.cancel() // the provider call is in flight: it will bill regardless
        await gate.releaseUpstream()
        _ = await caller.result

        let entries = await ledger.entries
        #expect(entries.count == 1,
                "the provider billed this call; caller cancellation must not unbook it")
    }
}
