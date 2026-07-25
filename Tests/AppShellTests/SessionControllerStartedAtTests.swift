import Foundation
import Testing

@testable import AppShell

/// The panel header's meeting timer (slice-01 reskin) reads the session's
/// start time through one derived accessor rather than pattern-matching the
/// state enum in view code.
@MainActor
struct SessionControllerStartedAtTests {
    @Test func startedAtIsNilWhileIdle() {
        let session = SessionController()
        #expect(session.startedAt == nil)
    }

    @Test func startedAtReflectsStartAndSurvivesPauseResume() {
        let session = SessionController()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        session.start(now: t0)
        #expect(session.startedAt == t0)
        session.pause()
        #expect(session.startedAt == t0)
        session.resume()
        #expect(session.startedAt == t0)
    }

    @Test func startedAtClearsOnStop() {
        let session = SessionController()
        session.start(now: Date(timeIntervalSinceReferenceDate: 2000))
        session.stop()
        #expect(session.startedAt == nil)
    }
}
