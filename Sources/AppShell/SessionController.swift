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

    var isCapturing: Bool {
        if case .capturing = state { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
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
