import Foundation
import ProviderKit
import Testing

@testable import PersistKit

/// The `settings` key/value table (schema v1) put to work: slice 2 needs the
/// selected provider profile, per-profile model overrides, and the per-meeting
/// cap to survive relaunch.
///
/// Nothing secret is ever stored here — keys live only in the Keychain
/// (SPEC §8), which `ProviderKitTests.KeyLeakTests` enforces by grepping the
/// database file.
struct SettingsStoreTests {

    @Test func valueRoundTripsForAKey() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())

        try await store.set("deepseek", forKey: "provider.selected")

        #expect(try await store.value(forKey: "provider.selected") == "deepseek")
    }

    @Test func missingKeyReadsAsNil() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())

        #expect(try await store.value(forKey: "never.set") == nil)
    }

    @Test func settingTheSameKeyTwiceReplacesTheValue() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())

        try await store.set("openai", forKey: "provider.selected")
        try await store.set("deepseek", forKey: "provider.selected")

        #expect(try await store.value(forKey: "provider.selected") == "deepseek")
    }

    @Test func providerSettingsRoundTripWholeIncludingOverridesAndCap() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())
        let settings = ProviderSettings(
            selectedProfileID: "deepseek",
            fastModelOverrides: ["deepseek": "deepseek-chat-lite"],
            deepModelOverrides: [:],
            perMeetingCapUSD: 0.25
        )

        try await store.setProviderSettings(settings)

        #expect(try await store.providerSettings() == settings)
    }

    @Test func providerSettingsDefaultToUnconfiguredOnAFreshDatabase() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())

        let settings = try await store.providerSettings()

        #expect(settings.selectedProfileID == nil, "a fresh install must be a pure local transcriber")
        #expect(settings.perMeetingCapUSD == nil)
    }

    @Test func unreadableProviderSettingsFallBackToUnconfiguredRatherThanThrowing() async throws {
        // A settings row written by a newer build (or corrupted) must not brick
        // launch — the app degrades to "no provider configured", which is a
        // fully working local transcriber.
        let database = try MacapyDatabase.inMemory()
        let store = SettingsStore(database: database)
        try await store.set("{not json", forKey: SettingsStore.providerSettingsKey)

        #expect(try await store.providerSettings() == ProviderSettings())
    }

    @Test func pricingOverridesRoundTrip() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())
        let table = PricingTable(rates: [
            "deepseek-reasoner": ModelPricing(
                inputPerMillionUSD: 0.55,
                cachedInputPerMillionUSD: 0.07,
                outputPerMillionUSD: 2.19
            )
        ])

        try await store.setPricing(table)

        #expect(try await store.pricing() == table)
    }
}
