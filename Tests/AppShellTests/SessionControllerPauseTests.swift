import Foundation
import Testing

@testable import AppShell

/// Check 6: `.paused` transition matrix. A NEW file — `SessionControllerTests.swift`
/// is never modified; none of its tests ever reach `.paused`, so the additive
/// `stop()`/`toggle()` guard changes (from `case .capturing`/`isCapturing` to
/// `state != .idle`) don't change their outcomes.
@MainActor
struct SessionControllerPauseTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func pauseOnlyWorksFromCapturing() {
        let session = SessionController()
        #expect(!session.pause(), "pause from idle must be a no-op")
        #expect(session.state == .idle)

        session.start(now: t0)
        #expect(session.pause())
        #expect(session.state == .paused(startedAt: t0))

        // Already paused: pausing again is a no-op (not "capturing").
        #expect(!session.pause())
        #expect(session.state == .paused(startedAt: t0))
    }

    @Test func resumeOnlyWorksFromPaused() {
        let session = SessionController()
        #expect(!session.resume(), "resume from idle must be a no-op")

        session.start(now: t0)
        #expect(!session.resume(), "resume while capturing (never paused) must be a no-op")
        #expect(session.state == .capturing(startedAt: t0))

        session.pause()
        #expect(session.resume())
        #expect(session.state == .capturing(startedAt: t0), "resume restores the original startedAt")
    }

    @Test func stopWorksFromPaused() {
        let session = SessionController()
        session.start(now: t0)
        session.pause()
        #expect(session.stop())
        #expect(session.state == .idle)
    }

    @Test func toggleFromPausedStops() {
        let session = SessionController()
        session.start(now: t0)
        session.pause()
        #expect(session.state == .paused(startedAt: t0))

        session.toggle()
        #expect(session.state == .idle, "toggle from paused must stop, not resume")
    }

    @Test func isCapturingIsFalseWhilePaused() {
        let session = SessionController()
        session.start(now: t0)
        session.pause()
        #expect(!session.isCapturing)
    }

    @Test func rapidPauseResumeNeverWedges() {
        let session = SessionController()
        session.start(now: t0)
        for _ in 0..<50 {
            session.pause()
            session.resume()
        }
        #expect(session.state == .capturing(startedAt: t0))
        #expect(session.stop())
        #expect(session.state == .idle)
    }
}
