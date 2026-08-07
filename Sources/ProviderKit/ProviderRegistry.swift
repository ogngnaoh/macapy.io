import Foundation

/// The user's provider configuration, as persisted in `settings` rows. Holds
/// **no key material** — keys live only in the Keychain, looked up by profile
/// id (SPEC §8).
public struct ProviderSettings: Sendable, Equatable, Codable {
    /// `nil` means "no AI provider configured": the app is a pure local
    /// transcriber and AI surfaces show the quiet setup prompt (PRD Story 1).
    public var selectedProfileID: String?
    /// Per-profile model overrides, so a provider renaming its models doesn't
    /// need an app update.
    public var fastModelOverrides: [String: String]
    public var deepModelOverrides: [String: String]
    /// Per-meeting spending cap in USD (PRD FR-015); `nil` means uncapped.
    public var perMeetingCapUSD: Double?

    public init(
        selectedProfileID: String? = nil,
        fastModelOverrides: [String: String] = [:],
        deepModelOverrides: [String: String] = [:],
        perMeetingCapUSD: Double? = nil
    ) {
        self.selectedProfileID = selectedProfileID
        self.fastModelOverrides = fastModelOverrides
        self.deepModelOverrides = deepModelOverrides
        self.perMeetingCapUSD = perMeetingCapUSD
    }
}

/// Turns settings + stored credentials into a usable client — or into `nil`.
///
/// This is the **only** place an `LLMProvider` is constructed, which is what
/// makes the zero-network guarantee checkable: unconfigured (or configured but
/// keyless) resolves to `nil`, so there is no object for a caller to send a
/// request through, and the quiet setup prompt is the natural consequence
/// rather than a special case someone has to remember to write.
public struct ProviderRegistry: Sendable {
    public let profiles: [EndpointProfile]
    let credentials: any CredentialStore
    let session: URLSession

    public init(
        profiles: [EndpointProfile] = EndpointProfile.builtIns,
        credentials: any CredentialStore,
        session: URLSession = .shared
    ) {
        self.profiles = profiles
        self.credentials = credentials
        self.session = session
    }

    public func profile(id: String) -> EndpointProfile? {
        profiles.first { $0.id == id }
    }

    /// The selected profile with the user's model overrides applied — what a
    /// caller consults to pick a tier's model id for a request. `nil` when no
    /// (known) profile is selected.
    public func resolvedProfile(for settings: ProviderSettings) -> EndpointProfile? {
        guard let id = settings.selectedProfileID, var profile = profile(id: id) else { return nil }
        if let fast = settings.fastModelOverrides[id], !fast.isEmpty { profile.fastModel = fast }
        if let deep = settings.deepModelOverrides[id], !deep.isEmpty { profile.deepModel = deep }
        return profile
    }

    /// The configured client, or `nil` when the app must stay silent: no
    /// profile selected, an unknown profile id, or a key-requiring profile with
    /// no key stored. Never performs I/O of its own.
    public func client(for settings: ProviderSettings) throws -> OpenAICompatibleClient? {
        guard let id = settings.selectedProfileID,
              let profile = resolvedProfile(for: settings)
        else { return nil }

        let key = try credentials.key(for: id)
        if profile.quirks.requiresAPIKey, key == nil || key?.isEmpty == true { return nil }

        return OpenAICompatibleClient(profile: profile, apiKey: key, session: session)
    }

    /// Whether AI features can run at all — what the UI asks before deciding
    /// between a live surface and the quiet setup prompt.
    public func isConfigured(_ settings: ProviderSettings) -> Bool {
        ((try? client(for: settings)) ?? nil) != nil
    }
}
