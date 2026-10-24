import Foundation
import Observation
import PersistKit
import ProviderKit
import os

/// Small async boundary so reset races can be exercised without Keychain,
/// networking, or a blocking database test hook.
protocol ProviderPreferencesStoring: Sendable {
    func providerSettings() async throws -> ProviderSettings
    func pricing() async throws -> PricingTable
    func setProviderSettings(_ settings: ProviderSettings) async throws
}

extension SettingsStore: ProviderPreferencesStoring {}

enum ProviderSettingsChange: Sendable, Equatable {
    /// Profile selection or credential material changed, so the live client
    /// must be rebuilt and any work owned by the old transport drained.
    case transport
    /// Spend admission changed without changing the provider transport.
    case cap
    /// Historical MVP-ignored overrides remain persisted, but must not disturb
    /// live presentation state or rebuild the fixed-model provider.
    case modelOverride
}

/// State behind the Providers and Spend settings tabs: what's configured, what
/// a test call reported, and what this meeting has cost.
///
/// Keys are written straight through to the `CredentialStore` and never held in
/// a property — the only in-memory copy is the field the user is typing into,
/// which the view discards on submit (SPEC §8).
@MainActor
@Observable
final class ProviderSettingsModel {

    /// Result of the Providers tab's "test connection" action.
    enum ConnectionTest: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    let profiles: [EndpointProfile]

    private(set) var settings = ProviderSettings()
    private(set) var pricing = PricingTable.defaults
    private(set) var connectionTest: ConnectionTest = .idle
    /// Ledger rows for the Spend tab, newest meeting first.
    private(set) var spendEntries: [SpendEntry] = []
    private(set) var isResettingPreferences = false

    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let settingsStore: (any ProviderPreferencesStoring)?
    @ObservationIgnored private let ledger: (any SpendLedger)?
    @ObservationIgnored private let session: URLSession
    /// Test-only transport seam. Production always leaves this `nil` and
    /// constructs the selected profile through `ProviderRegistry`.
    @ObservationIgnored private let connectionTestProviderOverride: (any LLMProvider)?
    @ObservationIgnored private let requestInspector: RequestInspector?
    @ObservationIgnored private let onSettingsChange:
        @MainActor (ProviderSettings, ProviderSettingsChange) async -> Void
    @ObservationIgnored private var keyedProfileIDs: Set<String> = []
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var preferencesRevision: UInt64 = 0
    @ObservationIgnored private let log = Logger(subsystem: "io.macapy.app", category: "AppShell")

    init(
        profiles: [EndpointProfile] = EndpointProfile.wired,
        credentials: any CredentialStore,
        settingsStore: (any ProviderPreferencesStoring)?,
        ledger: (any SpendLedger)?,
        session: URLSession = .shared,
        connectionTestProvider: (any LLMProvider)? = nil,
        requestInspector: RequestInspector? = nil,
        onSettingsChange: @escaping @MainActor (ProviderSettings, ProviderSettingsChange) async -> Void = { _, _ in }
    ) {
        self.profiles = profiles
        self.credentials = credentials
        self.settingsStore = settingsStore
        self.ledger = ledger
        self.session = session
        self.connectionTestProviderOverride = connectionTestProvider
        self.requestInspector = requestInspector
        self.onSettingsChange = onSettingsChange
    }

    // MARK: - Loading

    func load() async {
        await perform { revision in await self.loadOwned(revision: revision) }
    }

    private func loadOwned(revision: UInt64, duringReset: Bool = false) async {
        if let settingsStore {
            let loadedSettings = (try? await settingsStore.providerSettings()) ?? ProviderSettings()
            guard isCurrent(revision, duringReset: duringReset) else { return }
            let loadedPricing = (try? await settingsStore.pricing()) ?? PricingTable.defaults
            guard isCurrent(revision, duringReset: duringReset) else { return }
            settings = loadedSettings
            pricing = loadedPricing
        }
        guard isCurrent(revision, duringReset: duringReset) else { return }
        refreshKeyedProfiles()
        await refreshSpend(revision: revision, duringReset: duringReset)
    }

    private func refreshKeyedProfiles() {
        keyedProfileIDs = Set(profiles.compactMap { profile in
            let key = try? credentials.key(for: profile.id)
            return (key?.isEmpty == false) ? profile.id : nil
        })
    }

    private func refreshSpend(revision: UInt64, duringReset: Bool = false) async {
        guard let store = ledger as? SpendLedgerStore else { return }
        let entries = ((try? await store.allEntries()) ?? []).reversed()
        guard isCurrent(revision, duringReset: duringReset) else { return }
        spendEntries = Array(entries)
    }

    /// Close admission and clear sensitive presentation before the first await.
    /// An older write may ignore cancellation, so the caller must await this
    /// drain before clearing persistent namespaces or credentials.
    func beginPreferencesReset() async {
        if !isResettingPreferences {
            isResettingPreferences = true
            preferencesRevision &+= 1
        }
        settings = ProviderSettings(); pricing = .defaults
        keyedProfileIDs = []; spendEntries = []; connectionTest = .idle
        let pending = Array(operations.values)
        pending.forEach { $0.cancel() }
        for operation in pending { await operation.value }
    }

    /// Reload the actual retained state even after a partial reset failure.
    /// Keep admission closed through the transport callback so an old control
    /// cannot write while the coordinator rebuilds its provider state.
    func endPreferencesReset() async {
        guard isResettingPreferences else { return }
        let revision = preferencesRevision
        await loadOwned(revision: revision, duringReset: true)
        guard isCurrent(revision, duringReset: true) else { return }
        await onSettingsChange(settings, .transport)
        guard isCurrent(revision, duringReset: true) else { return }
        isResettingPreferences = false
    }

    private func isCurrent(_ revision: UInt64, duringReset: Bool = false) -> Bool {
        preferencesRevision == revision && (duringReset || !isResettingPreferences) && !Task.isCancelled
    }

    private func perform(_ operation: @escaping @MainActor (UInt64) async -> Void) async {
        guard !isResettingPreferences, !Task.isCancelled else { return }
        let id = UUID(), revision = preferencesRevision
        let task = Task { @MainActor [weak self] in
            guard let self, self.isCurrent(revision) else { return }
            await operation(revision)
        }
        operations[id] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        operations[id] = nil
    }

    // MARK: - Queries the views ask

    func hasKey(for profileID: String) -> Bool {
        keyedProfileIDs.contains(profileID)
    }

    func profile(id: String) -> EndpointProfile? {
        profiles.first { $0.id == id }
    }

    /// Whether AI features can run at all — the difference between a live
    /// surface and the quiet setup prompt (PRD edge case).
    var isConfigured: Bool {
        registry.isConfigured(settings)
    }

    var selectedProfile: EndpointProfile? {
        settings.selectedProfileID.flatMap(profile(id:))
    }

    /// Spend for one meeting, and the cap it is measured against.
    func spentUSD(meetingID: UUID) -> Double {
        spendEntries
            .filter { $0.meetingID == meetingID }
            .compactMap(\.estCostUSD)
            .reduce(0, +)
    }

    /// True when at least one row in view has no known price, so the UI can say
    /// the total is partial instead of quietly understating it.
    var hasUnpricedEntries: Bool {
        spendEntries.contains { $0.estCostUSD == nil }
    }

    /// The meeting the Spend tab reports on: the most recent one with any AI
    /// spend (`spendEntries` is newest-first).
    var latestMeetingID: UUID? {
        spendEntries.first { $0.meetingID != nil }?.meetingID
    }

    /// `nil` when no meeting has spent anything yet — rendered as "—" rather
    /// than as $0.00.
    var latestMeetingSpendUSD: Double? {
        guard let latestMeetingID else { return nil }
        return spentUSD(meetingID: latestMeetingID)
    }

    // MARK: - Mutations

    func select(profileID: String?) async {
        await perform { revision in
            self.settings.selectedProfileID = profileID
            await self.persistSettings(change: .transport, revision: revision)
        }
    }

    func saveKey(_ key: String, for profileID: String) async {
        await perform { revision in await self.saveKeyOwned(key, for: profileID, revision: revision) }
    }

    private func saveKeyOwned(_ key: String, for profileID: String, revision: UInt64) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try credentials.store(trimmed, for: profileID)
        } catch {
            // Never log the key itself — only that storing it failed.
            log.error("failed to store credential: \(String(describing: type(of: error)), privacy: .public)")
        }
        refreshKeyedProfiles()
        if settings.selectedProfileID == nil {
            settings.selectedProfileID = profileID
            await persistSettings(change: .transport, revision: revision)
        } else {
            // Credential replacement is a material configuration change even
            // though the settings value itself is unchanged. Notify the live
            // copilot so an authentication hard-pause can admit a retry.
            await onSettingsChange(settings, .transport)
        }
    }

    func removeKey(for profileID: String) async {
        await perform { _ in
            try? self.credentials.delete(for: profileID)
            self.refreshKeyedProfiles()
            self.connectionTest = .idle
            await self.onSettingsChange(self.settings, .transport)
        }
    }

    func setModelOverride(_ model: String, tier: ModelTier, for profileID: String) async {
        await perform { revision in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            switch tier {
            case .fast: self.settings.fastModelOverrides[profileID] = trimmed.isEmpty ? nil : trimmed
            case .deep: self.settings.deepModelOverrides[profileID] = trimmed.isEmpty ? nil : trimmed
            }
            await self.persistSettings(change: .modelOverride, revision: revision)
        }
    }

    func setCap(_ capUSD: Double?) async {
        await perform { revision in
            self.settings.perMeetingCapUSD = capUSD
            await self.persistSettings(change: .cap, revision: revision)
        }
    }

    enum ModelTier { case fast, deep }

    private func persistSettings(change: ProviderSettingsChange, revision: UInt64) async {
        guard let settingsStore else { return }
        do {
            try await settingsStore.setProviderSettings(settings)
        } catch {
            log.error("failed to persist provider settings: \(String(describing: type(of: error)), privacy: .public)")
        }
        guard isCurrent(revision) else { return }
        await onSettingsChange(settings, change)
    }

    // MARK: - Test connection

    private var registry: ProviderRegistry {
        ProviderRegistry(profiles: profiles, credentials: credentials, session: session, inspector: requestInspector)
    }

    /// Streams a one-word completion to prove the key and model ids work. Booked
    /// in the ledger like any other call — it spends the user's money, so it
    /// belongs in the Spend tab (`meetingID` is nil: there's no meeting yet).
    func testConnection() async {
        await perform { revision in await self.testConnectionOwned(revision: revision) }
    }

    private func testConnectionOwned(revision: UInt64) async {
        guard let profile = selectedProfile else {
            connectionTest = .failed("Choose a provider first.")
            return
        }

        let client: any LLMProvider
        if let connectionTestProviderOverride {
            client = connectionTestProviderOverride
        } else if let configuredClient = try? registry.client(for: settings) {
            client = configuredClient
        } else {
            connectionTest = .failed(
                "Add an API key for this provider first."
            )
            return
        }

        connectionTest = .running
        let meter = ledger.map { SpendMeter(ledger: $0, pricing: pricing, capUSD: nil) }
        let provider: any LLMProvider = meter.map {
            MeteredProvider(
                upstream: client,
                meter: $0,
                meetingID: nil,
                beforeDispatch: { [weak self] in await self?.isCurrent(revision) == true }
            )
        } ?? client

        let request = CompletionRequest(
            // M3 MVP uses the live-verified profile default. Historical
            // overrides stay stored for the multi-provider fast-follow but are
            // intentionally ignored by every production call path.
            model: profile.fastModel,
            messages: [.user("Reply with the single word: OK")],
            purpose: .classifier,
            maxTokens: 16,
            contextSources: [.connectionTest]
        )

        do {
            var reply = ""
            var terminalCount = 0
            var terminalReason: String?
            var eventAfterTerminal = false

            // Drain the stream before deciding its disposition. In particular,
            // MeteredProvider settles reported usage immediately before it
            // releases `.completed`; stopping early would race spend booking.
            for try await event in provider.stream(request) {
                switch event {
                case .token(let token):
                    guard terminalCount == 0 else {
                        eventAfterTerminal = true
                        continue
                    }
                    reply += token
                case .reasoning:
                    if terminalCount > 0 { eventAfterTerminal = true }
                case .completed(let completion):
                    terminalCount += 1
                    if terminalCount == 1 {
                        terminalReason = ProviderError.safeTerminalReason(completion.finishReason)
                    }
                }
            }
            try Task.checkCancellation()

            guard terminalCount == 1, !eventAfterTerminal else {
                throw ProviderError.malformedResponse("stream did not contain exactly one final completion")
            }
            guard terminalReason == "stop" else {
                throw ProviderError.truncated(
                    finishReason: ProviderError.safeTerminalReason(terminalReason)
                )
            }

            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw ProviderError.malformedResponse("natural completion contained no answer text")
            }
            if isCurrent(revision) { connectionTest = .succeeded(text) }
        } catch is CancellationError {
            if preferencesRevision == revision, !isResettingPreferences { connectionTest = .idle }
        } catch {
            if isCurrent(revision) { connectionTest = .failed((error as? ProviderError)?.userMessage ?? "The call failed.") }
        }
        if let meter {
            // MeteredProvider intentionally settles reported usage on a
            // detached task. Cancellation of this consumer must not let a
            // reset race that write and then have an old row reappear.
            await Task.detached { try? await meter.waitForSettlements() }.value
        }
        guard isCurrent(revision) else { return }
        await refreshSpend(revision: revision)
    }
}
