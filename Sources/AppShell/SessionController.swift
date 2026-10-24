import CaptureKit
import Foundation
import Observation
import TranscribeKit

/// The meeting-session state machine. Pure state transitions — the seam
/// slices 2–4 hook capture/transcription/persistence into. `.paused` arrives
/// with the pause hotkey in slice 4, added additively: no slice 1-3 test ever
/// reaches it, so `SessionControllerTests.swift` passes unmodified (slice-04
/// doc decision 6).
@MainActor
@Observable
final class SessionController {
    enum SessionState: Equatable, Sendable {
        case idle
        case preparing
        case capturing(startedAt: Date)
        case paused(startedAt: Date)
    }

    private(set) var state: SessionState = .idle
    private(set) var failure: SessionFailure?
    var storageWarning: String?
    var diarizationWarning: String?

    var isPreparing: Bool { state == .preparing }
    var isActive: Bool { state != .idle }

    var statusTitle: String {
        switch state {
        case .idle: failure == nil ? "Ready" : "Needs attention"
        case .preparing: "Preparing"
        case .capturing: "Capturing"
        case .paused: "Paused"
        }
    }

    @discardableResult
    func prepare() -> Bool {
        guard !isActive else { return false }
        failure = nil
        storageWarning = nil
        diarizationWarning = nil
        state = .preparing
        return true
    }

    @discardableResult
    func captureDidStart(now: Date = Date()) -> Bool {
        guard isPreparing else { return false }
        state = .capturing(startedAt: now)
        return true
    }

    func fail(_ failure: SessionFailure) {
        state = .idle
        self.failure = failure
    }

    func dismissFailure() { failure = nil }

    /// The current meeting's per-source levels for the signal strip (slice-4
    /// decision 5). Set by the coordinator when a pipeline starts; nil until
    /// the first meeting, after which it always points at the latest meter —
    /// the strip only renders it in `.live` mode, so stale values are never
    /// shown. Stored here (not threaded through `PanelPresenting`) so the
    /// panel picks it up via the session it already observes.
    var signalMeter: SignalLevelMeter?

    var isCapturing: Bool {
        if case .capturing = state { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    /// When the current session began — survives pause/resume, nil while
    /// idle. The panel header's meeting timer reads this.
    var startedAt: Date? {
        switch state {
        case .idle, .preparing: return nil
        case .capturing(let startedAt), .paused(let startedAt): return startedAt
        }
    }

    /// Starts a session. Returns false (and changes nothing) if one is already running.
    @discardableResult
    func start(now: Date = Date()) -> Bool {
        guard case .idle = state else { return false }
        failure = nil
        storageWarning = nil
        diarizationWarning = nil
        state = .capturing(startedAt: now)
        return true
    }

    /// Stops a running or paused session. Returns false if already idle.
    @discardableResult
    func stop() -> Bool {
        guard state != .idle else { return false }
        state = .idle
        return true
    }

    /// Pauses a capturing session, preserving its original `startedAt`.
    /// Returns false (no-op) unless currently capturing.
    @discardableResult
    func pause() -> Bool {
        guard case .capturing(let startedAt) = state else { return false }
        state = .paused(startedAt: startedAt)
        return true
    }

    /// Resumes a paused session, restoring `.capturing` with the same
    /// original `startedAt`. Returns false (no-op) unless currently paused.
    @discardableResult
    func resume() -> Bool {
        guard case .paused(let startedAt) = state else { return false }
        state = .capturing(startedAt: startedAt)
        return true
    }

    /// Idle → capturing; capturing or paused → idle (stop, not resume — see
    /// slice-04 doc decision 6 and acceptance check 6).
    func toggle(now: Date = Date()) {
        if state != .idle {
            stop()
        } else {
            start(now: now)
        }
    }
}

/// Only allowlisted product copy crosses the pipeline/UI error boundary.
enum SessionFailure: String, Sendable, Equatable {
    case speechAssets, locale, microphone, systemAudio, storage, transcription, audioRoute, captureInterrupted, systemSleep, shutdownDelayed

    var message: String {
        switch self {
        case .speechAssets:
            "Speech assets are not ready. Open Setup to install English speech support, then try again."
        case .locale:
            "This speech language is unavailable. Open Setup and select a supported English locale."
        case .microphone:
            "The microphone could not start. Check microphone access in System Settings and reconnect your input device."
        case .systemAudio:
            "System audio could not start. Check audio recording access in System Settings, or choose microphone only in Setup."
        case .storage:
            "Meeting storage is unavailable. Check available disk space and permissions before trying again."
        case .transcription:
            "Transcription stopped unexpectedly. Saved text remains in History. Check your audio device and try again."
        case .audioRoute:
            "The audio route changed and recording stopped. Saved text remains in History. Check your microphone and output device, then start a new meeting."
        case .captureInterrupted:
            "Audio capture was interrupted and recording stopped. Saved text remains in History. Check audio access and your devices, then start a new meeting."
        case .systemSleep:
            "Recording stopped when this Mac went to sleep. Saved text remains in History. Start a new meeting when you are ready."
        case .shutdownDelayed:
            "Quitting was cancelled because the recording is still finishing. Keep macapy open to protect the remaining text, then try Quit again."
        }
    }

    static func classify(_ error: any Error) -> Self {
        if error is MeetingStoragePreflight.Failure { return .storage }
        if let error = error as? CaptureInterruption {
            return error.reason == .routeChanged ? .audioRoute : .captureInterrupted
        }
        if let error = error as? TranscribeError {
            switch error {
            case .localeUnsupported: return .locale
            case .assetsUnavailable: return .speechAssets
            case .analyzerFailed: return .transcription
            }
        }
        if let error = error as? CaptureError {
            switch error {
            case .processTapFailed: return .systemAudio
            case .engineStartFailed, .formatUnavailable, .conversionFailed: return .microphone
            }
        }
        let domain = (error as NSError).domain
        if domain == NSCocoaErrorDomain || domain == "GRDB.DatabaseError" { return .storage }
        return .transcription
    }
}
