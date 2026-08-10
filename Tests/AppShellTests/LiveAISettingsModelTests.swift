import Foundation
import PersistKit
import Testing

@testable import AppShell

@MainActor
struct LiveAISettingsModelTests {
    @Test func defaultsLoadEnabledQuietAndPrefillANameWhenAvailable() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())
        let model = LiveAISettingsModel(store: store)

        await model.load()

        #expect(model.settings.aiFeaturesEnabled)
        #expect(model.settings.sensitivity == .quiet)
        if LiveAISettingsModel.defaultPreferredName != nil {
            #expect(model.settings.preferredName == LiveAISettingsModel.defaultPreferredName)
        }
    }

    @Test func changesPersistAndNotifyLiveConsumer() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())
        var observed: [LiveAISettings] = []
        let model = LiveAISettingsModel(store: store) { observed.append($0) }
        await model.load()

        await model.setEnabled(false)
        await model.setSensitivity(.active)
        await model.setPreferredName("  Mai  ")

        let persisted = try await store.liveAISettings()
        #expect(persisted == LiveAISettings(
            aiFeaturesEnabled: false,
            sensitivity: .active,
            preferredName: "Mai"
        ))
        #expect(observed.last == persisted)
    }
}
