import AgentKit
import Foundation
import MemoryKit
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
/// invariant. Provider construction and lifetime remain an AppShell concern.
actor MeetingSpendRegistry {
    private var meters: [UUID: SpendMeter] = [:]

    func register(_ meter: SpendMeter, meetingID: UUID) { meters[meetingID] = meter }
    func registerIfAbsent(_ meter: SpendMeter, meetingID: UUID) -> SpendMeter {
        if let existing = meters[meetingID] { return existing }
        meters[meetingID] = meter
        return meter
    }
    func meter(meetingID: UUID) -> SpendMeter? { meters[meetingID] }
    func remove(meetingID: UUID) { meters[meetingID] = nil }
    func remove(meetingID: UUID, ifSameAs meter: SpendMeter) {
        guard meters[meetingID] === meter else { return }
        meters[meetingID] = nil
    }
    func count() -> Int { meters.count }
    func uncertainUSD(meetingID: UUID) async -> Double? {
        guard let meter = meters[meetingID] else { return nil }
        return await meter.uncertainUSD(meetingID: meetingID)
    }

    func updateCaps(_ capUSD: Double?, activeMeetingID: UUID?) async -> Bool {
        var activeCapRaised = false
        for (meetingID, meter) in meters {
            let previous = await meter.capUSD
            if meetingID == activeMeetingID, let previous {
                activeCapRaised = capUSD == nil || (capUSD ?? previous) > previous
            }
            await meter.updateCapUSD(capUSD)
        }
        return activeCapRaised
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

enum LiveCopilotCardKind: Sendable, Equatable {
    case action(CopilotAction)
    case query(String)
}

struct LiveCopilotCard: Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: LiveCopilotCardKind
    let target: String
    let requested: Bool
    var text: String
    var isStreaming: Bool
    var evidence: [RetrievedExcerpt] = []

    var action: CopilotAction? {
        guard case .action(let action) = kind else { return nil }
        return action
    }

    var queryQuestion: String? {
        guard case .query(let question) = kind else { return nil }
        return question
    }
}

/// Main-actor projection of `CopilotMeetingOrchestrator` output. It owns only
/// observable panel state, query focus/input, and proactive-card expiry.
@MainActor
@Observable
final class LiveCopilotModel {
    struct GroundingPreview: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }
    static let maximumQueryCharacters = 800

    private(set) var availability: CopilotAvailability = .idle
    private var projectedCard: LiveCopilotCard?
    private(set) var card: LiveCopilotCard? {
        get {
            reconcileAuthoritativePresentationClear()
            return projectedCard
        }
        set { projectedCard = newValue }
    }
    private(set) var rollingSummaryText: String?
    private(set) var askFieldVisible = false
    private(set) var askFocusRevision = 0
    private(set) var latestTranscriptTime: TimeInterval = 0
    var sourcePicker: LiveAskSourcesModel?
    var groundingPreview: GroundingPreview?
    var queryText = "" {
        didSet {
            if queryText.count > Self.maximumQueryCharacters {
                queryText = String(queryText.prefix(Self.maximumQueryCharacters))
            }
            if let sourcePicker, sourcePicker.question != normalizedQuery {
                sourcePicker.cancel(); self.sourcePicker = nil
            }
        }
    }

    var askPlaceholderVisible: Bool { askFieldVisible }

    @ObservationIgnored private var orchestrator: CopilotMeetingOrchestrator?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPresentationMutation: Task<Void, Never>?
    @ObservationIgnored private var pendingDomainCommand: Task<Void, Never>?
    @ObservationIgnored private var activeMeetingID: UUID?
    @ObservationIgnored private var sourceDatabase: MacapyDatabase?
    @ObservationIgnored private var activeGrounding: LiveQueryGrounding?
    @ObservationIgnored private var sourcePickerTask: Task<Void, Never>?
    @ObservationIgnored private var configuration = CopilotConfiguration(aiFeaturesEnabled: false)
    @ObservationIgnored private var providerAvailable = false
    @ObservationIgnored private var presentationRevision: UInt64 = 0
    @ObservationIgnored private var transientRecoveryCount = 0
    @ObservationIgnored private var awaitingRecoveryProjectionCount: Int?
    @ObservationIgnored private var observedPresentationClearGeneration: UInt64 = 0

    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var expiryRemaining: TimeInterval = 25
    @ObservationIgnored private var expiryStartedAt: Date?
    @ObservationIgnored private var cardHovered = false
    @ObservationIgnored private var cardFocused = false
    @ObservationIgnored private let proactiveLifetime: TimeInterval
    @ObservationIgnored private let waitForExpiry: @Sendable (TimeInterval) async throws -> Void

    @ObservationIgnored private let waitForRecovery: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private let providerReplacementCheckpoint: (@Sendable (UUID) async -> Void)?
    @ObservationIgnored private let explicitAdmissionCheckpoint: (@Sendable () async -> Void)?
    @ObservationIgnored private let workAttachCheckpoint: (@Sendable () async -> Void)?
    @ObservationIgnored private let presentationClearCheckpoint: (@Sendable () async -> Void)?
    @ObservationIgnored private let eventProjectionCheckpoint: (@Sendable (CopilotMeetingEvent) async -> Void)?
    @ObservationIgnored private let diagnosticsNow: @Sendable () -> Date

    /// Stable object retained by diagnostics after a meeting ends. AgentKit
    /// writes only opaque lease ids and timestamps into it.
    @ObservationIgnored let suggestionLatencyRecorder: SuggestionLatencyRecorder
    @ObservationIgnored private let recoveryDiagnostics = CopilotRecoveryDiagnostics()
    @ObservationIgnored private var presentationClearFence = CopilotPresentationClearFence()

    init(
        proactiveLifetime: TimeInterval = 25,
        waitForExpiry: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(for: .seconds(delay))
        },
        waitForRecovery: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(for: .seconds(delay))
        },
        providerReplacementCheckpoint: (@Sendable (UUID) async -> Void)? = nil,
        explicitAdmissionCheckpoint: (@Sendable () async -> Void)? = nil,
        workAttachCheckpoint: (@Sendable () async -> Void)? = nil,
        presentationClearCheckpoint: (@Sendable () async -> Void)? = nil,
        eventProjectionCheckpoint: (@Sendable (CopilotMeetingEvent) async -> Void)? = nil,
        suggestionLatencyRecorder: SuggestionLatencyRecorder = SuggestionLatencyRecorder(),
        diagnosticsNow: @escaping @Sendable () -> Date = Date.init
    ) {
        self.proactiveLifetime = proactiveLifetime
        self.waitForExpiry = waitForExpiry
        self.waitForRecovery = waitForRecovery
        self.providerReplacementCheckpoint = providerReplacementCheckpoint
        self.explicitAdmissionCheckpoint = explicitAdmissionCheckpoint
        self.workAttachCheckpoint = workAttachCheckpoint
        self.presentationClearCheckpoint = presentationClearCheckpoint
        self.eventProjectionCheckpoint = eventProjectionCheckpoint
        self.suggestionLatencyRecorder = suggestionLatencyRecorder
        self.diagnosticsNow = diagnosticsNow
    }

    var canCatchUp: Bool {
        canAsk && latestTranscriptTime >= 60
    }

    var canAsk: Bool {
        configuration.aiFeaturesEnabled && providerAvailable && explicitRequestsAllowedByPause
    }

    var canSubmitAsk: Bool { canAsk && !normalizedQuery.isEmpty }
    var sourceLookupAvailable: Bool { sourceDatabase != nil }
    var canOpenSources: Bool { canSubmitAsk && sourceLookupAvailable }
    var canDismiss: Bool { card != nil || askFieldVisible }
    var isMeetingActive: Bool { orchestrator != nil }

    func beginMeeting(
        meetingID: UUID = UUID(),
        provider: (any LLMProvider)?,
        fastModel: String,
        deepModel: String,
        settings: LiveAISettings,
        sourceDatabase: MacapyDatabase? = nil
    ) {
        stopMeeting()
        suggestionLatencyRecorder.reset()
        let meetingPresentationClearFence = CopilotPresentationClearFence()
        presentationClearFence = meetingPresentationClearFence
        observedPresentationClearGeneration = meetingPresentationClearFence.clearGeneration
        let preferredName = Self.normalizedName(settings.preferredName)
        configuration = CopilotConfiguration(
            aiFeaturesEnabled: settings.aiFeaturesEnabled,
            proactiveEnabled: settings.sensitivity != .off,
            confidenceThreshold: settings.sensitivity.confidenceThreshold,
            preferredName: preferredName,
            cooldownSeconds: 45
        )
        let domain = try! CopilotMeetingOrchestrator(
            meetingID: meetingID,
            configuration: configuration,
            provider: provider,
            models: CopilotMeetingModels(fast: fastModel, deep: deepModel),
            suggestionLatencyRecorder: suggestionLatencyRecorder,
            recoveryDiagnostics: recoveryDiagnostics,
            presentationClearFence: meetingPresentationClearFence,
            waitForRecovery: waitForRecovery,
            providerReplacementCheckpoint: providerReplacementCheckpoint,
            explicitAdmissionCheckpoint: explicitAdmissionCheckpoint,
            workAttachCheckpoint: workAttachCheckpoint,
            presentationClearCheckpoint: presentationClearCheckpoint,
            diagnosticsNow: diagnosticsNow
        )
        orchestrator = domain
        activeMeetingID = meetingID
        self.sourceDatabase = sourceDatabase
        providerAvailable = provider != nil
        availability = !settings.aiFeaturesEnabled
            ? .disabled
            : (provider == nil ? .setupRequired : .ready)
        eventTask = Task { @MainActor [weak self, domain] in
            for await event in await domain.eventsStream() {
                await self?.eventProjectionCheckpoint?(event)
                guard !Task.isCancelled, self?.orchestrator === domain else { return }
                self?.project(event)
            }
        }
    }

    func applyLiveSettings(_ settings: LiveAISettings) async {
        guard let orchestrator else { return }
        configuration.aiFeaturesEnabled = settings.aiFeaturesEnabled
        configuration.proactiveEnabled = settings.sensitivity != .off
        configuration.confidenceThreshold = settings.sensitivity.confidenceThreshold
        if !settings.aiFeaturesEnabled {
            presentationRevision &+= 1
            clearPresentation(clearSummary: true)
            availability = .disabled
        } else if settings.sensitivity == .off, card?.requested == false {
            expiryTask?.cancel()
            expiryTask = nil
            card = nil
            resetCardInteraction()
        }
        let committedAvailability = await orchestrator.updateConfiguration(configuration)
        guard self.orchestrator === orchestrator else { return }
        // Configuration is a command boundary, not an eventually-consistent
        // presentation update. Commit its authoritative admission state before
        // returning so an immediately following Catch Up/Ask cannot lose a
        // race with the AsyncStream projection task.
        project(.availability(committedAvailability))
    }

    func replaceProviderAndWait(
        _ provider: (any LLMProvider)?,
        fastModel: String,
        deepModel: String,
        expectedMeetingID: UUID,
        replacementID: UUID
    ) async {
        guard activeMeetingID == expectedMeetingID, let orchestrator else { return }
        invalidateGrounding()
        pendingDomainCommand?.cancel()
        pendingDomainCommand = nil
        let outcome = await orchestrator.replaceProvider(
            provider,
            models: CopilotMeetingModels(fast: fastModel, deep: deepModel),
            replacementID: replacementID
        )
        guard self.orchestrator === orchestrator, activeMeetingID == expectedMeetingID else { return }
        guard case .committed(let state) = outcome else { return }
        providerAvailable = state.providerAvailable
        if configuration.aiFeaturesEnabled {
            project(.availability(state.availability))
        } else {
            availability = .disabled
        }
    }

    func receive(_ transcriptTurn: TranscriptTurn, userSpeaking: Bool, now: Date = Date()) async {
        // This is intentionally the first operation: G2 includes all context
        // append and admission time after the finalized turn reaches AppShell.
        let receivedAt = diagnosticsNow()
        guard let orchestrator else { return }
        await pendingPresentationMutation?.value
        pendingPresentationMutation = nil
        guard self.orchestrator === orchestrator else { return }
        let turn = CopilotTurn(
            id: transcriptTurn.id,
            source: transcriptTurn.source,
            text: transcriptTurn.text,
            segmentIDs: transcriptTurn.segmentIDs,
            tStart: transcriptTurn.tStart,
            tEnd: transcriptTurn.tEnd
        )
        latestTranscriptTime = max(latestTranscriptTime, turn.tEnd)
        await orchestrator.receive(
            turn,
            userSpeaking: userSpeaking,
            now: now,
            receivedAt: receivedAt
        )
    }

    func requestCatchUp() {
        guard canCatchUp, let orchestrator else { return }
        presentationRevision &+= 1
        let revision = presentationRevision
        clearPresentation(clearSummary: false)
        pendingDomainCommand?.cancel()
        let command = Task { @MainActor [weak self, orchestrator] in
            guard let self, self.presentationRevision == revision else { return }
            _ = await orchestrator.requestCatchUp()
        }
        pendingDomainCommand = command
    }

    func requestAsk() {
        guard canAsk, let orchestrator else { return }
        clearGroundingSelection()
        presentationRevision &+= 1
        let revision = presentationRevision
        expiryTask?.cancel()
        expiryTask = nil
        card = nil
        askFieldVisible = true
        queryText = ""
        askFocusRevision &+= 1
        resetCardInteraction()
        pendingDomainCommand?.cancel()
        let command = Task { @MainActor [weak self, orchestrator] in
            guard let self, self.presentationRevision == revision else { return }
            _ = await orchestrator.reserveQuerySurface()
        }
        pendingDomainCommand = command
    }

    @discardableResult
    func submitAsk() async -> Bool {
        let question = normalizedQuery
        guard canAsk, !question.isEmpty, let orchestrator else { return false }
        await pendingPresentationMutation?.value
        pendingPresentationMutation = nil
        guard self.orchestrator === orchestrator, canAsk else { return false }
        clearGroundingSelection()
        pendingDomainCommand?.cancel()
        pendingDomainCommand = nil
        presentationRevision &+= 1
        let revision = presentationRevision
        queryText = ""
        guard let started = await orchestrator.requestQuery(question),
              self.orchestrator === orchestrator,
              presentationRevision == revision
        else { return false }
        // `.card` is emitted before provider work begins. Do not project the
        // admission result here: a fast failure may already have emitted the
        // newer rollback event while this actor call was suspended.
        _ = started
        askFieldVisible = true
        availability = .working
        return true
    }

    func openSources() {
        guard canOpenSources, let database = sourceDatabase, let orchestrator, let meetingID = activeMeetingID else { return }
        sourcePickerTask?.cancel()
        let question = normalizedQuery, revision = presentationRevision
        sourcePickerTask = Task { [weak self] in
            guard let self else { return }
            let recent = await orchestrator.recentTranscriptEvidence()
            guard !Task.isCancelled, self.orchestrator === orchestrator, activeMeetingID == meetingID,
                  presentationRevision == revision, normalizedQuery == question, canAsk else { return }
            sourcePicker = LiveAskSourcesModel(database: database, question: question, recentTranscript: recent,
                onSend: { [weak self] selection in
                    guard let self, self.orchestrator === orchestrator, self.activeMeetingID == meetingID else { return false }
                    return await self.submitGroundedAsk(question: question, selection: selection)
                })
        }
    }

    private func submitGroundedAsk(question: String, selection: LiveQueryGrounding) async -> Bool {
        guard canAsk, normalizedQuery == question, let orchestrator else { return false }
        await pendingPresentationMutation?.value
        pendingPresentationMutation = nil
        guard self.orchestrator === orchestrator, canAsk else { return false }
        pendingDomainCommand?.cancel(); pendingDomainCommand = nil
        presentationRevision &+= 1
        let revision = presentationRevision
        activeGrounding = selection; sourcePicker = nil; groundingPreview = nil
        queryText = ""
        guard let _ = await orchestrator.requestQuery(question, grounding: selection),
              self.orchestrator === orchestrator, presentationRevision == revision else { return false }
        askFieldVisible = true; availability = .working
        return true
    }

    /// Root invokes this before source edits/deletion or privacy revocation.
    /// Meeting-only work remains available when no grounded request exists.
    func invalidateGrounding() {
        let hadGrounding = activeGrounding != nil
        clearGroundingSelection()
        guard hadGrounding, let orchestrator else { return }
        presentationRevision &+= 1
        card = nil
        pendingPresentationMutation = Task { await orchestrator.dismissPresentation() }
        restoreProjectedAvailability()
    }

    func previewGrounding(_ evidence: RetrievedExcerpt) async {
        guard let selection = activeGrounding, let orchestrator,
              card?.evidence.contains(where: { $0.citationID == evidence.citationID }) == true else { return }
        let revision = presentationRevision
        guard await selection.validateExternal(), await orchestrator.validateTranscriptEvidence(selection.recentTranscript),
              self.orchestrator === orchestrator, presentationRevision == revision else { invalidateGrounding(); return }
        var text = evidence.text
        if !evidence.sources.isEmpty, let database = sourceDatabase {
            let memory = MemoryStore(database: database)
            for source in evidence.sources {
                guard let original = try? await memory.sourcePreview(source) else { invalidateGrounding(); return }
                text += "\n\nOriginal evidence:\n" + original
                text = String(text.prefix(8_000))
            }
        }
        guard await selection.validateExternal(), self.orchestrator === orchestrator, presentationRevision == revision else { return }
        groundingPreview = .init(title: evidence.title, text: text)
    }

    private func clearGroundingSelection() {
        sourcePickerTask?.cancel(); sourcePickerTask = nil
        sourcePicker?.cancel(); sourcePicker = nil; groundingPreview = nil; activeGrounding = nil
    }

    func dismissCard() {
        guard canDismiss, let orchestrator else { return }
        presentationRevision &+= 1
        pendingDomainCommand?.cancel()
        pendingDomainCommand = nil
        clearPresentation(clearSummary: false)
        let mutation = Task { await orchestrator.dismissPresentation() }
        pendingPresentationMutation = mutation
        restoreProjectedAvailability()
    }

    func setCardHovered(_ hovered: Bool, now: Date = Date()) {
        guard card?.requested == false else { return }
        cardHovered = hovered
        updateCardInteraction(now: now)
    }

    func setCardFocused(_ focused: Bool, now: Date = Date()) {
        guard card?.requested == false else { return }
        cardFocused = focused
        updateCardInteraction(now: now)
    }

    func releaseAuthenticationPauseAfterConfigurationChange() {
        guard availability == .setupRequired, let orchestrator else { return }
        Task { await orchestrator.releaseAuthenticationPause() }
        restoreProjectedAvailability()
    }

    func releaseCapPauseAfterCapIncrease() {
        guard case .paused(let message) = availability,
              message.localizedCaseInsensitiveContains("cap"),
              let orchestrator
        else { return }
        Task { await orchestrator.releaseCapPause() }
        restoreProjectedAvailability()
    }

    func setAutomaticSuppressed(_ suppressed: Bool) async {
        await orchestrator?.setAutomaticSuppressed(suppressed)
    }

    func stopMeeting() {
        let old = orchestrator
        eventTask?.cancel()
        eventTask = nil
        pendingPresentationMutation?.cancel()
        pendingPresentationMutation = nil
        pendingDomainCommand?.cancel()
        pendingDomainCommand = nil
        orchestrator = nil
        activeMeetingID = nil
        sourceDatabase = nil
        presentationRevision &+= 1
        suggestionLatencyRecorder.cancelPending()
        providerAvailable = false
        configuration = CopilotConfiguration(aiFeaturesEnabled: false)
        latestTranscriptTime = 0
        transientRecoveryCount = 0
        awaitingRecoveryProjectionCount = nil
        observedPresentationClearGeneration = presentationClearFence.clearGeneration
        clearPresentation(clearSummary: true)
        availability = .idle
        if let old { Task { await old.stop() } }
    }

    func stopMeetingAndWait() async {
        let old = orchestrator
        stopMeeting()
        await old?.stop()
    }

    func contextSnapshotForTesting() async -> CopilotContextSnapshot {
        if let orchestrator { return await orchestrator.contextSnapshot() }
        return CopilotContextSnapshot(
            allTurns: [],
            currentSummary: nil,
            transcriptSeconds: 0,
            refreshEligible: false
        )
    }

    func boundedQueryContextForTesting(question: String) async throws -> String {
        guard let orchestrator else { throw CancellationError() }
        return try await orchestrator.boundedQueryContext(question: question)
    }

    func arbiterOwnershipForTesting() async -> (
        active: CopilotWorkLease?,
        retained: CopilotWorkLease?
    ) {
        guard let orchestrator else { return (nil, nil) }
        return await orchestrator.arbiterOwnership()
    }

    var transientRecoveryFailureCountForTesting: Int {
        // Focused synchronous oracle for tests polling the injected recovery
        // scheduler. Domain failure clears partial presentation before it
        // advances this text-free counter; mirror that causal edge if the
        // AsyncStream projection has not received its already-enqueued events.
        let domainCount = recoveryDiagnostics.transientFailureCount
        if domainCount > transientRecoveryCount {
            card = nil
            transientRecoveryCount = domainCount
            awaitingRecoveryProjectionCount = domainCount
            availability = .paused("AI paused — the provider call failed.")
        }
        return transientRecoveryCount
    }

    var presentationClearFenceForTesting: CopilotPresentationClearFence {
        presentationClearFence
    }
}

private extension LiveCopilotModel {
    func project(_ event: CopilotMeetingEvent) {
        switch event {
        case .availability(let value):
            if !configuration.aiFeaturesEnabled, value != .disabled { return }
            if configuration.aiFeaturesEnabled, value == .disabled { return }
            if awaitingRecoveryProjectionCount != nil {
                switch value {
                case .ready, .working: return
                case .disabled, .setupRequired, .paused: break
                }
            }
            switch value {
            case .ready: availability = .ready
            case .disabled: availability = .disabled
            case .setupRequired: availability = .setupRequired
            case .working: availability = .working
            case .paused(let message): availability = .paused(message)
            }
        case .latestTranscriptTime(let time):
            // receive() already advances this at the command boundary. An
            // older queued projection from the same meeting cannot rewind it
            // and temporarily disable Catch Up after enough context arrived.
            latestTranscriptTime = max(latestTranscriptTime, time)
        case .card(let domainCard):
            if !configuration.aiFeaturesEnabled, domainCard != nil { return }
            if let domainCard {
                guard presentationClearFence.clearGeneration
                    == observedPresentationClearGeneration
                else { return }
                if awaitingRecoveryProjectionCount != nil, !domainCard.requested { return }
                projectCard(domainCard)
            } else {
                card = nil
                resetCardInteraction()
            }
        case .presentationCleared(let generation):
            guard generation > observedPresentationClearGeneration else { return }
            observedPresentationClearGeneration = generation
            expiryTask?.cancel()
            expiryTask = nil
            projectedCard = nil
            resetCardInteraction()
        case .rollingSummary(let text):
            rollingSummaryText = text
        case .recoveryFailureCount(let count):
            transientRecoveryCount = count
            if awaitingRecoveryProjectionCount == count {
                awaitingRecoveryProjectionCount = nil
            }
        }
    }

    func projectCard(_ domain: CopilotMeetingCard) {
        let clearGeneration = observedPresentationClearGeneration
        guard presentationClearFence.clearGeneration == clearGeneration else { return }
        let kind: LiveCopilotCardKind
        switch domain.kind {
        case .action(let action): kind = .action(action)
        case .query(let question): kind = .query(question)
        }
        let replacing = projectedCard?.id != domain.id
        projectedCard = LiveCopilotCard(
            id: domain.id,
            kind: kind,
            target: domain.target,
            requested: domain.requested,
            text: domain.text,
            isStreaming: domain.isStreaming,
            evidence: domain.evidence
        )
        guard presentationClearFence.clearGeneration == clearGeneration else {
            reconcileAuthoritativePresentationClear()
            return
        }
        if !domain.requested, !domain.text.isEmpty {
            suggestionLatencyRecorder.recordFirstVisible(domain.id, at: diagnosticsNow())
        }
        if replacing { resetCardInteraction() }
        if !domain.requested, !domain.isStreaming {
            scheduleExpiry(cardID: domain.id)
        }
    }

    func clearPresentation(clearSummary: Bool) {
        clearGroundingSelection()
        expiryTask?.cancel()
        expiryTask = nil
        card = nil
        askFieldVisible = false
        queryText = ""
        if clearSummary { rollingSummaryText = nil }
        resetCardInteraction()
    }

    func reconcileAuthoritativePresentationClear() {
        let generation = presentationClearFence.clearGeneration
        guard generation != observedPresentationClearGeneration else { return }
        observedPresentationClearGeneration = generation
        expiryTask?.cancel()
        expiryTask = nil
        projectedCard = nil
        resetCardInteraction()
    }

    func updateCardInteraction(now: Date) {
        let interacting = cardHovered || cardFocused
        if interacting {
            if let expiryStartedAt {
                expiryRemaining = max(0, expiryRemaining - now.timeIntervalSince(expiryStartedAt))
            }
            self.expiryStartedAt = nil
            expiryTask?.cancel()
            expiryTask = nil
        } else if let cardID = card?.id {
            scheduleExpiry(cardID: cardID)
        }
    }

    func scheduleExpiry(cardID: UUID) {
        guard card?.id == cardID,
              card?.requested == false,
              !cardHovered,
              !cardFocused
        else { return }
        expiryTask?.cancel()
        let delay = max(0, expiryRemaining)
        expiryStartedAt = Date()
        let waitForExpiry = self.waitForExpiry
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await waitForExpiry(delay)
                try Task.checkCancellation()
                guard let self,
                      self.card?.id == cardID,
                      self.card?.requested == false,
                      !self.cardHovered,
                      !self.cardFocused
                else { return }
                self.dismissCard()
            } catch {}
        }
    }

    func resetCardInteraction() {
        cardHovered = false
        cardFocused = false
        expiryRemaining = proactiveLifetime
        expiryStartedAt = nil
    }

    func restoreProjectedAvailability() {
        guard configuration.aiFeaturesEnabled else {
            availability = .disabled
            return
        }
        availability = providerAvailable ? .ready : .setupRequired
    }

    var normalizedQuery: String {
        queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var explicitRequestsAllowedByPause: Bool {
        switch availability {
        case .idle, .disabled, .setupRequired: false
        case .ready, .working: true
        case .paused(let message):
            !message.localizedCaseInsensitiveContains("cap")
        }
    }

    static func normalizedName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return String(trimmed.prefix(120))
    }
}
