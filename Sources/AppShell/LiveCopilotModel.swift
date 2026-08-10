import AgentKit
import CaptureKit
import Foundation
import Observation
import PersistKit
import ProviderKit
import TranscribeKit

/// In-memory ledger for an ephemeral meeting. It gives the live copilot the
/// same cap semantics as a persistent meeting without creating any disk rows.
actor EphemeralSpendLedger: SpendLedger {
    private(set) var entries: [SpendEntry] = []

    func record(_ entry: SpendEntry) async throws { entries.append(entry) }

    func totalCostUSD(meetingID: UUID) async throws -> Double {
        entries
            .filter { $0.meetingID == meetingID }
            .compactMap(\.estCostUSD)
            .reduce(0, +)
    }
}

/// Crosses the MainActor/Sendable boundary for the one-meter-per-meeting
/// invariant. The live copilot registers first; the post-meeting agent reuses
/// and then removes the same meter after extraction settles.
actor MeetingSpendRegistry {
    private var meters: [UUID: SpendMeter] = [:]

    func register(_ meter: SpendMeter, meetingID: UUID) { meters[meetingID] = meter }
    func meter(meetingID: UUID) -> SpendMeter? { meters[meetingID] }
    func remove(meetingID: UUID) { meters[meetingID] = nil }

    func updateCaps(_ capUSD: Double?) async {
        for meter in meters.values { await meter.updateCapUSD(capUSD) }
    }
}

enum CopilotAvailability: Sendable, Equatable {
    case idle
    case ready
    case disabled
    case setupRequired
    case working
    case paused(String)
}

struct LiveCopilotCard: Sendable, Equatable, Identifiable {
    let id: UUID
    let action: CopilotAction
    let target: String
    let requested: Bool
    var text: String
    var isStreaming: Bool
}

/// One meeting's presentation-facing copilot orchestrator. Nothing here is
/// persisted: turns, cards, catch-up text, timers, and provider state disappear
/// on teardown. Provider calls remain in AgentKit and cost rows in ProviderKit.
@MainActor
@Observable
final class LiveCopilotModel {
    private(set) var availability: CopilotAvailability = .idle
    private(set) var card: LiveCopilotCard?
    private(set) var askPlaceholderVisible = false
    private(set) var latestTranscriptTime: TimeInterval = 0

    @ObservationIgnored private var provider: (any LLMProvider)?
    @ObservationIgnored private var classifier: CopilotClassifier?
    @ObservationIgnored private var generator: CopilotGenerator?
    @ObservationIgnored private var configuration = CopilotConfiguration(aiFeaturesEnabled: false)
    @ObservationIgnored private var turns: [CopilotTurn] = []
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var activeWorkID: UUID?
    @ObservationIgnored private var lastProactiveAt: Date?
    @ObservationIgnored private var automaticSuppressed = false
    @ObservationIgnored private var currentWorkRequested = false
    @ObservationIgnored private var cardInteractionActive = false
    @ObservationIgnored private var expiryRemaining: TimeInterval = 25
    @ObservationIgnored private var expiryStartedAt: Date?
    @ObservationIgnored private let proactiveLifetime: TimeInterval

    init(proactiveLifetime: TimeInterval = 25) {
        self.proactiveLifetime = proactiveLifetime
    }

    var canCatchUp: Bool {
        configuration.aiFeaturesEnabled && provider != nil && latestTranscriptTime >= 60
    }

    var isMeetingActive: Bool { availability != .idle }

    func beginMeeting(
        provider: (any LLMProvider)?,
        fastModel: String,
        deepModel: String,
        settings: LiveAISettings
    ) {
        stopMeeting()
        let preferredName = Self.normalizedName(settings.preferredName)
        configuration = CopilotConfiguration(
            aiFeaturesEnabled: settings.aiFeaturesEnabled,
            proactiveEnabled: settings.sensitivity != .off,
            confidenceThreshold: settings.sensitivity.confidenceThreshold,
            preferredName: preferredName,
            cooldownSeconds: 45
        )
        self.provider = provider
        if let provider {
            classifier = CopilotClassifier(provider: provider, model: fastModel)
            generator = CopilotGenerator(provider: provider, model: deepModel)
        }
        availability = !settings.aiFeaturesEnabled
            ? .disabled
            : (provider == nil ? .setupRequired : .ready)
    }

    func applyLiveSettings(_ settings: LiveAISettings) {
        guard isMeetingActive else { return }
        configuration.aiFeaturesEnabled = settings.aiFeaturesEnabled
        configuration.proactiveEnabled = settings.sensitivity != .off
        configuration.confidenceThreshold = settings.sensitivity.confidenceThreshold
        // Preferred name is deliberately not updated: it is snapshotted at
        // meeting start so a mid-meeting settings edit cannot rewrite context.
        if !settings.aiFeaturesEnabled {
            cancelAndClear()
            availability = .disabled
        } else if settings.sensitivity == .off,
                  !currentWorkRequested,
                  card?.requested != true,
                  !askPlaceholderVisible
        {
            cancelAndClear()
            availability = provider == nil ? .setupRequired : .ready
        } else if card == nil, !askPlaceholderVisible {
            availability = provider == nil ? .setupRequired : .ready
        }
    }

    func receive(_ transcriptTurn: TranscriptTurn, userSpeaking: Bool, now: Date = Date()) {
        guard isMeetingActive else { return }
        let turn = CopilotTurn(
            id: transcriptTurn.id,
            source: transcriptTurn.source,
            text: transcriptTurn.text,
            segmentIDs: transcriptTurn.segmentIDs,
            tStart: transcriptTurn.tStart,
            tEnd: transcriptTurn.tEnd
        )
        turns.append(turn)
        latestTranscriptTime = max(latestTranscriptTime, turn.tEnd)

        guard provider != nil, !automaticSuppressed, workTask == nil, card == nil else { return }
        let gate = CopilotGate.evaluate(
            turn: turn,
            configuration: configuration,
            state: CopilotGateState(
                userSpeaking: userSpeaking,
                hasActiveProactiveCard: card != nil,
                lastProactiveAt: lastProactiveAt
            ),
            now: now
        )
        guard gate == .allowed else { return }

        let context = turns
        let preferredName = configuration.preferredName
        let threshold = configuration.confidenceThreshold
        let workID = UUID()
        activeWorkID = workID
        workTask = Task { [weak self] in
            guard let self else { return }
            currentWorkRequested = false
            await runProactive(
                workID: workID,
                context: context,
                preferredName: preferredName,
                threshold: threshold,
                triggeredAt: now
            )
        }
    }

    func requestCatchUp() {
        guard canCatchUp, let generator else { return }
        startRequested(action: .catchUp, target: "Last 90 seconds") {
            generator.catchUp(turns: self.turns)
        }
    }

    /// Slice 1 reserves the interaction and shortcut; Slice 2 replaces this
    /// quiet placeholder with the meeting-grounded query field.
    func requestAsk() {
        guard configuration.aiFeaturesEnabled, provider != nil else { return }
        cancelAndClear()
        askPlaceholderVisible = true
    }

    func dismissCard() {
        cancelAndClear()
        if isMeetingActive {
            availability = !configuration.aiFeaturesEnabled
                ? .disabled
                : (provider == nil ? .setupRequired : .ready)
        }
    }

    func setCardInteractionActive(_ active: Bool, now: Date = Date()) {
        guard card?.requested == false else { return }
        cardInteractionActive = active
        if active {
            if let expiryStartedAt {
                expiryRemaining = max(0, expiryRemaining - now.timeIntervalSince(expiryStartedAt))
            }
            expiryStartedAt = nil
            expiryTask?.cancel()
            expiryTask = nil
        } else if card != nil {
            scheduleExpiry()
        }
    }

    func setAutomaticSuppressed(_ suppressed: Bool) {
        automaticSuppressed = suppressed
        if suppressed,
           !currentWorkRequested,
           card?.requested != true,
           !askPlaceholderVisible
        {
            cancelAndClear()
            availability = !configuration.aiFeaturesEnabled
                ? .disabled
                : (provider == nil ? .setupRequired : .ready)
        }
    }

    func stopMeeting() {
        cancelAndClear()
        provider = nil
        classifier = nil
        generator = nil
        turns.removeAll()
        latestTranscriptTime = 0
        lastProactiveAt = nil
        automaticSuppressed = false
        availability = .idle
    }

    func stopMeetingAndWait() async {
        let inFlight = workTask
        stopMeeting()
        await inFlight?.value
    }

    private func runProactive(
        workID: UUID,
        context: [CopilotTurn],
        preferredName: String?,
        threshold: Double,
        triggeredAt: Date
    ) async {
        guard let classifier, let generator else {
            finish(workID, retainCard: false)
            return
        }
        do {
            let decision = try await classifier.classify(
                recentTurns: context,
                preferredName: preferredName
            )
            try Task.checkCancellation()
            guard decision.meetsThreshold(threshold),
                  let action = decision.action,
                  let target = decision.target
            else {
                finish(workID, retainCard: false)
                return
            }

            lastProactiveAt = triggeredAt
            card = LiveCopilotCard(
                id: workID,
                action: action,
                target: target,
                requested: false,
                text: "",
                isStreaming: true
            )
            availability = .working
            let stream: AsyncThrowingStream<CopilotTextEvent, Error>
            switch action {
            case .suggestAnswer:
                stream = generator.suggestedAnswer(turns: context, target: target)
            case .flagCommitment:
                stream = generator.commitment(turns: context, target: target)
            case .catchUp:
                // Structurally unreachable: strict classifier decoding rejects it.
                finish(workID, retainCard: false)
                return
            }
            try await consume(stream, cardID: workID)
            finish(workID, retainCard: true)
            scheduleExpiry()
        } catch is CancellationError {
            finish(workID, retainCard: false)
        } catch {
            finish(workID, retainCard: false)
            handle(error)
        }
    }

    private func startRequested(
        action: CopilotAction,
        target: String,
        makeStream: @escaping @MainActor () -> AsyncThrowingStream<CopilotTextEvent, Error>
    ) {
        cancelAndClear()
        let contextStream = makeStream()
        let workID = UUID()
        activeWorkID = workID
        // Synchronous with admission: pause can arrive before the Task gets
        // its first executor turn and must still recognize this as explicit.
        currentWorkRequested = true
        workTask = Task { [weak self] in
            guard let self else { return }
            card = LiveCopilotCard(
                id: workID,
                action: action,
                target: target,
                requested: true,
                text: "",
                isStreaming: true
            )
            availability = .working
            do {
                try await consume(contextStream, cardID: workID)
                finish(workID, retainCard: true)
            } catch is CancellationError {
                finish(workID, retainCard: false)
            } catch {
                finish(workID, retainCard: false)
                handle(error)
            }
        }
    }

    private func consume(
        _ stream: AsyncThrowingStream<CopilotTextEvent, Error>,
        cardID: UUID
    ) async throws {
        for try await event in stream {
            try Task.checkCancellation()
            guard card?.id == cardID else { throw CancellationError() }
            switch event {
            case .delta(let token): card?.text += token
            case .completed(let text):
                card?.text = text
                card?.isStreaming = false
                availability = .ready
            case .cleared:
                card = nil
            }
        }
    }

    private func finish(_ workID: UUID, retainCard: Bool) {
        guard activeWorkID == workID else { return }
        activeWorkID = nil
        workTask = nil
        currentWorkRequested = false
        if !retainCard { card = nil }
        if card == nil, configuration.aiFeaturesEnabled {
            availability = provider == nil ? .setupRequired : .ready
        }
    }

    private func handle(_ error: any Error) {
        card = nil
        if let providerError = error as? ProviderError {
            switch providerError {
            case .capReached:
                availability = .paused("AI paused — meeting cap reached.")
            case .missingCredentials, .http(status: 401, _), .http(status: 403, _):
                availability = .setupRequired
            default:
                availability = .paused("AI paused — \(providerError.userMessage)")
            }
        } else {
            availability = .paused("AI paused — the provider call failed.")
        }
    }

    private func scheduleExpiry() {
        guard card?.requested == false, !cardInteractionActive else { return }
        expiryTask?.cancel()
        let delay = max(0, expiryRemaining)
        expiryStartedAt = Date()
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard let self, !self.cardInteractionActive else { return }
                self.dismissCard()
            } catch {}
        }
    }

    private func cancelAndClear() {
        workTask?.cancel()
        workTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        activeWorkID = nil
        currentWorkRequested = false
        card = nil
        askPlaceholderVisible = false
        expiryRemaining = proactiveLifetime
        expiryStartedAt = nil
    }

    private static func normalizedName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
