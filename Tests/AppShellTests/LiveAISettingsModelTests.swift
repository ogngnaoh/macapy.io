import Foundation
import PersistKit
import Testing

@testable import AppShell

private actor BlockingSettingsSave {
    private var firstRelease: CheckedContinuation<Void, Never>?
    private(set) var snapshots: [LiveAISettings] = []
    private(set) var firstSaveIsBlocked = false

    func save(_ settings: LiveAISettings) async {
        snapshots.append(settings)
        if snapshots.count == 1 {
            await withCheckedContinuation { continuation in
                firstRelease = continuation
                firstSaveIsBlocked = true
            }
        }
    }

    func releaseFirst() {
        firstSaveIsBlocked = false
        firstRelease?.resume()
        firstRelease = nil
    }
}

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

    @Test func rapidOffOnDeliversSnapshotsImmediatelyAndPersistsInOrder() async throws {
        let saves = BlockingSettingsSave()
        var observed: [LiveAISettings] = []
        let model = LiveAISettingsModel(
            testingSaveSettings: { await saves.save($0) },
            onChange: { observed.append($0) }
        )

        let turnOff = Task { await model.setEnabled(false) }
        for _ in 0..<300 {
            if await saves.firstSaveIsBlocked { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await saves.firstSaveIsBlocked)
        #expect(observed.map(\.aiFeaturesEnabled) == [false])

        let turnOn = Task { await model.setEnabled(true) }
        for _ in 0..<300 where observed.count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed.map(\.aiFeaturesEnabled) == [false, true])
        #expect(await saves.snapshots.map(\.aiFeaturesEnabled) == [false])

        await saves.releaseFirst()
        await turnOff.value
        await turnOn.value

        #expect(await saves.snapshots.map(\.aiFeaturesEnabled) == [false, true])
        #expect((await saves.snapshots.last)?.aiFeaturesEnabled == true)
    }
}
