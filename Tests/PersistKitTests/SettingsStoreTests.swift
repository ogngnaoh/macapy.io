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

    @Test func liveAISettingsDefaultToEnabledQuietAndNoPreferredName() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())

        let settings = try await store.liveAISettings()

        #expect(settings.aiFeaturesEnabled)
        #expect(settings.sensitivity == .quiet)
        #expect(settings.preferredName == nil)
    }

    @Test func liveAISettingsRoundTrip() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())
        let settings = LiveAISettings(
            aiFeaturesEnabled: false,
            sensitivity: .active,
            preferredName: "Hoang"
        )

        try await store.setLiveAISettings(settings)

        #expect(try await store.liveAISettings() == settings)
    }

    @Test func liveAISensitivityThresholdsAreTheProductContract() {
        #expect(LiveAISensitivity.off.confidenceThreshold == 1.0)
        #expect(LiveAISensitivity.quiet.confidenceThreshold == 0.90)
        #expect(LiveAISensitivity.balanced.confidenceThreshold == 0.80)
        #expect(LiveAISensitivity.active.confidenceThreshold == 0.70)
    }

    @Test func partialLegacyLiveAISettingsDecodeEachFieldIndependently() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())
        try await store.set(#"{"preferredName":"Hoang"}"#, forKey: SettingsStore.liveAISettingsKey)

        let settings = try await store.liveAISettings()

        #expect(settings.aiFeaturesEnabled)
        #expect(settings.sensitivity == .quiet)
        #expect(settings.preferredName == "Hoang")
    }

    @Test func malformedLiveAIFieldsUseDefaultsWithoutDiscardingValidFields() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())
        try await store.set(
            #"{"aiFeaturesEnabled":"yes","sensitivity":"future-mode","preferredName":"Hoang"}"#,
            forKey: SettingsStore.liveAISettingsKey
        )

        let settings = try await store.liveAISettings()

        #expect(settings.aiFeaturesEnabled)
        #expect(settings.sensitivity == .quiet)
        #expect(settings.preferredName == "Hoang")
    }

    @Test func unreadableLiveAISettingsDoNotChangeProviderSettings() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())
        let provider = ProviderSettings(
            selectedProfileID: "deepseek",
            fastModelOverrides: ["deepseek": "custom-fast"],
            deepModelOverrides: ["deepseek": "custom-deep"],
            perMeetingCapUSD: 0.25
        )
        try await store.setProviderSettings(provider)
        try await store.set("{not json", forKey: SettingsStore.liveAISettingsKey)

        #expect(try await store.liveAISettings() == LiveAISettings())
        #expect(try await store.providerSettings() == provider)
    }
}
