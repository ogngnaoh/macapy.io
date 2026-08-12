import Foundation
import GRDB
import ProviderKit

/// User-selectable proactive copilot sensitivity. The confidence threshold is
/// part of the persisted product contract rather than a provider preference.
public enum LiveAISensitivity: String, Sendable, CaseIterable, Codable, Equatable {
    case off
    case quiet
    case balanced
    case active

    public var confidenceThreshold: Double {
        switch self {
        case .off: 1.0
        case .quiet: 0.90
        case .balanced: 0.80
        case .active: 0.70
        }
    }
}

/// Non-secret settings for M3 live intelligence. Decoding defaults each field
/// independently so an old, partial, or partly malformed blob cannot disable
/// transcription or disturb provider configuration.
public struct LiveAISettings: Sendable, Codable, Equatable {
    public var aiFeaturesEnabled: Bool
    public var sensitivity: LiveAISensitivity
    public var preferredName: String?

    public init(
        aiFeaturesEnabled: Bool = true,
        sensitivity: LiveAISensitivity = .quiet,
        preferredName: String? = nil
    ) {
        self.aiFeaturesEnabled = aiFeaturesEnabled
        self.sensitivity = sensitivity
        self.preferredName = preferredName
    }

    private enum CodingKeys: String, CodingKey {
        case aiFeaturesEnabled
        case sensitivity
        case preferredName
    }

    public init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        self.init(
            aiFeaturesEnabled: (try? container.decode(Bool.self, forKey: .aiFeaturesEnabled)) ?? true,
            sensitivity: (try? container.decode(LiveAISensitivity.self, forKey: .sensitivity)) ?? .quiet,
            preferredName: try? container.decode(String.self, forKey: .preferredName)
        )
    }
}

/// The `settings` key/value table (schema v1). Small, typed helpers on top for
/// the values slice 2 needs to survive relaunch.
///
/// **Never holds secrets.** API keys live in the Keychain and nowhere else
/// (SPEC §8); what lands here is which profile is selected, model-id overrides,
/// per-model prices, and the spending cap.
public actor SettingsStore {
    /// Row key for the encoded `ProviderSettings` blob.
    public static let providerSettingsKey = "provider.settings"
    /// Row key for the encoded `PricingTable`.
    public static let pricingKey = "provider.pricing"
    /// Row key for the encoded `LiveAISettings` blob. Kept separate from the
    /// provider row so neither setting family can erase the other.
    public static let liveAISettingsKey = "live-ai.settings"

    private let database: MacapyDatabase

    public init(database: MacapyDatabase) {
        self.database = database
    }

    public func value(forKey key: String) async throws -> String? {
        try await database.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    public func set(_ value: String?, forKey key: String) async throws {
        try await database.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO settings (key, value) VALUES (?, ?) "
                    + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value]
            )
        }
    }

    // MARK: - Typed values

    /// The user's provider configuration. A missing row means "no provider
    /// configured" — a fresh install is a pure local transcriber (PRD Story 1).
    ///
    /// A row this build can't decode also reads as unconfigured rather than
    /// throwing: a settings blob written by a newer version must never stop the
    /// app from transcribing.
    public func providerSettings() async throws -> ProviderSettings {
        guard let raw = try await value(forKey: Self.providerSettingsKey),
              let decoded = try? JSONDecoder().decode(ProviderSettings.self, from: Data(raw.utf8))
        else { return ProviderSettings() }
        return decoded
    }

    public func setProviderSettings(_ settings: ProviderSettings) async throws {
        let data = try JSONEncoder().encode(settings)
        try await set(String(decoding: data, as: UTF8.self), forKey: Self.providerSettingsKey)
    }

    /// User-maintained per-model prices. Empty means "no known rates", which
    /// renders as "—" rather than as free (slice-02 doc Notes 8).
    public func pricing() async throws -> PricingTable {
        guard let raw = try await value(forKey: Self.pricingKey),
              let decoded = try? JSONDecoder().decode(PricingTable.self, from: Data(raw.utf8))
        else { return PricingTable.defaults }
        return decoded
    }

    public func setPricing(_ pricing: PricingTable) async throws {
        let data = try JSONEncoder().encode(pricing)
        try await set(String(decoding: data, as: UTF8.self), forKey: Self.pricingKey)
    }

    /// Live-intelligence preferences. Missing or unreadable data returns safe
    /// defaults and never prevents local transcription from starting.
    public func liveAISettings() async throws -> LiveAISettings {
        guard let raw = try await value(forKey: Self.liveAISettingsKey),
              let decoded = try? JSONDecoder().decode(LiveAISettings.self, from: Data(raw.utf8))
        else { return LiveAISettings() }
        return decoded
    }

    public func setLiveAISettings(_ settings: LiveAISettings) async throws {
        let data = try JSONEncoder().encode(settings)
        try await set(String(decoding: data, as: UTF8.self), forKey: Self.liveAISettingsKey)
    }
}
