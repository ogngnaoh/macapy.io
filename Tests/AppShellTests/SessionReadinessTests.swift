import Foundation
import Testing
@testable import AppShell

@MainActor
struct SessionReadinessTests {
    @Test func preparationDoesNotClaimCaptureOrStartTheClock() {
        let session = SessionController()
        #expect(session.prepare())
        #expect(session.isPreparing)
        #expect(session.isActive)
        #expect(!session.isCapturing)
        #expect(session.startedAt == nil)
        #expect(!session.pause())
        let ready = Date(timeIntervalSince1970: 123)
        #expect(session.captureDidStart(now: ready))
        #expect(session.isCapturing)
        #expect(session.startedAt == ready)
    }

    @Test func stoppedPreparationCannotResurrectCapture() {
        let session = SessionController()
        session.prepare()
        session.stop()
        #expect(!session.captureDidStart())
        #expect(!session.isActive)
    }

    @Test func failedPreparationRetainsSafeRecoveryUntilNextAttempt() {
        let session = SessionController()
        session.prepare()
        session.fail(.speechAssets)
        #expect(!session.isActive)
        #expect(session.failure == .speechAssets)
        #expect(session.failure?.message.contains("Setup") == true)
        session.prepare()
        #expect(session.failure == nil)
        #expect(session.isPreparing)
    }

    @Test func unknownErrorsNeverExposeTheirDescription() {
        struct PrivateError: LocalizedError {
            var errorDescription: String? { "private transcript sk-secret" }
        }
        let failure = SessionFailure.classify(PrivateError())
        #expect(!failure.message.contains("private"))
        #expect(!failure.message.contains("sk-secret"))
    }
}
