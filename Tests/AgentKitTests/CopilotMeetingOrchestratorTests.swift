import AgentKit
import CaptureKit
import Foundation
import ProviderKit
import Testing

private actor OrchestratorGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private var released = false

    func wait() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor FirstOrchestratorReplacementGate {
    private var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var firstStarted = false

    func wait() async {
        callCount += 1
        guard callCount == 1 else { return }
        firstStarted = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor OrchestratorRecoveryScheduler {
    private(set) var delays: [TimeInterval] = []
    private var continuations: [CheckedContinuation<Void, Never>?] = []

    func wait(_ delay: TimeInterval) async {
        delays.append(delay)
        await withCheckedContinuation { continuations.append($0) }
    }

    func release(_ index: Int) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else {
            return
        }
        continuations[index] = nil
        continuation.resume()
    }
}

private actor OrchestratorEvents {
    private(set) var values: [CopilotMeetingEvent] = []
    func append(_ value: CopilotMeetingEvent) { values.append(value) }

    func completedCard(where predicate: (CopilotMeetingCard) -> Bool) -> CopilotMeetingCard? {
        for value in values.reversed() {
            guard case .card(let card?) = value, !card.isStreaming, predicate(card) else { continue }
            return card
        }
        return nil
    }

    var lastAvailability: CopilotMeetingAvailability? {
        for value in values.reversed() {
            if case .availability(let availability) = value { return availability }
        }
        return nil
    }
}

private final class OrchestratorProvider: LLMProvider, @unchecked Sendable {
    enum Structured {
        case value(String)
        case failure(ProviderError)
        case blocked(String, OrchestratorGate)
    }

    enum Streamed {
        case completed(String)
        case failure(partial: String, ProviderError)
        case blocked(String, OrchestratorGate)
    }

    private let lock = NSLock()
    private var structured: [Structured]
    private var streamed: [Streamed]
    private var _requests: [CompletionRequest] = []

    init(structured: [Structured] = [], streamed: [Streamed] = []) {
        self.structured = structured
        self.streamed = streamed
    }

    var requests: [CompletionRequest] { lock.withLock { _requests } }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let outcome = lock.withLock { () -> Streamed in
            _requests.append(request)
            return streamed.isEmpty ? .completed("default") : streamed.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch outcome {
                case .completed(let text):
                    continuation.yield(.token(text))
                    continuation.yield(.completed(.init(finishReason: "stop", usage: nil)))
                    continuation.finish()
                case .failure(let partial, let error):
                    continuation.yield(.token(partial))
                    continuation.finish(throwing: error)
                case .blocked(let text, let gate):
                    await gate.wait()
                    // Deliberately ignore cancellation at the fake-provider
                    // boundary; lease ownership must reject this stale output.
                    continuation.yield(.token(text))
                    continuation.yield(.completed(.init(finishReason: "stop", usage: nil)))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                // Do not cancel the fake task: stale-event fencing is the test.
                _ = task
            }
        }
    }

    func completeReportingUsage<T: Decodable>(
        _ request: CompletionRequest,
        as type: T.Type
    ) async throws -> CompletedCall<T> {
        let outcome = lock.withLock { () -> Structured in
            _requests.append(request)
            return structured.isEmpty ? .value(Self.noneDecision) : structured.removeFirst()
        }
        let json: String
        switch outcome {
        case .value(let value): json = value
        case .failure(let error): throw error
        case .blocked(let value, let gate):
            await gate.wait()
            json = value
        }
        return CompletedCall(
            value: try JSONDecoder().decode(type, from: Data(json.utf8)),
            usage: nil
        )
    }

    static let actionDecision =
        #"{"action":"suggest_answer","confidence":0.98,"target":"migration risk"}"#
    static let noneDecision = #"{"action":"none","confidence":0.1,"target":null}"#
}

struct CopilotMeetingOrchestratorTests {
    private func make(
        provider: any LLMProvider,
        proactive: Bool = true,
        recorder: SuggestionLatencyRecorder = SuggestionLatencyRecorder(),
        scheduler: OrchestratorRecoveryScheduler? = nil,
        providerReplacementCheckpoint: (@Sendable (UUID) async -> Void)? = nil,
        explicitCheckpoint: (@Sendable () async -> Void)? = nil,
        diagnosticsNow: @escaping @Sendable () -> Date = Date.init
    ) -> CopilotMeetingOrchestrator {
        try! CopilotMeetingOrchestrator(
            meetingID: UUID(),
            configuration: CopilotConfiguration(
                proactiveEnabled: proactive,
                confidenceThreshold: 0.9,
                preferredName: "Hoang"
            ),
            provider: provider,
            models: CopilotMeetingModels(fast: "fast", deep: "deep"),
            suggestionLatencyRecorder: recorder,
            waitForRecovery: { delay in
                if let scheduler { await scheduler.wait(delay) }
            },
            providerReplacementCheckpoint: providerReplacementCheckpoint,
            explicitAdmissionCheckpoint: explicitCheckpoint,
            diagnosticsNow: diagnosticsNow
        )
    }

    private func turn(
        source: AudioSource = .system,
        text: String = "Hoang, can you explain the migration risk?",
        start: TimeInterval = 60,
        end: TimeInterval = 62
    ) -> CopilotTurn {
        CopilotTurn(source: source, text: text, tStart: start, tEnd: end)
    }

    private func collect(
        _ orchestrator: CopilotMeetingOrchestrator,
        into events: OrchestratorEvents
    ) async -> Task<Void, Never> {
        let stream = await orchestrator.eventsStream()
        return Task {
            for await event in stream { await events.append(event) }
        }
    }

    @discardableResult
    private func waitUntil(
        _ label: String,
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(label)")
        return false
    }

    @Test func proactivePipelineOwnsContextAndG2StartsAtTurnReceipt() async throws {
        let provider = OrchestratorProvider(
            structured: [.value(OrchestratorProvider.actionDecision)],
            streamed: [.completed("Mention the rollback plan.")]
        )
        let recorder = SuggestionLatencyRecorder()
        let orchestrator = make(
            provider: provider,
            recorder: recorder,
            diagnosticsNow: { Date(timeIntervalSince1970: 12) }
        )
        let events = OrchestratorEvents()
        let collector = await collect(orchestrator, into: events)

        await orchestrator.receive(
            turn(),
            userSpeaking: false,
            now: Date(timeIntervalSince1970: 100),
            receivedAt: Date(timeIntervalSince1970: 10)
        )
        await waitUntil("proactive completion") {
            await events.completedCard {
                $0.kind == .action(.suggestAnswer)
                    && $0.text == "Mention the rollback plan."
            } != nil
        }

        let completed = try #require(await events.completedCard {
            $0.kind == .action(.suggestAnswer)
        })
        #expect(recorder.report().pendingCount == 1)
        recorder.recordFirstVisible(completed.id, at: Date(timeIntervalSince1970: 12))
        #expect(recorder.report().count == 1)
        #expect(recorder.report().p95Ms == 2_000)
        #expect(await orchestrator.contextSnapshot().allTurns.count == 1)
        #expect(provider.requests.map(\.model) == ["fast", "deep"])
        collector.cancel()
        await orchestrator.stop()
    }

    @Test func explicitQueryPreemptsProactiveAndRejectsStaleProviderEvents() async {
        let gate = OrchestratorGate()
        let provider = OrchestratorProvider(
            structured: [.value(OrchestratorProvider.actionDecision)],
            streamed: [
                .blocked("stale proactive", gate),
                .completed("current query answer"),
            ]
        )
        let orchestrator = make(provider: provider)
        let events = OrchestratorEvents()
        let collector = await collect(orchestrator, into: events)
        await orchestrator.receive(turn(), userSpeaking: false)
        await waitUntil("proactive stream start") { await gate.started }

        let query = await orchestrator.requestQuery("What was decided?")
        #expect(query?.requested == true)
        await waitUntil("query completion") {
            await events.completedCard {
                $0.kind == .query("What was decided?")
                    && $0.text == "current query answer"
            } != nil
        }
        await gate.release()
        try? await Task.sleep(for: .milliseconds(20))

        let ownership = await orchestrator.arbiterOwnership()
        #expect(ownership.active == nil)
        #expect(ownership.retained?.priority == .userRequest)
        #expect(await events.completedCard { $0.text == "stale proactive" } == nil)
        collector.cancel()
        await orchestrator.stop()
    }

    @Test func providerReplacementCancelsCommandBeforeAdmissionAndRetainsContext() async {
        let checkpoint = OrchestratorGate()
        let oldProvider = OrchestratorProvider(streamed: [.completed("old")])
        let newProvider = OrchestratorProvider(streamed: [.completed("new")])
        let orchestrator = make(
            provider: oldProvider,
            proactive: false,
            explicitCheckpoint: { await checkpoint.wait() }
        )
        await orchestrator.receive(
            turn(source: .mic, text: "meeting context", start: 0, end: 61),
            userSpeaking: false
        )
        let pending = Task { await orchestrator.requestCatchUp() }
        await waitUntil("explicit checkpoint") { await checkpoint.started }

        await orchestrator.replaceProvider(
            newProvider,
            models: CopilotMeetingModels(fast: "new-fast", deep: "new-deep"),
            replacementID: UUID()
        )
        await checkpoint.release()
        #expect(await pending.value == false)
        #expect(oldProvider.requests.isEmpty)

        #expect(await orchestrator.requestCatchUp())
        await waitUntil("new provider request") { newProvider.requests.count == 1 }
        #expect(newProvider.requests.first?.model == "new-deep")
        #expect(await orchestrator.contextSnapshot().allTurns.count == 1)
        await orchestrator.stop()
    }

    @Test func providerReplacementReturnsOnlyTheWinningAuthoritativeState() async {
        let gate = FirstOrchestratorReplacementGate()
        let orchestrator = make(
            provider: OrchestratorProvider(),
            proactive: false,
            providerReplacementCheckpoint: { _ in await gate.wait() }
        )
        let staleProvider = OrchestratorProvider(streamed: [.completed("stale")])
        let stale = Task {
            await orchestrator.replaceProvider(
                staleProvider,
                models: CopilotMeetingModels(fast: "stale-fast", deep: "stale-deep"),
                replacementID: UUID()
            )
        }
        await waitUntil("first provider replacement") { await gate.firstStarted }

        let winner = await orchestrator.replaceProvider(
            nil,
            models: CopilotMeetingModels(fast: "winning-fast", deep: "winning-deep"),
            replacementID: UUID()
        )
        await gate.release()

        #expect(winner == .committed(CopilotMeetingProviderState(
            providerAvailable: false,
            models: CopilotMeetingModels(fast: "winning-fast", deep: "winning-deep"),
            availability: .setupRequired
        )))
        #expect(await stale.value == .superseded)
        await orchestrator.stop()
    }

    @Test func transientRecoveryOrdersRollbackAndExplicitRetryBypassesPause() async {
        let scheduler = OrchestratorRecoveryScheduler()
        let provider = OrchestratorProvider(
            structured: [.failure(.transport("offline"))],
            streamed: [.completed("meeting-grounded retry")]
        )
        let orchestrator = make(provider: provider, scheduler: scheduler)
        let events = OrchestratorEvents()
        let collector = await collect(orchestrator, into: events)
        await orchestrator.receive(turn(), userSpeaking: false)
        await waitUntil("recovery delay") { await scheduler.delays == [30] }
        #expect(await events.lastAvailability != .ready)
        #expect(await orchestrator.transientRecoveryFailureCount == 1)

        let query = await orchestrator.requestQuery("What did we decide?")
        #expect(query != nil, "explicit request must bypass transient backoff")
        await waitUntil("explicit retry completion") {
            await events.completedCard { $0.text == "meeting-grounded retry" } != nil
        }
        #expect(await orchestrator.transientRecoveryFailureCount == 0)
        await scheduler.release(0)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await events.completedCard { $0.text == "meeting-grounded retry" } != nil)
        collector.cancel()
        await orchestrator.stop()
    }
}
