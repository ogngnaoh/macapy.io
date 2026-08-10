import Foundation
import Observation
import PersistKit
import os

@MainActor
@Observable
final class LiveAISettingsModel {
    private(set) var settings = LiveAISettings()
    private(set) var loaded = false

    @ObservationIgnored private let store: SettingsStore?
    @ObservationIgnored private let onChange: @MainActor (LiveAISettings) -> Void
    @ObservationIgnored private let log = Logger(subsystem: "io.macapy.app", category: "LiveAISettings")

    init(
        store: SettingsStore?,
        onChange: @escaping @MainActor (LiveAISettings) -> Void = { _ in }
    ) {
        self.store = store
        self.onChange = onChange
    }

    func load() async {
        settings = (try? await store?.liveAISettings()) ?? LiveAISettings()
        if settings.preferredName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            settings.preferredName = Self.defaultPreferredName
        }
        loaded = true
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
        do {
            try await store?.setLiveAISettings(settings)
        } catch {
            log.error("failed to persist live AI settings: \(error.localizedDescription)")
        }
        onChange(settings)
    }

    static var defaultPreferredName: String? {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullName.isEmpty else { return nil }
        return fullName.split(separator: " ").first.map(String.init)
    }
}
