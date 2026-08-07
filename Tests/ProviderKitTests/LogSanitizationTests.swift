import Testing

@testable import ProviderKit

/// The log sanitizer's contract (critic finding, slice 3): a provider may
/// echo request content — transcript text included — back inside an error
/// message, so `logDescription` must carry the case (and status), never the
/// message. Every module logging a `ProviderError` routes through this.
struct LogSanitizationTests {

    private static let leak = "SECRET transcript excerpt"

    private static let messageCarryingErrors: [ProviderError] = [
        .transport(leak),
        .rateLimited(message: leak),
        .server(status: 503, message: leak),
        .http(status: 400, message: leak),
        .inStreamError(message: leak),
        .malformedResponse(leak),
        .decodingFailed(leak),
        .missingCredentials(profile: leak),
    ]

    @Test func logDescriptionNeverContainsTheEndpointsMessage() {
        for error in Self.messageCarryingErrors {
            #expect(
                !error.logDescription.contains(Self.leak),
                "\(error.logDescription) leaked the message for \(error)")
            #expect(!error.logDescription.isEmpty)
        }
    }

    @Test func logDescriptionKeepsTheDiagnosticShape() {
        #expect(ProviderError.server(status: 503, message: "x").logDescription == "server(503)")
        #expect(ProviderError.http(status: 401, message: "x").logDescription == "http(401)")
        #expect(ProviderError.truncated(finishReason: "length").logDescription == "truncated(length)")
        #expect(ProviderError.capReached(spentUSD: 1, capUSD: 0.5).logDescription == "capReached")
    }
}
