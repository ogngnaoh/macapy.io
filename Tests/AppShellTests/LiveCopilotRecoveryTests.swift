import AgentKit
import CaptureKit
import Foundation
import PersistKit
import ProviderKit
import Testing
import TranscribeKit

@testable import AppShell

private actor ManualRecoveryScheduler {
    private(set) var delays: [TimeInterval] = []
    private var waiters: [CheckedContinuation<Void, Never>?] = []

    func wait(_ delay: TimeInterval) async {
        delays.append(delay)
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release(_ index: Int) {
        guard waiters.indices.contains(index), let waiter = waiters[index] else { return }
        waiters[index] = nil
        waiter.resume()
    }
}

private actor TerminalStreamGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class RecoveryQueueProvider: LLMProvider, @unchecked Sendable {
    enum StructuredOutcome {
        case decision(String)
        case failure(ProviderError)
    }

    enum StreamOutcome {
        case completed(String)
        case completedThenWait(String, TerminalStreamGate)
        case failure(partial: String, ProviderError)
        case terminal(partial: String, reason: String?)
    }

    private let lock = NSLock()
    private var structured: [StructuredOutcome]
    private var streams: [StreamOutcome]
    private var _structuredCalls = 0
    private var _streamCalls = 0

    init(structured: [StructuredOutcome], streams: [StreamOutcome] = []) {
        self.structured = structured
        self.streams = streams
    }

    var calls: (structured: Int, stream: Int) {
        lock.withLock { (_structuredCalls, _streamCalls) }
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let outcome = lock.withLock { () -> StreamOutcome in
            _streamCalls += 1
            if streams.isEmpty { return .completed("Recovered answer.") }
            return streams.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch outcome {
            case .completed(let text):
                continuation.yield(.token(text))
                continuation.yield(.completed(.init(finishReason: "stop", usage: nil)))
                continuation.finish()
            case .completedThenWait(let text, let gate):
                let task = Task {
                    continuation.yield(.token(text))
                    continuation.yield(.completed(.init(finishReason: "stop", usage: nil)))
                    await gate.wait()
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            case .failure(let partial, let error):
                continuation.yield(.token(partial))
                continuation.finish(throwing: error)
            case .terminal(let partial, let reason):
                continuation.yield(.token(partial))
                continuation.yield(.completed(.init(finishReason: reason, usage: nil)))
                continuation.finish()
            }
        }
    }

    func completeReportingUsage<T: Decodable>(
        _ request: CompletionRequest,
        as type: T.Type
    ) async throws -> CompletedCall<T> {
        let outcome = lock.withLock { () -> StructuredOutcome in
            _structuredCalls += 1
            if structured.isEmpty { return .decision(Self.noneDecision) }
            return structured.removeFirst()
        }
        switch outcome {
        case .decision(let json):
            return CompletedCall(
                value: try JSONDecoder().decode(type, from: Data(json.utf8)),
                usage: nil
            )
        case .failure(let error):
            throw error
        }
    }

    static let actionDecision =
        #"{"action":"suggest_answer","confidence":0.97,"target":"migration risk"}"#
    static let noneDecision = #"{"action":"none","confidence":0.10,"target":null}"#
}

@MainActor
struct LiveCopilotRecoveryTests {
    private func model(
        provider: any LLMProvider,
        scheduler: ManualRecoveryScheduler,
        meetingID: UUID = UUID()
    ) -> LiveCopilotModel {
        let model = LiveCopilotModel(waitForRecovery: { delay in
            await scheduler.wait(delay)
        })
        model.beginMeeting(
            meetingID: meetingID,
            provider: provider,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings(sensitivity: .active)
        )
        return model
    }

    private func turn(_ index: Int) -> TranscriptTurn {
        let start = 60.0 + Double(index * 2)
        return TranscriptTurn(
            source: .system,
            text: "Hoang, can you explain migration risk number \(index)?",
            segmentIDs: [UUID()],
            tStart: start,
            tEnd: start + 1
        )
    }

    @discardableResult
    private func waitUntil(
        _ label: String,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(label)")
        return false
    }

    @Test func repeatedDeepFailuresAdvanceThirtySixtyOneTwentyWithoutReplay() async {
        let scheduler = ManualRecoveryScheduler()
        let provider = RecoveryQueueProvider(
            structured: Array(repeating: .decision(RecoveryQueueProvider.actionDecision), count: 3),
            streams: [
                .failure(partial: "unsafe one", .transport("disconnect")),
                .failure(partial: "unsafe two", .server(status: 503, message: nil)),
                .failure(partial: "unsafe three", .rateLimited(message: nil)),
            ]
        )
        let model = model(provider: provider, scheduler: scheduler)
        let expected: [TimeInterval] = [30, 60, 120]

        for index in 0..<3 {
            await model.receive(
                turn(index),
                userSpeaking: false,
                now: Date(timeIntervalSince1970: Double(100 + index * 100))
            )
            await waitUntil("transient pause \(index)") {
                await scheduler.delays.count == index + 1
                    && model.transientRecoveryFailureCountForTesting == index + 1
            }
            #expect(await scheduler.delays == Array(expected.prefix(index + 1)))
            #expect(model.card == nil, "partial output must be cleared")

            let callsBeforeWake = provider.calls
            await scheduler.release(index)
            await waitUntil("recovery wake \(index)") { model.availability == .ready }
            #expect(provider.calls == callsBeforeWake, "a wake must not replay a stale moment")
        }
        model.stopMeeting()
    }

    @Test func terminalNoActionSuccessResetsTheNextFailureToThirtySeconds() async {
        let scheduler = ManualRecoveryScheduler()
        let provider = RecoveryQueueProvider(
            structured: [
                .decision(RecoveryQueueProvider.actionDecision),
                .decision(RecoveryQueueProvider.noneDecision),
                .decision(RecoveryQueueProvider.actionDecision),
            ],
            streams: [
                .failure(partial: "first", .transport("offline")),
                .failure(partial: "second", .server(status: 500, message: nil)),
            ]
        )
        let model = model(provider: provider, scheduler: scheduler)

        await model.receive(turn(0), userSpeaking: false, now: .init(timeIntervalSince1970: 100))
        await waitUntil("first delay") { await scheduler.delays.count == 1 }
        await scheduler.release(0)
        await waitUntil("first recovery") { model.availability == .ready }

        await model.receive(turn(1), userSpeaking: false, now: .init(timeIntervalSince1970: 200))
        await waitUntil("successful no-action classifier") {
            provider.calls.structured == 2
                && model.transientRecoveryFailureCountForTesting == 0
        }

        await model.receive(turn(2), userSpeaking: false, now: .init(timeIntervalSince1970: 300))
        await waitUntil("fresh first delay") { await scheduler.delays.count == 2 }
        #expect(await scheduler.delays == [30, 30])
        await scheduler.release(1)
        model.stopMeeting()
    }

    @Test func explicitQueryBypassesDelayAndFailureAdvancesTheExistingSequence() async {
        let scheduler = ManualRecoveryScheduler()
        let provider = RecoveryQueueProvider(
            structured: [.failure(.malformedResponse("bad classifier JSON"))],
            streams: [.failure(partial: "unsafe query", .rateLimited(message: nil))]
        )
        let model = model(provider: provider, scheduler: scheduler)

        await model.receive(turn(0), userSpeaking: false)
        await waitUntil("automatic delay") { await scheduler.delays == [30] }
        #expect(model.canAsk)

        await model.setAutomaticSuppressed(true)
        model.requestAsk()
        model.queryText = "What decision did we make?"
        #expect(await model.submitAsk(), "capture pause must still permit an explicit query")
        await waitUntil("explicit retry delay") { await scheduler.delays == [30, 60] }
        #expect(model.card == nil, "failed explicit partial output must be removed")
        #expect(model.transientRecoveryFailureCountForTesting == 2)

        await scheduler.release(0)
        try? await Task.sleep(for: .milliseconds(20))
        guard case .paused = model.availability else {
            Issue.record("a cancelled stale wake reopened the current delay")
            return
        }
        await scheduler.release(1)
        await waitUntil("current recovery") { model.availability == .ready }
        #expect(provider.calls == (structured: 1, stream: 1))
        model.stopMeeting()
    }

    @Test func explicitSuccessClearsDelayAndStaleWakeCannotChangeTheCard() async {
        let scheduler = ManualRecoveryScheduler()
        let provider = RecoveryQueueProvider(
            structured: [.failure(.server(status: 503, message: nil))],
            streams: [.completed("Meeting-grounded answer.")]
        )
        let model = model(provider: provider, scheduler: scheduler)

        await model.receive(turn(0), userSpeaking: false)
        await waitUntil("automatic delay") { await scheduler.delays == [30] }
        model.requestAsk()
        model.queryText = "What did they decide?"
        #expect(await model.submitAsk())
        await waitUntil("requested answer and terminal success fence") {
            model.card?.text == "Meeting-grounded answer."
                && model.card?.isStreaming == false
                && model.transientRecoveryFailureCountForTesting == 0
        }
        #expect(model.transientRecoveryFailureCountForTesting == 0)

        await scheduler.release(0)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.card?.text == "Meeting-grounded answer.")
        #expect(model.availability == .ready)
        model.stopMeeting()
    }

    @Test func completedProviderOperationResetsRecoveryBeforeCardCanBeReplaced() async {
        let scheduler = ManualRecoveryScheduler()
        let terminalGate = TerminalStreamGate()
        let provider = RecoveryQueueProvider(
            structured: [.failure(.server(status: 503, message: nil))],
            streams: [
                .completedThenWait("Meeting-grounded answer.", terminalGate),
                .failure(partial: "unsafe retry", .transport("offline")),
            ]
        )
        let model = model(provider: provider, scheduler: scheduler)

        await model.receive(turn(0), userSpeaking: false)
        await waitUntil("automatic delay") { await scheduler.delays == [30] }

        model.requestAsk()
        model.queryText = "What did they decide?"
        #expect(await model.submitAsk())
        await waitUntil("completed first answer") {
            model.card?.text == "Meeting-grounded answer."
                && model.card?.isStreaming == false
        }

        model.requestAsk()
        model.queryText = "What happens next?"
        #expect(await model.submitAsk())
        await waitUntil("fresh recovery sequence") { await scheduler.delays.count == 2 }
        #expect(await scheduler.delays == [30, 30])
        #expect(model.transientRecoveryFailureCountForTesting == 1)

        await terminalGate.release()
        await scheduler.release(1)
        model.stopMeeting()
    }

    @Test func aiOffAndNextMeetingRejectAStaleScheduledWake() async {
        let scheduler = ManualRecoveryScheduler()
        let oldProvider = RecoveryQueueProvider(
            structured: [.failure(.transport("offline"))]
        )
        let model = model(provider: oldProvider, scheduler: scheduler)
        await model.receive(turn(0), userSpeaking: false)
        await waitUntil("old recovery") { await scheduler.delays == [30] }

        await model.applyLiveSettings(LiveAISettings(aiFeaturesEnabled: false))
        #expect(model.availability == .disabled)
        let newProvider = RecoveryQueueProvider(
            structured: [.decision(RecoveryQueueProvider.noneDecision)]
        )
        model.beginMeeting(
            provider: newProvider,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings(sensitivity: .active)
        )
        await scheduler.release(0)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.availability == .ready)
        #expect(newProvider.calls == (structured: 0, stream: 0))

        await model.receive(turn(1), userSpeaking: false)
        await waitUntil("new meeting request") { newProvider.calls.structured == 1 }
        #expect(model.availability == .ready)
        model.stopMeeting()
    }

    @Test func authenticationAndCapRemainHardLatchedWhileMalformedIsRetryable() async {
        for status in [401, 403] {
            let scheduler = ManualRecoveryScheduler()
            let provider = RecoveryQueueProvider(
                structured: [.failure(.http(status: status, message: nil))]
            )
            let model = model(provider: provider, scheduler: scheduler)
            await model.receive(turn(status), userSpeaking: false)
            await waitUntil("auth \(status)") { model.availability == .setupRequired }
            #expect(!model.canAsk)
            #expect(await scheduler.delays.isEmpty)
            model.releaseAuthenticationPauseAfterConfigurationChange()
            #expect(model.canAsk)
            model.stopMeeting()
        }

        let capScheduler = ManualRecoveryScheduler()
        let capProvider = RecoveryQueueProvider(
            structured: [.failure(.capReached(spentUSD: 0.25, capUSD: 0.25))]
        )
        let capModel = model(provider: capProvider, scheduler: capScheduler)
        await capModel.receive(turn(3), userSpeaking: false)
        await waitUntil("cap latch") {
            if case .paused(let message) = capModel.availability { return message.contains("cap") }
            return false
        }
        await capModel.applyLiveSettings(LiveAISettings(sensitivity: .active))
        #expect(!capModel.canAsk)
        #expect(await capScheduler.delays.isEmpty)
        capModel.releaseCapPauseAfterCapIncrease()
        #expect(capModel.canAsk)
        capModel.stopMeeting()
    }
}
