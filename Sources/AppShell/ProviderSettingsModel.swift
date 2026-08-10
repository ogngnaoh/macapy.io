import Foundation
import Observation
import PersistKit
import ProviderKit
import os

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
    @ObservationIgnored private let onSettingsChange: @MainActor (ProviderSettings) async -> Void
    @ObservationIgnored private var keyedProfileIDs: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: "io.macapy.app", category: "AppShell")

    init(
        profiles: [EndpointProfile] = EndpointProfile.wired,
        credentials: any CredentialStore,
        settingsStore: SettingsStore?,
        ledger: (any SpendLedger)?,
        session: URLSession = .shared,
        onSettingsChange: @escaping @MainActor (ProviderSettings) async -> Void = { _ in }
    ) {
        self.profiles = profiles
        self.credentials = credentials
        self.settingsStore = settingsStore
        self.ledger = ledger
        self.session = session
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
        await persistSettings()
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
            await onSettingsChange(settings)
        }
    }

    func removeKey(for profileID: String) async {
        try? credentials.delete(for: profileID)
        refreshKeyedProfiles()
        connectionTest = .idle
        await onSettingsChange(settings)
    }

    func setModelOverride(_ model: String, tier: ModelTier, for profileID: String) async {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tier {
        case .fast: settings.fastModelOverrides[profileID] = trimmed.isEmpty ? nil : trimmed
        case .deep: settings.deepModelOverrides[profileID] = trimmed.isEmpty ? nil : trimmed
        }
        await persistSettings()
    }

    func setCap(_ capUSD: Double?) async {
        settings.perMeetingCapUSD = capUSD
        await persistSettings()
    }

    enum ModelTier { case fast, deep }

    private func persistSettings() async {
        guard let settingsStore else { return }
        do {
            try await settingsStore.setProviderSettings(settings)
        } catch {
            log.error("failed to persist provider settings: \(error.localizedDescription)")
        }
        await onSettingsChange(settings)
    }

    // MARK: - Test connection

    private var registry: ProviderRegistry {
        ProviderRegistry(profiles: profiles, credentials: credentials, session: session)
    }

    /// Streams a one-word completion to prove the key and model ids work. Booked
    /// in the ledger like any other call — it spends the user's money, so it
    /// belongs in the Spend tab (`meetingID` is nil: there's no meeting yet).
    func testConnection() async {
        guard let profile = selectedProfile, let client = try? registry.client(for: settings) else {
            connectionTest = .failed(
                selectedProfile == nil
                    ? "Choose a provider first."
                    : "Add an API key for this provider first."
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
            for try await event in provider.stream(request) {
                if case .token(let token) = event { reply += token }
            }
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            connectionTest = .succeeded(text.isEmpty ? "Connected." : text)
        } catch {
            connectionTest = .failed((error as? ProviderError)?.userMessage ?? "The call failed.")
        }
        await refreshSpend()
    }
}
