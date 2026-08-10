import Foundation
import Observation
import PersistKit
import os

private actor SettingsPersistenceGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
@Observable
final class LiveAISettingsModel {
    private(set) var settings = LiveAISettings()
    private(set) var loaded = false

    @ObservationIgnored private let store: SettingsStore?
    @ObservationIgnored private let saveSettings: @Sendable (LiveAISettings) async throws -> Void
    @ObservationIgnored private let onChange: @MainActor (LiveAISettings) async -> Void
    @ObservationIgnored private var persistenceTail: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.macapy.app", category: "LiveAISettings")

    init(
        store: SettingsStore?,
        onChange: @escaping @MainActor (LiveAISettings) async -> Void = { _ in }
    ) {
        self.store = store
        self.saveSettings = { settings in
            try await store?.setLiveAISettings(settings)
        }
        self.onChange = onChange
    }

    /// Focused lifecycle-test seam: production always uses `SettingsStore`,
    /// while tests can suspend a write to prove notification and ordering.
    init(
        testingSaveSettings saveSettings: @escaping @Sendable (LiveAISettings) async throws -> Void,
        onChange: @escaping @MainActor (LiveAISettings) async -> Void = { _ in }
    ) {
        store = nil
        self.saveSettings = saveSettings
        self.onChange = onChange
    }

    func load() async {
        guard !loaded else { return }
        settings = (try? await store?.liveAISettings()) ?? LiveAISettings()
        if settings.preferredName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            settings.preferredName = Self.defaultPreferredName
        }
        loaded = true
        // Loading establishes the app's in-memory operational latch too. The
        // database value is durable input, not a separate source of truth once
        // the model is alive.
        await onChange(settings)
    }

    func setEnabled(_ enabled: Bool) async {
        settings.aiFeaturesEnabled = enabled
        await persist()
    }

    func setSensitivity(_ sensitivity: LiveAISensitivity) async {
        settings.sensitivity = sensitivity
        await persist()
    }

    func setPreferredName(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.preferredName = trimmed.isEmpty ? nil : trimmed
        await persist()
    }

    private func persist() async {
        // A value snapshot matters here: another setter may run while either
        // callback or storage is suspended. The live consumer sees AI-off
        // before any database delay, while queued writes retain mutation order.
        let snapshot = settings
        let deliveryGate = SettingsPersistenceGate()
        let persistencePredecessor = persistenceTail
        let saveSettings = self.saveSettings
        let task = Task { [log] in
            await persistencePredecessor?.value
            await deliveryGate.wait()
            do {
                try await saveSettings(snapshot)
            } catch {
                log.error("failed to persist live AI settings: \(error.localizedDescription)")
            }
        }
        persistenceTail = task

        // Invoke the callback directly on MainActor. Registering the ordered
        // persistence task first means a reentrant setter cannot overtake this
        // snapshot's write while this callback is suspended.
        await onChange(snapshot)
        await deliveryGate.release()
        await task.value
    }

    static var defaultPreferredName: String? {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullName.isEmpty else { return nil }
        return fullName.split(separator: " ").first.map(String.init)
    }
}
