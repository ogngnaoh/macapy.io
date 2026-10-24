import AgentKit
import Foundation
import Testing
@testable import AppShell

@MainActor private final class FakeLoginItem: LoginItemManaging {
    var status: LoginItemStatus = .disabled
    var registrations = 0
    var unregistrations = 0
    var opens = 0
    var registrationStatus: LoginItemStatus = .enabled
    var failRegistration = false
    var holdRemoval = false
    var removal: CheckedContinuation<Void, Never>?
    func register() throws {
        registrations += 1
        if failRegistration { throw NSError(domain: "private-content-never-display", code: 1) }
        status = registrationStatus
    }
    func unregister() async throws {
        unregistrations += 1
        if holdRemoval { await withCheckedContinuation { removal = $0 } }
        status = .disabled
    }
    func openSystemSettings() { opens += 1 }
}

@MainActor private final class FakeShortcutRegistration: ShortcutRegistration {}
@MainActor private final class WeakShortcut {
    weak var value: (any ShortcutRegistration)?
    init(_ value: any ShortcutRegistration) { self.value = value }
}
@MainActor private final class FakeShortcutPlatform {
    var registrations: [ShortcutBinding] = []
    var unavailable: Set<ShortcutBinding> = []
    var live: [ShortcutBinding: WeakShortcut] = [:]
    var callbacks: [ShortcutBinding: GlobalShortcutManager.Handler] = [:]
    func register(_ binding: ShortcutBinding, _ id: UInt32,
                  _ callback: @escaping GlobalShortcutManager.Handler) throws -> any ShortcutRegistration {
        if unavailable.contains(binding) { throw ShortcutFailure.unavailable }
        let lease = FakeShortcutRegistration()
        registrations.append(binding)
        live[binding] = WeakShortcut(lease)
        callbacks[binding] = callback
        return lease
    }
}

@MainActor struct LaunchPreferencesTests {
    @Test func openingPreferencesOnlyReadsSystemStatus() {
        let platform = FakeLoginItem()
        let model = LaunchPreferencesModel(platform: platform)
        model.refresh()
        #expect(model.status == .disabled)
        #expect(platform.registrations == 0 && platform.unregistrations == 0 && platform.opens == 0)
        platform.status = .requiresApproval
        model.refresh()
        #expect(model.status == .requiresApproval)
        #expect(platform.registrations == 0)
    }

    @Test func explicitRegistrationReflectsApprovalAndSanitizesFailure() async {
        let platform = FakeLoginItem()
        platform.registrationStatus = .requiresApproval
        let model = LaunchPreferencesModel(platform: platform)
        await model.setEnabled(true)
        #expect(model.status == .requiresApproval)
        #expect(platform.registrations == 1)
        model.openSystemSettings()
        #expect(platform.opens == 1)
        await model.setEnabled(false)
        platform.failRegistration = true
        await model.setEnabled(true)
        #expect(!model.isEnabled && !model.isChanging)
        #expect(model.message?.contains("private-content") == false)
        #expect(model.message?.contains("System Settings") == true)
    }

    @Test func inFlightUnregisterCannotRaceAnotherToggle() async {
        let platform = FakeLoginItem()
        platform.status = .enabled
        platform.holdRemoval = true
        let model = LaunchPreferencesModel(platform: platform)
        let removal = Task { await model.setEnabled(false) }
        while platform.removal == nil { await Task.yield() }
        await model.setEnabled(true)
        #expect(platform.registrations == 0)
        #expect(model.isChanging)
        platform.removal?.resume()
        await removal.value
        #expect(model.status == .disabled && !model.isChanging)
    }

    @Test func failedShortcutReplacementPreservesOldLeaseAndReleasesNewOnes() throws {
        let platform = FakeShortcutPlatform()
        let manager = GlobalShortcutManager(register: platform.register)
        try manager.apply(.defaults)
        var replacement = ShortcutConfiguration.defaults
        let firstNew = ShortcutBinding(letter: "A", modifiers: .controlCommand)
        let rejected = ShortcutBinding(letter: "B", modifiers: .controlCommand)
        replacement.bindings[.startStop] = firstNew
        replacement.bindings[.pauseResume] = rejected
        platform.unavailable.insert(rejected)
        #expect(throws: ShortcutFailure.self) { try manager.apply(replacement) }
        #expect(manager.activeConfiguration == .defaults)
        #expect(platform.live[firstNew]?.value == nil)
        for binding in ShortcutConfiguration.defaults.bindings.values {
            #expect(platform.live[binding]?.value != nil)
        }
    }

    @Test func swappingExistingCombinationsReusesLeasesAndChangesDispatchAtomically() throws {
        let platform = FakeShortcutPlatform()
        var dispatched: [ShortcutAction] = []
        let manager = GlobalShortcutManager(handlers: [
            .startStop: { dispatched.append(.startStop) },
            .pauseResume: { dispatched.append(.pauseResume) },
        ], register: platform.register)
        try manager.apply(.defaults)
        let originalStart = try #require(ShortcutConfiguration.defaults.bindings[.startStop])
        let originalPause = try #require(ShortcutConfiguration.defaults.bindings[.pauseResume])
        var swapped = ShortcutConfiguration.defaults
        swapped.bindings[.startStop] = originalPause
        swapped.bindings[.pauseResume] = originalStart
        try manager.apply(swapped)
        #expect(platform.registrations.count == 5)
        platform.callbacks[originalStart]?()
        #expect(dispatched == [.pauseResume])
        try manager.apply(.defaults)
        platform.callbacks[originalStart]?()
        #expect(dispatched == [.pauseResume, .startStop])
        #expect(platform.registrations.count == 5)
    }

    @Test func invalidAndDuplicateSettingsNeverReachPlatform() {
        let platform = FakeShortcutPlatform()
        let manager = GlobalShortcutManager(register: platform.register)
        let model = ShortcutPreferencesModel(manager: manager, defaults: nil)
        #expect(platform.registrations.isEmpty)
        model.set(.startStop, binding: model.binding(for: .ask))
        #expect(model.configuration == .defaults)
        #expect(platform.registrations.isEmpty)
        #expect(model.message?.contains("already assigned") == true)
        model.set(.startStop, binding: ShortcutBinding(letter: "Return"))
        #expect(platform.registrations.isEmpty)
        model.activate()
        #expect(platform.registrations.count == 5)
        let conflict = ShortcutBinding(letter: "Q", modifiers: .controlCommand)
        platform.unavailable.insert(conflict)
        model.set(.startStop, binding: conflict)
        #expect(model.configuration == .defaults)
        #expect(model.message?.contains("unavailable") == true)
    }

    private func snapshot() -> AppShellCoordinator.DiagnosticsSnapshot {
        AppShellCoordinator.DiagnosticsSnapshot(
            hasMeeting: true, speech: nil, suggestion: SuggestionLatencyRecorder().report(),
            memoryBytes: 42, artifactG3Seconds: 9.5, droppedChunks: 3, sttErrorCount: 2
        )
    }

    @Test func diagnosticSchemaContainsOnlyAllowedCountersAndVersionStrings() throws {
        let report = SanitizedDiagnosticsReport(
            snapshot: snapshot(), appVersion: "1.2.3", appBuild: "private-content",
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        )
        let data = try report.data()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "appVersion", "appBuild", "macOSVersion", "counters"])
        #expect(object["appBuild"] as? String == "unknown")
        #expect(report.counters["droppedAudioChunks"] == 3)
        #expect(report.counters["speechErrorEvents"] == 2)
        #expect(!String(decoding: data, as: UTF8.self).contains("private-content"))
        #expect(report.counters.values.allSatisfy { $0 >= 0 })
    }

    @Test func diagnosticPreviewDoesNotWriteAndSaveRequiresLocalDestination() async {
        var writes = 0
        let model = SanitizedDiagnosticsExportModel(snapshot: { self.snapshot() }, write: { _, _ in writes += 1 })
        await model.prepare()
        #expect(model.report != nil && writes == 0)
        model.save(to: URL(string: "https://example.invalid/diagnostics")!)
        #expect(writes == 0)
        model.save(to: URL(fileURLWithPath: "/tmp/fictional-diagnostics.json"))
        #expect(writes == 1)
        model.clear()
        #expect(model.report == nil)
    }

    @Test func closingDiagnosticPreviewFencesPendingSnapshot() async {
        var pending: CheckedContinuation<AppShellCoordinator.DiagnosticsSnapshot, Never>?
        let model = SanitizedDiagnosticsExportModel(snapshot: {
            await withCheckedContinuation { pending = $0 }
        })
        let preparation = Task { await model.prepare() }
        while pending == nil { await Task.yield() }
        model.clear()
        pending?.resume(returning: snapshot())
        await preparation.value
        #expect(model.report == nil && !model.isPreparing)
    }
}
