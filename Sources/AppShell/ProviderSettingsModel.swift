import Foundation
import Observation
import PersistKit
import ProviderKit
import os

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

    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let settingsStore: SettingsStore?
    @ObservationIgnored private let ledger: (any SpendLedger)?
    @ObservationIgnored private let session: URLSession
    /// Test-only transport seam. Production always leaves this `nil` and
    /// constructs the selected profile through `ProviderRegistry`.
    @ObservationIgnored private let connectionTestProviderOverride: (any LLMProvider)?
    @ObservationIgnored private let onSettingsChange:
        @MainActor (ProviderSettings, ProviderSettingsChange) async -> Void
    @ObservationIgnored private var keyedProfileIDs: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: "io.macapy.app", category: "AppShell")

    init(
        profiles: [EndpointProfile] = EndpointProfile.wired,
        credentials: any CredentialStore,
        settingsStore: SettingsStore?,
        ledger: (any SpendLedger)?,
        session: URLSession = .shared,
        connectionTestProvider: (any LLMProvider)? = nil,
        onSettingsChange: @escaping @MainActor (ProviderSettings, ProviderSettingsChange) async -> Void = { _, _ in }
    ) {
        self.profiles = profiles
        self.credentials = credentials
        self.settingsStore = settingsStore
        self.ledger = ledger
        self.session = session
        self.connectionTestProviderOverride = connectionTestProvider
        self.onSettingsChange = onSettingsChange
    }

    // MARK: - Loading

    func load() async {
        if let settingsStore {
            settings = (try? await settingsStore.providerSettings()) ?? ProviderSettings()
            pricing = (try? await settingsStore.pricing()) ?? PricingTable.defaults
        }
        refreshKeyedProfiles()
        await refreshSpend()
    }

    private func refreshKeyedProfiles() {
        keyedProfileIDs = Set(profiles.compactMap { profile in
            let key = try? credentials.key(for: profile.id)
            return (key?.isEmpty == false) ? profile.id : nil
        })
    }

    private func refreshSpend() async {
        guard let store = ledger as? SpendLedgerStore else { return }
        spendEntries = ((try? await store.allEntries()) ?? []).reversed()
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
        settings.selectedProfileID = profileID
        await persistSettings(change: .transport)
    }

    func saveKey(_ key: String, for profileID: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try credentials.store(trimmed, for: profileID)
        } catch {
            // Never log the key itself — only that storing it failed.
            log.error("failed to store credential: \(String(describing: error))")
        }
        refreshKeyedProfiles()
        if settings.selectedProfileID == nil {
            await select(profileID: profileID)
        } else {
            // Credential replacement is a material configuration change even
            // though the settings value itself is unchanged. Notify the live
            // copilot so an authentication hard-pause can admit a retry.
            await onSettingsChange(settings, .transport)
        }
    }

    func removeKey(for profileID: String) async {
        try? credentials.delete(for: profileID)
        refreshKeyedProfiles()
        connectionTest = .idle
        await onSettingsChange(settings, .transport)
    }

    func setModelOverride(_ model: String, tier: ModelTier, for profileID: String) async {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tier {
        case .fast: settings.fastModelOverrides[profileID] = trimmed.isEmpty ? nil : trimmed
        case .deep: settings.deepModelOverrides[profileID] = trimmed.isEmpty ? nil : trimmed
        }
        await persistSettings(change: .modelOverride)
    }

    func setCap(_ capUSD: Double?) async {
        settings.perMeetingCapUSD = capUSD
        await persistSettings(change: .cap)
    }

    enum ModelTier { case fast, deep }

    private func persistSettings(change: ProviderSettingsChange) async {
        guard let settingsStore else { return }
        do {
            try await settingsStore.setProviderSettings(settings)
        } catch {
            log.error("failed to persist provider settings: \(error.localizedDescription)")
        }
        await onSettingsChange(settings, change)
    }

    // MARK: - Test connection

    private var registry: ProviderRegistry {
        ProviderRegistry(profiles: profiles, credentials: credentials, session: session)
    }

    /// Streams a one-word completion to prove the key and model ids work. Booked
    /// in the ledger like any other call — it spends the user's money, so it
    /// belongs in the Spend tab (`meetingID` is nil: there's no meeting yet).
    func testConnection() async {
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
        let provider: any LLMProvider = ledger.map {
            MeteredProvider(
                upstream: client,
                meter: SpendMeter(ledger: $0, pricing: pricing, capUSD: nil),
                meetingID: nil
            )
        } ?? client

        let request = CompletionRequest(
            // M3 MVP uses the live-verified profile default. Historical
            // overrides stay stored for the multi-provider fast-follow but are
            // intentionally ignored by every production call path.
            model: profile.fastModel,
            messages: [.user("Reply with the single word: OK")],
            purpose: .classifier,
            maxTokens: 16
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
            connectionTest = .succeeded(text)
        } catch is CancellationError {
            connectionTest = .idle
        } catch {
            connectionTest = .failed((error as? ProviderError)?.userMessage ?? "The call failed.")
        }
        await refreshSpend()
    }
}
