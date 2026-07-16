import Foundation
import Testing

@testable import AppShell

@MainActor
struct SessionControllerTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    let t1 = Date(timeIntervalSinceReferenceDate: 2_000)

    @Test func startsIdle() {
        let session = SessionController()
        #expect(session.state == .idle)
        #expect(!session.isCapturing)
    }

    @Test func startBeginsCapturing() {
        let session = SessionController()
        let started = session.start(now: t0)
        #expect(started)
        #expect(session.state == .capturing(startedAt: t0))
        #expect(session.isCapturing)
    }

    @Test func startWhileCapturingIsANoOpAndKeepsOriginalStart() {
        let session = SessionController()
        session.start(now: t0)
        let startedAgain = session.start(now: t1)
        #expect(!startedAgain)
        #expect(session.state == .capturing(startedAt: t0))
    }

    @Test func stopReturnsToIdle() {
        let session = SessionController()
        session.start(now: t0)
        let stopped = session.stop()
        #expect(stopped)
        #expect(session.state == .idle)
        #expect(!session.isCapturing)
    }

    @Test func stopWhileIdleIsANoOp() {
        let session = SessionController()
        let stopped = session.stop()
        #expect(!stopped)
        #expect(session.state == .idle)
    }

    @Test func toggleAlternatesBetweenIdleAndCapturing() {
        let session = SessionController()
        session.toggle(now: t0)
        #expect(session.state == .capturing(startedAt: t0))
        session.toggle(now: t1)
        #expect(session.state == .idle)
    }

    @Test func rapidTogglesNeverWedgeTheStateMachine() {
        let session = SessionController()
        for _ in 0..<101 {
            session.toggle(now: t0)
        }
        // Odd number of toggles from idle ends capturing; one more returns to idle.
        #expect(session.state == .capturing(startedAt: t0))
        session.toggle(now: t1)
        #expect(session.state == .idle)
    }
}
