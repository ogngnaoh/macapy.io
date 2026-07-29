import Foundation
import GRDB
import ProviderKit

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
}
