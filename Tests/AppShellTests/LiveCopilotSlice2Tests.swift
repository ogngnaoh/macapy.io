import AgentKit
import Carbon.HIToolbox
import CaptureKit
import Foundation
import PersistKit
import ProviderKit
import Testing
import TranscribeKit

@testable import AppShell

private final class Slice2QueuedProvider: LLMProvider, @unchecked Sendable {
    enum SummaryOutcome {
        case value(String)
        case failure(ProviderError)
    }

    struct StreamOutcome {
        var text: String
        var finishReason: String? = "stop"
    }

    private let lock = NSLock()
    private var summaryOutcomes: [SummaryOutcome]
    private var streamOutcomes: [StreamOutcome]
    private var recorded: [CompletionRequest] = []
    private let classifierJSON: String

    init(
        summaries: [SummaryOutcome] = [],
        streams: [StreamOutcome] = [],
        classifierJSON: String =
            #"{"action":"suggest_answer","confidence":0.97,"target":"migration risk"}"#
    ) {
        summaryOutcomes = summaries
        streamOutcomes = streams
        self.classifierJSON = classifierJSON
    }

    var requests: [CompletionRequest] { lock.withLock { recorded } }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let outcome = lock.withLock { () -> StreamOutcome in
            recorded.append(request)
            if streamOutcomes.isEmpty { return StreamOutcome(text: "answer") }
            return streamOutcomes.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(outcome.text))
            continuation.yield(.completed(.init(
                finishReason: outcome.finishReason,
                usage: .init(promptTokens: 10, completionTokens: 2)
            )))
            continuation.finish()
        }
    }

    func completeReportingUsage<T: Decodable>(
        _ request: CompletionRequest,
        as type: T.Type
    ) async throws -> CompletedCall<T> {
        let payload: String
        let failure: ProviderError?
        if request.responseFormat?.name == "rolling_meeting_summary" {
            let outcome = lock.withLock { () -> SummaryOutcome in
                recorded.append(request)
                if summaryOutcomes.isEmpty {
                    return .value(Self.summaryJSON("Fallback summary"))
                }
                return summaryOutcomes.removeFirst()
            }
            switch outcome {
            case .value(let value):
                payload = value
                failure = nil
            case .failure(let error):
                payload = ""
                failure = error
            }
        } else {
            lock.withLock { recorded.append(request) }
            payload = classifierJSON
            failure = nil
        }
        if let failure { throw failure }
        return CompletedCall(
            value: try JSONDecoder().decode(type, from: Data(payload.utf8)),
            usage: .init(promptTokens: 10, completionTokens: 2)
        )
    }

    static func summaryJSON(_ overview: String) -> String {
        """
        {"overview":"\(overview)","decisions":[],"commitments":[],"unresolved_questions":[]}
        """
    }
}

private actor Slice2Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private var open = false

    func wait() async {
        guard !open else { return }
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}

private actor Slice2OneShotGate {
    private var consumed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false

    func wait() async {
        guard !consumed else { return }
        consumed = true
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor Slice2NthCallGate {
    let targetCall: Int
    private var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false

    init(targetCall: Int) { self.targetCall = targetCall }

    func wait() async {
        callCount += 1
        guard callCount == targetCall else { return }
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class Slice2BlockingSummaryProvider: LLMProvider, @unchecked Sendable {
    let summaryGate: Slice2Gate
    private let lock = NSLock()
    private var recorded: [CompletionRequest] = []

    init(summaryGate: Slice2Gate) { self.summaryGate = summaryGate }

    var requests: [CompletionRequest] { lock.withLock { recorded } }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.withLock { recorded.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.token("Proactive answer."))
            continuation.yield(.completed(.init(finishReason: "stop", usage: nil)))
            continuation.finish()
        }
    }

    func completeReportingUsage<T: Decodable>(
        _ request: CompletionRequest,
        as type: T.Type
    ) async throws -> CompletedCall<T> {
        lock.withLock { recorded.append(request) }
        let payload: String
        if request.responseFormat?.name == "rolling_meeting_summary" {
            await summaryGate.wait()
            payload = Slice2QueuedProvider.summaryJSON("Stale blocked summary")
        } else {
            payload =
                #"{"action":"suggest_answer","confidence":0.97,"target":"migration risk"}"#
        }
        return CompletedCall(
            value: try JSONDecoder().decode(type, from: Data(payload.utf8)),
            usage: nil
        )
    }
}

@MainActor
struct LiveCopilotSlice2Tests {
    private func turn(
        source: AudioSource = .mic,
        text: String = "meeting fact",
        start: TimeInterval,
        end: TimeInterval
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
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(label)")
        return false
    }

    private func waitForGate(_ gate: Slice2Gate, _ label: String) async {
        for _ in 0..<400 where !(await gate.started) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.started, Comment(rawValue: label))
    }

    private func waitForGate(_ gate: Slice2OneShotGate, _ label: String) async {
        for _ in 0..<400 where !(await gate.started) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.started, Comment(rawValue: label))
    }

    private func waitForGate(_ gate: Slice2NthCallGate, _ label: String) async {
        for _ in 0..<400 where !(await gate.started) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.started, Comment(rawValue: label))
    }

    @Test func rollingSummaryCadenceFailureRetainsStripAndRequestedCard() async {
        let provider = Slice2QueuedProvider(
            summaries: [
                .value(Slice2QueuedProvider.summaryJSON("Decision stays behind the flag")),
                .failure(.transport("refresh failed")),
            ],
            streams: [.init(text: "Recent catch-up")]
        )
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: provider,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings(sensitivity: .off)
        )

        await model.receive(turn(start: 0, end: 60), userSpeaking: false)
        #expect(model.rollingSummaryText == nil)
        await model.receive(turn(start: 60, end: 120), userSpeaking: false)
        await waitUntil("first rolling summary") { model.rollingSummaryText != nil }
        #expect(model.rollingSummaryText == "Decision stays behind the flag")

        model.requestCatchUp()
        await waitUntil("retained catch-up") { model.card?.isStreaming == false }
        let requested = model.card

        for index in 0..<5 {
            let start = 120 + Double(index * 24)
            await model.receive(turn(start: start, end: start + 24), userSpeaking: false)
        }
        let summaryCallsBeforeSixth = provider.requests.filter {
            $0.responseFormat?.name == "rolling_meeting_summary"
        }.count
        #expect(summaryCallsBeforeSixth == 1, "120 seconds without six turns is not eligible")

        await model.receive(turn(start: 240, end: 241), userSpeaking: false)
        await waitUntil("failed refresh latch") {
            if case .paused = model.availability { return true }
            return false
        }
        #expect(model.rollingSummaryText == "Decision stays behind the flag")
        #expect(model.card == requested, "background failure cannot erase requested presentation")
        #expect(model.canAsk, "a transient background failure must still permit an explicit retry")
    }

    @Test func proactivePreemptsBlockedSummaryAndStaleRefreshCannotCommit() async {
        let gate = Slice2Gate()
        let provider = Slice2BlockingSummaryProvider(summaryGate: gate)
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: provider,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings(preferredName: "Hoang")
        )

        await model.receive(turn(start: 0, end: 120), userSpeaking: false)
        await waitForGate(gate, "summary call did not reach the blocking provider")
        await model.receive(
            turn(
                source: .system,
                text: "Hoang, can you explain the migration risk?",
                start: 120,
                end: 121
            ),
            userSpeaking: false
        )
        await waitUntil("proactive preemption") { model.card?.text == "Proactive answer." }
        await gate.release()
        try? await Task.sleep(for: .milliseconds(30))

        #expect(model.card?.requested == false)
        #expect(model.rollingSummaryText == nil, "cancelled background work cannot commit late")
    }

    @Test func askStreamsBoundedIndependentMeetingOnlyQueriesAndClampsInput() async throws {
        let provider = Slice2QueuedProvider(streams: [
            .init(text: "FIRST_GENERATED_ANSWER"),
            .init(text: "SECOND_GENERATED_ANSWER"),
        ])
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: provider,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings(sensitivity: .off)
        )
        await model.setAutomaticSuppressed(true)
        await model.receive(
            turn(text: "CURRENT_MEETING_ONLY launch is Friday", start: 0, end: 1),
            userSpeaking: false
        )
        for index in 0..<12 {
            await model.receive(
                turn(
                    text: String(repeating: "\u{0001}", count: 5_000) + " turn-\(index)",
                    start: 1,
                    end: 1
                ),
                userSpeaking: false
            )
        }

        model.requestAsk()
        let focusRevision = model.askFocusRevision
        #expect(model.askFieldVisible)
        #expect(!(await model.submitAsk()), "empty Return must not start a call")
        model.queryText = String(repeating: "q", count: 900)
        #expect(model.queryText.count == LiveCopilotModel.maximumQueryCharacters)
        model.queryText = "FIRST_UNIQUE_QUESTION"
        #expect(await model.submitAsk())
        await waitUntil("first query") { model.card?.text == "FIRST_GENERATED_ANSWER" }
        #expect(model.card?.queryQuestion == "FIRST_UNIQUE_QUESTION")
        #expect(model.askFocusRevision == focusRevision)
        #expect(model.queryText.isEmpty)

        model.queryText = "SECOND_UNIQUE_QUESTION"
        #expect(await model.submitAsk())
        await waitUntil("second query") { model.card?.text == "SECOND_GENERATED_ANSWER" }
        let queryRequests = provider.requests.filter { $0.maxTokens == CopilotGenerator.queryOutputTokenCeiling }
        #expect(queryRequests.count == 2)
        for request in queryRequests {
            #expect(request.messages.reduce(0) { $0 + $1.content.count }
                <= CopilotContextLimits.hardCharacterLimit)
            #expect(request.messages.map(\.content).joined().contains("CURRENT_MEETING_ONLY"))
        }
        let second = queryRequests[1].messages.map(\.content).joined(separator: "\n")
        #expect(second.contains("SECOND_UNIQUE_QUESTION"))
        #expect(!second.contains("FIRST_UNIQUE_QUESTION"))
        #expect(!second.contains("FIRST_GENERATED_ANSWER"))
    }

    @Test func nonStopQueryRollsBackPartialPresentation() async {
        let provider = Slice2QueuedProvider(streams: [
            .init(text: "unsafe partial", finishReason: "length")
        ])
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: provider,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings(sensitivity: .off)
        )
        await model.receive(turn(start: 0, end: 1), userSpeaking: false)
        model.requestAsk()
        model.queryText = "What happened?"
        #expect(await model.submitAsk())
        await waitUntil("non-stop rollback") {
            model.card == nil && model.availability != .working
        }
        #expect(model.card == nil)
        #expect(!provider.requests.isEmpty)
    }

    @Test func taskCannotReachProviderUntilArbiterAttachGateOpens() async {
        let gate = Slice2OneShotGate()
        let provider = Slice2QueuedProvider(streams: [.init(text: "attached answer")])
        let model = LiveCopilotModel(workAttachCheckpoint: { await gate.wait() })
        model.beginMeeting(
            provider: provider,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings(sensitivity: .off)
        )
        await model.receive(turn(start: 0, end: 1), userSpeaking: false)
        model.requestAsk()
        model.queryText = "Is the task attached?"
        let submission = Task { @MainActor in await model.submitAsk() }
        await waitForGate(gate, "work attach checkpoint was not reached")
        #expect(provider.requests.isEmpty, "provider work must remain behind the start gate")
        await gate.release()
        #expect(await submission.value)
        await waitUntil("attached query") { model.card?.text == "attached answer" }
    }

    @Test func immediateAskDismissCancelsPendingAdmissionWithoutRetainedLease() async {
        let admissionGate = Slice2OneShotGate()
        let summaryGate = Slice2Gate()
        let provider = Slice2BlockingSummaryProvider(summaryGate: summaryGate)
        let model = LiveCopilotModel(
            explicitAdmissionCheckpoint: { await admissionGate.wait() }
        )
        model.beginMeeting(
            provider: provider,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings(sensitivity: .off)
        )

        await model.receive(turn(start: 0, end: 120), userSpeaking: false)
        await waitForGate(summaryGate, "background summary did not start")

        model.requestAsk()
        await waitForGate(admissionGate, "Ask admission did not suspend")
        #expect(model.askFieldVisible)
        model.dismissCard()
        await admissionGate.release()
        await summaryGate.release()
        try? await Task.sleep(for: .milliseconds(30))
        let ownership = await model.arbiterOwnershipForTesting()
        #expect(ownership.active == nil)
        #expect(ownership.retained == nil)
        #expect(!model.askFieldVisible)
    }

    @Test func dismissDuringSubmitReleasesOpenAskLeaseAndAllowsBackgroundRefresh() async {
        let gate = Slice2NthCallGate(targetCall: 2)
        let provider = Slice2QueuedProvider(
            summaries: [.value(Slice2QueuedProvider.summaryJSON("Summary after dismissal"))]
        )
        let model = LiveCopilotModel(explicitAdmissionCheckpoint: { await gate.wait() })
        model.beginMeeting(
            provider: provider,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings(sensitivity: .off)
        )
        await model.receive(turn(start: 0, end: 60), userSpeaking: false)

        model.requestAsk()
        for _ in 0..<400 {
            if (await model.arbiterOwnershipForTesting().retained) != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect((await model.arbiterOwnershipForTesting().retained) != nil)

        model.queryText = "What was decided?"
        let submission = Task { @MainActor in await model.submitAsk() }
        await waitForGate(gate, "query submission did not suspend before admission")
        model.dismissCard()
        await gate.release()
        #expect(!(await submission.value))

        await model.receive(turn(start: 60, end: 120), userSpeaking: false)
        await waitUntil("summary after dismissed submit") {
            model.rollingSummaryText == "Summary after dismissal"
        }
        let ownership = await model.arbiterOwnershipForTesting()
        #expect(ownership.active == nil)
        #expect(ownership.retained == nil)
    }

    @Test func providerReplacementCancelsPendingCatchUpBeforeItCapturesOldGenerator() async {
        let gate = Slice2OneShotGate()
        let oldProvider = Slice2QueuedProvider(streams: [.init(text: "old provider")])
        let newProvider = Slice2QueuedProvider(streams: [.init(text: "new provider")])
        let meetingID = UUID()
        let model = LiveCopilotModel(explicitAdmissionCheckpoint: { await gate.wait() })
        model.beginMeeting(
            meetingID: meetingID,
            provider: oldProvider,
            fastModel: "old-fast",
            deepModel: "old-deep",
            settings: LiveAISettings(sensitivity: .off)
        )
        await model.receive(turn(start: 0, end: 61), userSpeaking: false)

        model.requestCatchUp()
        await waitForGate(gate, "Catch Up admission did not suspend")
        let replacement = Task { @MainActor in
            await model.replaceProviderAndWait(
                newProvider,
                fastModel: "new-fast",
                deepModel: "new-deep",
                expectedMeetingID: meetingID,
                replacementID: UUID()
            )
        }
        #expect(oldProvider.requests.isEmpty)
        await gate.release()
        await replacement.value
        #expect(oldProvider.requests.isEmpty)

        model.requestCatchUp()
        await waitUntil("new-provider catch-up") { model.card?.text == "new provider" }
        #expect(newProvider.requests.count == 1)
        #expect(newProvider.requests.first?.model == "new-deep")
    }

    @Test func aiOffClearsGeneratedStateButPreservesTurnsAndCannotResurrectWork() async {
        let gate = Slice2Gate()
        let provider = Slice2BlockingSummaryProvider(summaryGate: gate)
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: provider,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings(sensitivity: .off)
        )
        await model.receive(turn(start: 0, end: 120), userSpeaking: false)
        await waitForGate(gate, "summary was not blocked")

        await model.applyLiveSettings(LiveAISettings(aiFeaturesEnabled: false))
        let disabled = await model.contextSnapshotForTesting()
        #expect(disabled.allTurns.count == 1)
        #expect(disabled.currentSummary == nil)
        #expect(model.rollingSummaryText == nil)
        await model.applyLiveSettings(LiveAISettings(aiFeaturesEnabled: true, sensitivity: .off))
        await gate.release()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.rollingSummaryText == nil)
        #expect(model.card == nil)
    }

    @Test func threeHourContextAndEveryDeepPathRemainUnderSixtyThousandCharacters() async {
        let provider = Slice2QueuedProvider(
            streams: [
                .init(text: "bounded proactive"),
                .init(text: "bounded catch-up"),
            ],
            classifierJSON:
                #"{"action":"suggest_answer","confidence":0.99,"target":"three hour risk"}"#
        )
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: provider,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings(preferredName: "Hoang")
        )
        await model.setAutomaticSuppressed(true)
        for index in 0..<180 {
            let text = index >= 178
                ? String(repeating: "X", count: 40_000) + " tail-\(index)"
                : String(repeating: "context ", count: 40) + "turn-\(index)"
            await model.receive(
                turn(
                    text: text,
                    start: Double(index * 60),
                    end: Double((index + 1) * 60)
                ),
                userSpeaking: false
            )
        }
        let snapshot = await model.contextSnapshotForTesting()
        #expect(snapshot.transcriptSeconds == 10_800)

        await model.setAutomaticSuppressed(false)
        await model.receive(
            turn(
                source: .system,
                text: "Hoang, can you explain the three hour risk?",
                start: 10_800,
                end: 10_801
            ),
            userSpeaking: false
        )
        await waitUntil("bounded proactive") { model.card?.text == "bounded proactive" }
        model.dismissCard()

        await model.setAutomaticSuppressed(true)
        model.requestCatchUp()
        await waitUntil("bounded catch-up") { model.card?.text == "bounded catch-up" }

        let allLiveRequests = provider.requests.filter {
            $0.purpose == .classifier || $0.purpose == .generation
        }
        #expect(allLiveRequests.count == 3)
        for request in allLiveRequests {
            #expect(request.messages.reduce(0) { $0 + $1.content.count }
                <= CopilotContextLimits.hardCharacterLimit)
        }
        let generationRequests = allLiveRequests.filter { $0.purpose == .generation }
        #expect(generationRequests.count == 2)
    }

    @Test func panelInteractionAccessibilityAndShortcutContractIsComplete() {
        #expect(PanelView.dismissShortcutAccessibilityHint
            == "Keyboard shortcut Option Command D")
        #expect(HotKey.catchUpKeyCode == UInt32(kVK_ANSI_C))
        #expect(HotKey.askKeyCode == UInt32(kVK_ANSI_K))
        #expect(HotKey.dismissCopilotKeyCode == UInt32(kVK_ANSI_D))
        #expect(HotKey.copilotModifiers == UInt32(optionKey | cmdKey))
    }
}
