import Foundation
import Testing
@testable import AppShell

@MainActor
struct ResetPreferencesTests {
    @Test(arguments: ["", "reset", "Reset", "RESE", "RESET ", " RESET", "RESET\n"])
    func nearMissesNeverInvokeReset(entry: String) async {
        var calls = 0
        let model = ResetPreferencesModel(performReset: { calls += 1; return .completed })
        #expect(calls == 0)
        model.entry = entry
        #expect(!model.canReset)
        await model.confirm()
        #expect(calls == 0)
        #expect(model.outcome == nil)
    }

    @Test func exactConfirmationIsSingleFlightAndSuccessIsTerminal() async throws {
        var calls = 0
        var completion: CheckedContinuation<ResetPreferencesOutcome, Never>?
        let model = ResetPreferencesModel(performReset: {
            calls += 1
            return await withCheckedContinuation { completion = $0 }
        })
        model.entry = "RESET"
        let attempt = Task { await model.confirm() }
        for _ in 0..<200 {
            if completion != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let pending = try #require(completion)
        #expect(model.isResetting)
        #expect(model.entry.isEmpty)
        model.entry = "RESET"
        await model.confirm()
        #expect(calls == 1)
        pending.resume(returning: .completed)
        await attempt.value
        #expect(model.didComplete && !model.isResetting)
        #expect(model.entry.isEmpty)
        model.entry = "RESET"
        await model.confirm()
        #expect(calls == 1 && !model.canReset)
    }

    @Test(arguments: [ResetPreferencesOutcome.busy, .requiresContentDeletion, .failed])
    func refusalOrFailureRequiresFreshConfirmation(outcome: ResetPreferencesOutcome) async {
        var calls = 0
        let model = ResetPreferencesModel(performReset: {
            calls += 1
            return calls == 1 ? outcome : .completed
        })
        model.entry = "RESET"
        await model.confirm()
        #expect(model.outcome == outcome)
        #expect(!model.didComplete && !model.isResetting)
        #expect(model.entry.isEmpty && !model.canReset)
        #expect(model.message != nil)
        await model.confirm()
        #expect(calls == 1)
        model.entry = "RESET"
        await model.confirm()
        #expect(calls == 2 && model.didComplete)
    }

    @Test func partialFailureAndAccountingCopyAreExplicit() async {
        let model = ResetPreferencesModel(performReset: { .failed })
        model.entry = "RESET"
        await model.confirm()
        #expect(model.message?.contains("Some settings may already be reset") == true)
        #expect(ResetPreferencesModel.accountingDisclosure.contains("does not refund"))
        #expect(ResetPreferencesModel.accountingDisclosure.contains("may already have incurred charges"))
    }
}

@MainActor
struct RetainedSettingsResetTests {
    private final class Environment: SetupEnvironment {
        var inspections = 0
        var permissionRequests = 0
        var installs = 0
        func microphoneStatus() -> MicrophonePermission { inspections += 1; return .allowed }
        func requestMicrophone() async -> Bool { permissionRequests += 1; return true }
        func speechInstalled() async -> Bool { inspections += 1; return true }
        func installSpeech() async throws { installs += 1 }
    }

    private final class Registration: ShortcutRegistration {}
    @MainActor private final class Shortcuts {
        var registrations = 0
        var rejected: ShortcutBinding?
        func register(_ binding: ShortcutBinding, _ id: UInt32,
                      _ handler: @escaping GlobalShortcutManager.Handler) throws -> any ShortcutRegistration {
            if binding == rejected { throw ShortcutFailure.unavailable }
            registrations += 1
            return Registration()
        }
    }

    private func defaults() throws -> (UserDefaults, String) {
        let name = "io.macapy.tests.reset.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func onboardingResetClearsOnlyInjectedPreferencesAndPreservesReadiness() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CapturePreferences.setupKey)
        defaults.set(CaptureMode.microphoneOnly.rawValue, forKey: CapturePreferences.modeKey)
        defaults.set("retained", forKey: "unrelated.preference")
        let environment = Environment()
        let model = OnboardingModel(environment: environment, defaults: defaults)
        await model.refresh()
        let inspections = environment.inspections
        #expect(model.isComplete)
        #expect(model.resetPreferences())
        #expect(!model.isComplete && model.captureMode == .microphoneAndSystem)
        #expect(model.microphone == .allowed && model.speechReady)
        #expect(model.installationMessage == nil)
        #expect(defaults.object(forKey: CapturePreferences.setupKey) == nil)
        #expect(defaults.object(forKey: CapturePreferences.modeKey) == nil)
        #expect(defaults.string(forKey: "unrelated.preference") == "retained")
        #expect(environment.inspections == inspections)
        #expect(environment.permissionRequests == 0 && environment.installs == 0)
        #expect(model.resetPreferences())
    }

    @Test func onboardingResetRefusesOwnedMeetingOrDownloadAndClearsStaleMessageWhenIdle() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CapturePreferences.setupKey)
        let environment = Environment()
        let activity = SetupActivityGate()
        let model = OnboardingModel(environment: environment, defaults: defaults, activity: activity)
        #expect(activity.beginMeeting())
        await model.installSpeech()
        #expect(model.installationMessage != nil)
        #expect(!model.resetPreferences())
        #expect(model.isComplete && defaults.bool(forKey: CapturePreferences.setupKey))
        activity.endMeeting()
        let lease = try #require(activity.beginDownload())
        #expect(!model.resetPreferences())
        #expect(model.isComplete)
        activity.endDownload(lease)
        #expect(model.resetPreferences())
        #expect(model.installationMessage == nil)
        #expect(environment.installs == 0 && environment.permissionRequests == 0)
    }

    @Test func inactiveShortcutResetDoesNotRegisterAnything() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var customized = ShortcutConfiguration.defaults
        customized.bindings[.startStop] = ShortcutBinding(letter: "X", modifiers: .controlCommand)
        defaults.set(try JSONEncoder().encode(customized), forKey: ShortcutPreferencesModel.storageKey)
        let platform = Shortcuts()
        let manager = GlobalShortcutManager(register: { binding, id, handler in
            try platform.register(binding, id, handler)
        })
        let model = ShortcutPreferencesModel(manager: manager, defaults: defaults)
        #expect(model.configuration == customized)
        try model.resetRetainedPreferences()
        #expect(model.configuration == .defaults)
        #expect(manager.activeConfiguration == nil && platform.registrations == 0)
        #expect(defaults.object(forKey: ShortcutPreferencesModel.storageKey) == nil)
    }

    @Test func activeShortcutConflictPreservesSettingsUntilExplicitSuccessfulRetry() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let platform = Shortcuts()
        let manager = GlobalShortcutManager(register: { binding, id, handler in
            try platform.register(binding, id, handler)
        })
        let model = ShortcutPreferencesModel(manager: manager, defaults: defaults)
        let custom = ShortcutBinding(letter: "X", modifiers: .controlCommand)
        model.set(.startStop, binding: custom)
        let saved = try #require(defaults.data(forKey: ShortcutPreferencesModel.storageKey))
        platform.rejected = ShortcutConfiguration.defaults.bindings[.startStop]
        #expect(throws: ShortcutFailure.self) { try model.resetRetainedPreferences() }
        #expect(model.binding(for: .startStop) == custom)
        #expect(manager.activeConfiguration == model.configuration)
        #expect(defaults.data(forKey: ShortcutPreferencesModel.storageKey) == saved)
        platform.rejected = nil
        try model.resetRetainedPreferences()
        #expect(model.configuration == .defaults && manager.activeConfiguration == .defaults)
        #expect(defaults.object(forKey: ShortcutPreferencesModel.storageKey) == nil)
    }
}
