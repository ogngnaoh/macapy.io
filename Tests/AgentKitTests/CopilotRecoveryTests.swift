import AgentKit
import ProviderKit
import Testing

struct CopilotRecoveryTests {
    @Test func deterministicScheduleCapsAtFiveMinutes() {
        let policy = CopilotRecoveryPolicy.default
        #expect((1...8).map(policy.delay(afterTransientFailure:))
            == [30, 60, 120, 240, 300, 300, 300, 300])
    }

    @Test func controllerRejectsStaleWakesAndSuccessRestartsAtThirtySeconds() {
        var controller = CopilotRecoveryController()
        let first = controller.recordTransientFailure()
        let second = controller.recordTransientFailure()

        #expect(!controller.owns(first))
        #expect(controller.owns(second))
        #expect(second.failureCount == 2)
        #expect(second.delay == 60)

        controller.recordSuccess()
        #expect(!controller.owns(second))
        #expect(controller.transientFailureCount == 0)
        #expect(controller.recordTransientFailure().delay == 30)
    }

    @Test func failureDispositionSeparatesHardLatchesFromRetryableReplies() {
        let policy = CopilotRecoveryPolicy.default
        #expect(policy.disposition(for: ProviderError.http(status: 401, message: nil))
            == .authenticationOrConfiguration)
        #expect(policy.disposition(for: ProviderError.http(status: 403, message: nil))
            == .authenticationOrConfiguration)
        #expect(policy.disposition(for: ProviderError.missingCredentials(profile: "deepseek"))
            == .authenticationOrConfiguration)
        #expect(policy.disposition(for: ProviderError.capReached(spentUSD: 1, capUSD: 1))
            == .cap)

        let retryable: [ProviderError] = [
            .transport("offline"),
            .rateLimited(message: nil),
            .server(status: 503, message: nil),
            .inStreamError(message: nil),
            .malformedResponse("bad SSE"),
            .decodingFailed("bad object"),
            .truncated(finishReason: "length"),
            .http(status: 408, message: nil),
        ]
        for error in retryable {
            #expect(policy.disposition(for: error) == .transient)
        }
    }
}
