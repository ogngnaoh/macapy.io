import Foundation
import Observation

/// The meeting-session state machine. Pure state transitions — the seam
/// slices 2–4 hook capture/transcription/persistence into. `.paused` arrives
/// with the pause hotkey in slice 4.
@MainActor
@Observable
final class SessionController {
    enum SessionState: Equatable, Sendable {
        case idle
        case capturing(startedAt: Date)
    }

    private(set) var state: SessionState = .idle

    var isCapturing: Bool {
        if case .capturing = state { return true }
        return false
    }

    /// Starts a session. Returns false (and changes nothing) if one is already running.
    @discardableResult
    func start(now: Date = Date()) -> Bool {
        guard case .idle = state else { return false }
        state = .capturing(startedAt: now)
        return true
    }

    /// Stops the running session. Returns false if none is running.
    @discardableResult
    func stop() -> Bool {
        guard case .capturing = state else { return false }
        state = .idle
        return true
    }

    func toggle(now: Date = Date()) {
        if isCapturing {
            stop()
        } else {
            start(now: now)
        }
    }
}
