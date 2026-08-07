import CaptureKit
import Foundation
import Observation

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
        case capturing(startedAt: Date)
        case paused(startedAt: Date)
    }

    private(set) var state: SessionState = .idle

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
        case .idle: return nil
        case .capturing(let startedAt), .paused(let startedAt): return startedAt
        }
    }

    /// Starts a session. Returns false (and changes nothing) if one is already running.
    @discardableResult
    func start(now: Date = Date()) -> Bool {
        guard case .idle = state else { return false }
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
