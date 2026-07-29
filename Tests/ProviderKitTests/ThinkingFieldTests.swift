import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// DeepSeek V4 selects thinking per request (`"thinking": {"type": "enabled"}`),
/// not via a separate reasoner model id — a `thinking: true` request that never
/// serializes the field silently runs non-thinking against the current API.
/// Endpoints without the field (OpenAI) reject unknown top-level params, so it
/// is quirk-gated. Asserted against the wire, like every quirk.
struct ThinkingFieldTests {

    private static var okStream: FakeOpenAIServer.Response {
        .sse(frames: [OpenAIFixtures.contentDelta("8"), OpenAIFixtures.finish(), OpenAIFixtures.done])
    }

    private func wireBody(
        profile base: EndpointProfile,
        thinking: Bool
    ) async throws -> [String: Any] {
        let server = try FakeOpenAIServer.start(responses: [Self.okStream])
        defer { server.stop() }
        var profile = base
        profile.baseURL = server.baseURL
        let client = OpenAICompatibleClient(profile: profile, apiKey: "sk-test")

        var request = CompletionRequest.hello
        request.thinking = thinking
        for try await _ in client.stream(request) {}

        return try #require(server.recordedRequests.first?.jsonBody)
    }

    @Test func deepSeekThinkingRequestsEnableThinkingOnTheWire() async throws {
        let body = try await wireBody(profile: .deepSeek, thinking: true)

        #expect((body["thinking"] as? [String: String])?["type"] == "enabled")
    }

    @Test func deepSeekNonThinkingRequestsExplicitlyDisableThinking() async throws {
        let body = try await wireBody(profile: .deepSeek, thinking: false)

        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
    }

    @Test func endpointsWithoutTheQuirkNeverSeeTheField() async throws {
        let body = try await wireBody(profile: .fake(baseURL: URL(string: "http://placeholder")!), thinking: true)

        #expect(body["thinking"] == nil)
    }
}
