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
            preferredName: "Mai",
            usesSystemPreferredName: false
        ))
        #expect(observed.last == persisted)
    }

    @Test func explicitBlankAndContentDeletionDoNotRestoreAccountName() async throws {
        let database = try MacapyDatabase.inMemory(), store = SettingsStore(database: database)
        let model = LiveAISettingsModel(store: store)
        await model.load(); await model.setPreferredName("")
        let reopened = LiveAISettingsModel(store: store)
        await reopened.load()
        #expect(reopened.settings.preferredName == nil)
        #expect(!reopened.settings.usesSystemPreferredName)
        await model.setPreferredName("Synthetic Person")
        await model.setEnabled(false)
        await model.beginContentDeletion()
        await model.setPreferredName("Blocked late edit")
        try await MeetingStore(database: database).deleteAllUserData()
        await model.endContentDeletion()
        #expect(model.settings.preferredName == nil && !model.settings.usesSystemPreferredName)
        #expect(!model.settings.aiFeaturesEnabled)
        let afterDeletion = LiveAISettingsModel(store: store)
        await afterDeletion.load()
        #expect(afterDeletion.settings.preferredName == nil)
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

    @Test func aLoadStartedBeforeDeletionCannotRestoreOldIdentityAfterReload() async throws {
        let reads = BlockingSettingsLoad(value: .init(preferredName: "Synthetic old name", usesSystemPreferredName: false))
        await reads.blockNextRead()
        var observed: [LiveAISettings] = []
        let model = LiveAISettingsModel(testingSaveSettings: { await reads.save($0) },
            testingLoadSettings: { await reads.load() }, onChange: { observed.append($0) })
        let oldLoad = Task { await model.load() }
        await reads.waitForBlockedRead()
        await model.beginContentDeletion()
        await model.load()
        #expect(await reads.readCount == 1)
        await reads.clearIdentity()
        await model.endContentDeletion()
        #expect(model.settings.preferredName == nil && !model.settings.usesSystemPreferredName)
        await reads.releaseRead()
        await oldLoad.value
        #expect(model.loaded && model.settings.preferredName == nil)
        #expect(observed.count == 1 && observed.first?.preferredName == nil)
    }

    @Test func endingDeletionKeepsMutationsBlockedThroughReloadAndCallback() async throws {
        let reads = BlockingSettingsLoad(value: .init(usesSystemPreferredName: false))
        var model: LiveAISettingsModel!
        var attemptReentrantEdit = true
        model = LiveAISettingsModel(testingSaveSettings: { await reads.save($0) },
            testingLoadSettings: { await reads.load() }, onChange: { _ in
                if attemptReentrantEdit {
                    attemptReentrantEdit = false
                    await model.setPreferredName("Blocked callback")
                }
            })
        await model.beginContentDeletion()
        await reads.blockNextRead()
        let reload = Task { await model.endContentDeletion() }
        await reads.waitForBlockedRead()
        await model.setEnabled(false)
        await model.setPreferredName("Blocked editor")
        await model.load()
        #expect(await reads.writeCount == 0)
        #expect(await reads.readCount == 1)
        await reads.releaseRead()
        await reload.value
        #expect(await reads.writeCount == 0)
        #expect(model.settings.preferredName == nil)
        // Clearing the barrier admits later genuine user edits.
        await model.setPreferredName("New choice")
        #expect(await reads.writeCount > 0)
    }
}

private actor BlockingSettingsLoad {
    private var value: LiveAISettings
    private var shouldBlock = false
    private var release: CheckedContinuation<Void, Never>?
    private var arrival: [CheckedContinuation<Void, Never>] = []
    private(set) var readCount = 0
    private(set) var writeCount = 0
    init(value: LiveAISettings) { self.value = value }
    func blockNextRead() { shouldBlock = true }
    func load() async -> LiveAISettings {
        readCount += 1
        let snapshot = value
        if shouldBlock {
            shouldBlock = false
            await withCheckedContinuation { continuation in
                release = continuation
                arrival.forEach { $0.resume() }; arrival = []
            }
        }
        return snapshot
    }
    func waitForBlockedRead() async { if release == nil { await withCheckedContinuation { arrival.append($0) } } }
    func releaseRead() { release?.resume(); release = nil }
    func clearIdentity() { value.preferredName = nil; value.usesSystemPreferredName = false }
    func save(_ value: LiveAISettings) { writeCount += 1; self.value = value }
}
