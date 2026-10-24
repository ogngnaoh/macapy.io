import AVFoundation
import Foundation
import Observation
import TranscribeKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case microphoneAndSystem, microphoneOnly
    var id: String { rawValue }
    var label: String { self == .microphoneOnly ? "Microphone only" : "Microphone + system audio" }
}

enum CapturePreferences {
    static let modeKey = "capture.mode"
    static let setupKey = "setup.completed.v1"
    static let locale = Locale(identifier: "en-US")
    static var mode: CaptureMode {
        CaptureMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .microphoneAndSystem
    }
}

enum MicrophonePermission: Equatable { case unknown, allowed, denied }

/// One app-lifetime boundary for setup downloads and recording. A cancelled
/// installer retains its lease until the installer actually returns.
@MainActor @Observable
final class SetupActivityGate {
    private(set) var sessionActive = false
    private var downloadID: UUID?
    var isBusy: Bool { downloadID != nil }

    func beginDownload() -> UUID? {
        guard !sessionActive, downloadID == nil else { return nil }
        let id = UUID()
        downloadID = id
        return id
    }

    func endDownload(_ id: UUID) {
        if downloadID == id { downloadID = nil }
    }

    func beginMeeting() -> Bool {
        guard downloadID == nil else { return false }
        sessionActive = true
        return true
    }

    func endMeeting() { sessionActive = false }
}

@MainActor
protocol SetupEnvironment {
    func microphoneStatus() -> MicrophonePermission
    func requestMicrophone() async -> Bool
    func speechInstalled() async -> Bool
    func installSpeech() async throws
}

@MainActor
struct NativeSetupEnvironment: SetupEnvironment {
    func microphoneStatus() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .denied, .restricted: .denied
        case .notDetermined: .unknown
        @unknown default: .unknown
        }
    }
    func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
    func speechInstalled() async -> Bool {
        await SpeechAnalyzerEngine.assetsAreInstalled(locale: CapturePreferences.locale)
    }
    func installSpeech() async throws {
        try await SpeechAnalyzerEngine(locale: CapturePreferences.locale)
            .prepare(locale: CapturePreferences.locale)
    }
}

/// Setup performs no permission request or asset download until a user action.
@MainActor @Observable
final class OnboardingModel {
    let activity: SetupActivityGate
    private(set) var microphone: MicrophonePermission = .unknown
    private(set) var speechReady = false
    private(set) var isInstalling = false
    private(set) var installationMessage: String?
    private(set) var isComplete: Bool
    var captureMode: CaptureMode {
        didSet { defaults?.set(captureMode.rawValue, forKey: CapturePreferences.modeKey) }
    }
    @ObservationIgnored private let environment: any SetupEnvironment
    @ObservationIgnored private let defaults: UserDefaults?

    init(
        environment: any SetupEnvironment = NativeSetupEnvironment(),
        defaults: UserDefaults? = .standard,
        activity: SetupActivityGate = SetupActivityGate()
    ) {
        self.environment = environment
        self.defaults = defaults
        self.activity = activity
        self.isComplete = defaults?.bool(forKey: CapturePreferences.setupKey) ?? false
        self.captureMode = CaptureMode(rawValue: defaults?.string(forKey: CapturePreferences.modeKey) ?? "")
            ?? .microphoneAndSystem
    }

    var canFinish: Bool { speechReady && microphone == .allowed && !isInstalling }

    func refresh() async {
        microphone = environment.microphoneStatus()
        speechReady = await environment.speechInstalled()
    }

    func requestMicrophone() async {
        microphone = await environment.requestMicrophone() ? .allowed : .denied
    }

    func installSpeech() async {
        guard !isInstalling else { return }
        guard let lease = activity.beginDownload() else {
            installationMessage = "Finish the meeting or current download before installing speech support."
            return
        }
        isInstalling = true
        installationMessage = nil
        defer {
            isInstalling = false
            activity.endDownload(lease)
        }
        do {
            try await environment.installSpeech()
            try Task.checkCancellation()
            speechReady = await environment.speechInstalled()
            if !speechReady { installationMessage = "Speech support is not ready yet. Try again when you are online." }
        } catch is CancellationError {
            installationMessage = "Setup was cancelled. You can continue it later."
        } catch {
            installationMessage = "Speech setup could not finish. Check your connection and try again."
        }
    }

    @discardableResult
    func finish() -> Bool {
        guard canFinish else { return false }
        isComplete = true
        defaults?.set(true, forKey: CapturePreferences.setupKey)
        return true
    }

    /// Reset only this model's injected preference namespace. Permissions and
    /// shared installed assets remain actual platform state, not preferences.
    @discardableResult
    func resetPreferences() -> Bool {
        guard !activity.sessionActive, !activity.isBusy, !isInstalling else { return false }
        isComplete = false
        captureMode = .microphoneAndSystem
        defaults?.removeObject(forKey: CapturePreferences.modeKey)
        defaults?.removeObject(forKey: CapturePreferences.setupKey)
        installationMessage = nil
        return true
    }
}
