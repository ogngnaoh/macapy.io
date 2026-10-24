import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import ServiceManagement
import SwiftUI

enum LoginItemStatus: Equatable {
    case disabled, enabled, requiresApproval, unavailable
}

@MainActor protocol LoginItemManaging {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() async throws
    func openSystemSettings()
}

@MainActor struct MainAppLoginItem: LoginItemManaging {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .disabled
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// ServiceManagement is authoritative. Reading preferences never registers a
/// service, and a successful request still needs the OS's actual status.
@MainActor @Observable
final class LaunchPreferencesModel {
    private(set) var status: LoginItemStatus
    private(set) var isChanging = false
    private(set) var message: String?
    @ObservationIgnored private let platform: any LoginItemManaging

    init(platform: any LoginItemManaging = MainAppLoginItem()) {
        self.platform = platform
        status = platform.status
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = platform.status }

    func setEnabled(_ enabled: Bool) async {
        guard !isChanging else { return }
        refresh()
        guard enabled != isEnabled else { return }
        isChanging = true
        message = nil
        defer { isChanging = false; refresh() }
        do {
            if enabled { try platform.register() }
            else { try await platform.unregister() }
        } catch {
            message = "Couldn’t change launch at login. Check Login Items in System Settings and try again."
        }
    }

    func openSystemSettings() { platform.openSystemSettings() }
}

enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case startStop, pauseResume, catchUp, ask, dismiss
    var id: Self { self }
    var title: String {
        switch self {
        case .startStop: "Start / stop meeting"
        case .pauseResume: "Pause / resume capture"
        case .catchUp: "Catch up"
        case .ask: "Ask"
        case .dismiss: "Dismiss copilot"
        }
    }
    var defaultLetter: String {
        switch self {
        case .startStop: "M"
        case .pauseResume: "P"
        case .catchUp: "C"
        case .ask: "K"
        case .dismiss: "D"
        }
    }
}

enum ShortcutModifiers: String, Codable, CaseIterable, Identifiable {
    case optionCommand, controlCommand, shiftOptionCommand, controlOptionCommand
    var id: Self { self }
    var display: String {
        switch self {
        case .optionCommand: "⌥⌘"
        case .controlCommand: "⌃⌘"
        case .shiftOptionCommand: "⇧⌥⌘"
        case .controlOptionCommand: "⌃⌥⌘"
        }
    }
    var carbon: UInt32 {
        switch self {
        case .optionCommand: UInt32(optionKey | cmdKey)
        case .controlCommand: UInt32(controlKey | cmdKey)
        case .shiftOptionCommand: UInt32(shiftKey | optionKey | cmdKey)
        case .controlOptionCommand: UInt32(controlKey | optionKey | cmdKey)
        }
    }
    var eventModifiers: SwiftUI.EventModifiers {
        switch self {
        case .optionCommand: [.option, .command]
        case .controlCommand: [.control, .command]
        case .shiftOptionCommand: [.shift, .option, .command]
        case .controlOptionCommand: [.control, .option, .command]
        }
    }
}

struct ShortcutBinding: Codable, Hashable {
    var letter: String
    var modifiers: ShortcutModifiers = .optionCommand
    var display: String { modifiers.display + letter }
    var keyEquivalent: KeyEquivalent { KeyEquivalent(letter.lowercased().first ?? "m") }
    var eventModifiers: SwiftUI.EventModifiers { modifiers.eventModifiers }
    var keyCode: UInt32? { Self.keyCodes[letter] }
    static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
    private static let keyCodes: [String: UInt32] = [
        "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4,
        "I": 34, "J": 38, "K": 40, "L": 37, "M": 46, "N": 45, "O": 31,
        "P": 35, "Q": 12, "R": 15, "S": 1, "T": 17, "U": 32, "V": 9,
        "W": 13, "X": 7, "Y": 16, "Z": 6,
    ]
}

struct ShortcutConfiguration: Codable, Equatable {
    var bindings: [ShortcutAction: ShortcutBinding]
    static let defaults = ShortcutConfiguration(bindings: Dictionary(uniqueKeysWithValues:
        ShortcutAction.allCases.map { ($0, ShortcutBinding(letter: $0.defaultLetter)) }
    ))

    func validated() throws {
        guard Set(bindings.keys) == Set(ShortcutAction.allCases),
              bindings.values.allSatisfy({ $0.keyCode != nil }) else {
            throw ShortcutFailure.invalid
        }
        guard Set(bindings.values).count == bindings.count else { throw ShortcutFailure.duplicate }
    }
}

enum ShortcutFailure: Error { case invalid, duplicate, unavailable }
@MainActor protocol ShortcutRegistration: AnyObject {}
extension HotKey: ShortcutRegistration {}

/// Registrations belong to key combinations, while callbacks resolve their
/// current action at dispatch. Swaps/reset can reuse existing leases. A failed
/// replacement releases only newly acquired leases and leaves old keys active.
@MainActor
final class GlobalShortcutManager {
    typealias Handler = @MainActor () -> Void
    typealias Register = @MainActor (ShortcutBinding, UInt32, @escaping Handler) throws -> any ShortcutRegistration
    var handlers: [ShortcutAction: Handler]
    private(set) var activeConfiguration: ShortcutConfiguration?
    private var leases: [ShortcutBinding: any ShortcutRegistration] = [:]
    private let register: Register
    private static var nextID: UInt32 = 100

    init(handlers: [ShortcutAction: Handler] = [:], register: @escaping Register = GlobalShortcutManager.registerNative) {
        self.handlers = handlers
        self.register = register
    }

    func apply(_ candidate: ShortcutConfiguration) throws {
        try candidate.validated()
        var next = leases
        for action in ShortcutAction.allCases {
            guard let binding = candidate.bindings[action], next[binding] == nil else { continue }
            Self.nextID &+= 1
            next[binding] = try register(binding, Self.nextID) { [weak self] in
                guard let self, let action = self.activeConfiguration?.bindings.first(where: { $0.value == binding })?.key else { return }
                self.handlers[action]?()
            }
        }
        let retained = Set(candidate.bindings.values)
        activeConfiguration = candidate
        leases = next.filter { retained.contains($0.key) }
    }

    func removeAll() { activeConfiguration = nil; leases.removeAll() }

    private static func registerNative(_ binding: ShortcutBinding, _ id: UInt32, _ handler: @escaping Handler) throws -> any ShortcutRegistration {
        guard let code = binding.keyCode else { throw ShortcutFailure.invalid }
        let key = HotKey(keyCode: code, carbonModifiers: binding.modifiers.carbon, id: id, exclusive: true, handler: handler)
        guard key.isRegistered else { throw ShortcutFailure.unavailable }
        return key
    }
}

@MainActor @Observable
final class ShortcutPreferencesModel {
    private(set) var configuration: ShortcutConfiguration
    private(set) var message: String?
    @ObservationIgnored let manager: GlobalShortcutManager
    @ObservationIgnored private let defaults: UserDefaults?
    static let storageKey = "macapy.global-shortcuts.v1"

    init(manager: GlobalShortcutManager, defaults: UserDefaults? = .standard) {
        self.manager = manager
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data),
           (try? stored.validated()) != nil {
            configuration = stored
        } else {
            configuration = .defaults
        }
    }

    /// Called once by the coordinator after all action handlers are installed.
    /// Merely constructing/opening Settings does not register global shortcuts.
    func activate() { apply(configuration, persist: false) }
    func binding(for action: ShortcutAction) -> ShortcutBinding {
        configuration.bindings[action] ?? ShortcutBinding(letter: action.defaultLetter)
    }
    func set(_ action: ShortcutAction, binding: ShortcutBinding) {
        var next = configuration
        next.bindings[action] = binding
        apply(next, persist: true)
    }
    func reset() { apply(.defaults, persist: true) }

    /// Clearing retained preferences must not activate a test/sample or other
    /// inactive owner. Active registrations change transactionally, and a
    /// conflict leaves both the working configuration and stored value intact.
    func resetRetainedPreferences() throws {
        if manager.activeConfiguration != nil { try manager.apply(.defaults) }
        configuration = .defaults
        defaults?.removeObject(forKey: Self.storageKey)
        message = nil
    }

    private func apply(_ next: ShortcutConfiguration, persist: Bool) {
        do {
            try manager.apply(next)
            configuration = next
            if persist { defaults?.set(try JSONEncoder().encode(next), forKey: Self.storageKey) }
            message = nil
        } catch ShortcutFailure.duplicate {
            message = "That shortcut is already assigned in macapy. Choose a different combination."
        } catch ShortcutFailure.invalid {
            message = "Choose a letter and one of the supported modifier combinations."
        } catch {
            message = "That shortcut is unavailable on this Mac. Existing shortcuts are unchanged; meeting controls remain in the menu bar."
        }
    }
}

/// Only allowlisted numeric counters and version labels can enter this export.
/// It has no fields for meeting IDs, names, paths, endpoints, keys, or text.
struct SanitizedDiagnosticsReport: Codable, Equatable {
    let schemaVersion: Int
    let appVersion: String
    let appBuild: String
    let macOSVersion: String
    let counters: [String: Int]

    init(snapshot: AppShellCoordinator.DiagnosticsSnapshot, appVersion: String, appBuild: String,
         osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
        schemaVersion = 1
        self.appVersion = Self.versionLabel(appVersion)
        self.appBuild = Self.versionLabel(appBuild)
        macOSVersion = "\(max(0, osVersion.majorVersion)).\(max(0, osVersion.minorVersion)).\(max(0, osVersion.patchVersion))"
        counters = [
            "speechVolatileEvents": snapshot.speech?.volatile.count ?? 0,
            "speechFinalEvents": snapshot.speech?.final.count ?? 0,
            "speechExcludedNegativeEvents": (snapshot.speech?.volatile.excludedNegativeCount ?? 0) + (snapshot.speech?.final.excludedNegativeCount ?? 0),
            "suggestionCompletedEvents": snapshot.suggestion.count,
            "suggestionExcludedNegativeEvents": snapshot.suggestion.excludedNegativeCount,
            "suggestionCancelledEvents": snapshot.suggestion.cancelledCount,
            "suggestionPendingEvents": snapshot.suggestion.pendingCount,
            "droppedAudioChunks": max(0, snapshot.droppedChunks),
            "speechErrorEvents": max(0, snapshot.sttErrorCount),
        ]
    }

    private static func versionLabel(_ value: String) -> String {
        guard !value.isEmpty, value.count <= 32,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.").contains($0) }) else { return "unknown" }
        return value
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

@MainActor @Observable
final class SanitizedDiagnosticsExportModel {
    private(set) var report: Data?
    private(set) var isPreparing = false
    private(set) var message: String?
    @ObservationIgnored private let snapshot: @MainActor () async -> AppShellCoordinator.DiagnosticsSnapshot
    @ObservationIgnored private let write: (Data, URL) throws -> Void
    @ObservationIgnored private var generation = 0

    init(snapshot: @escaping @MainActor () async -> AppShellCoordinator.DiagnosticsSnapshot,
         write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.snapshot = snapshot
        self.write = write
    }

    func prepare() async {
        guard !isPreparing else { return }
        generation += 1
        let token = generation
        isPreparing = true
        message = nil
        let current = await snapshot()
        guard token == generation else { return }
        defer { isPreparing = false }
        do {
            report = try SanitizedDiagnosticsReport(
                snapshot: current,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            ).data()
        } catch {
            message = "Couldn’t prepare the diagnostic report. Try again."
        }
    }

    func save(to url: URL) {
        guard let report, url.isFileURL else { message = "Choose a local file destination."; return }
        do { try write(report, url); message = "Diagnostic report saved." }
        catch { message = "Couldn’t save the diagnostic report. Choose another location and try again." }
    }

    func clear() { generation += 1; isPreparing = false; report = nil; message = nil }
}
