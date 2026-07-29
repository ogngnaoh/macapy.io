import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// Acceptance check 3: continuation requests carry `reasoning_content` back on
/// endpoints that require it, and thinking-mode requests omit sampling params
/// where they are ignored.
///
/// Asserted against what reached the wire (`server.recordedRequests`), not
/// against the builder's return value — the quirk only counts if the endpoint
/// would actually see it. DeepSeek is M2's live-verified profile precisely
/// because it is the quirkiest (milestone Integration notes).
struct ProfileQuirksTests {

    private static func continuation() -> CompletionRequest {
        CompletionRequest(
            model: "deepseek-reasoner",
            messages: [
                .user("what's 2+2?"),
                .assistant("4", reasoningContent: "adding two and two"),
                .user("and doubled?"),
            ],
            purpose: .generation,
            temperature: 0.7,
            thinking: true
        )
    }

    private static var okStream: FakeOpenAIServer.Response {
        .sse(frames: [OpenAIFixtures.contentDelta("8"), OpenAIFixtures.finish(), OpenAIFixtures.done])
    }

    private func drain(_ client: OpenAICompatibleClient, _ request: CompletionRequest) async throws {
        for try await _ in client.stream(request) {}
    }

    private func messages(in server: FakeOpenAIServer) throws -> [[String: Any]] {
        let body = try #require(server.recordedRequests.first?.jsonBody)
        return try #require(body["messages"] as? [[String: Any]])
    }

    @Test func deepSeekContinuationCarriesReasoningContentBack() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.okStream])
        defer { server.stop() }
        var profile = EndpointProfile.deepSeek
        profile.baseURL = server.baseURL
        let client = OpenAICompatibleClient(profile: profile, apiKey: "sk-test")

        try await drain(client, Self.continuation())

        let messages = try messages(in: server)
        #expect(messages[1]["reasoning_content"] as? String == "adding two and two")
        #expect(messages[1]["content"] as? String == "4")
    }

    @Test func endpointsWithoutTheQuirkNeverSeeReasoningContent() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.okStream])
        defer { server.stop() }
        // OpenAI rejects unknown message fields; sending it would break the call.
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        try await drain(client, Self.continuation())

        let messages = try messages(in: server)
        #expect(messages[1]["reasoning_content"] == nil)
    }

    @Test func thinkingModeRequestOmitsSamplingParamsWhereTheyAreIgnored() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.okStream])
        defer { server.stop() }
        var profile = EndpointProfile.deepSeek
        profile.baseURL = server.baseURL
        let client = OpenAICompatibleClient(profile: profile, apiKey: "sk-test")

        try await drain(client, Self.continuation())

        let body = try #require(server.recordedRequests.first?.jsonBody)
        #expect(body["temperature"] == nil)
    }

    @Test func nonThinkingRequestKeepsItsSamplingParams() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.okStream])
        defer { server.stop() }
        var profile = EndpointProfile.deepSeek
        profile.baseURL = server.baseURL
        let client = OpenAICompatibleClient(profile: profile, apiKey: "sk-test")

        var request = Self.continuation()
        request.thinking = false
        try await drain(client, request)

        let body = try #require(server.recordedRequests.first?.jsonBody)
        #expect(body["temperature"] as? Double == 0.7)
    }

    @Test func reasoningDeltasSurfaceSeparatelyFromAnswerTokens() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.reasoningDelta("let me think"),
                OpenAIFixtures.reasoningDelta(" about it"),
                OpenAIFixtures.contentDelta("8"),
                OpenAIFixtures.finish(),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }
        var profile = EndpointProfile.deepSeek
        profile.baseURL = server.baseURL
        let client = OpenAICompatibleClient(profile: profile, apiKey: "sk-test")

        var events: [LLMEvent] = []
        for try await event in client.stream(Self.continuation()) { events.append(event) }

        #expect(events == [
            .reasoning("let me think"),
            .reasoning(" about it"),
            .token("8"),
            .completed(Completion(finishReason: "stop", usage: nil)),
        ])
    }

    @Test func keyedProfilesSendBearerAuthAndKeylessOnesSendNone() async throws {
        let keyed = try FakeOpenAIServer.start(responses: [Self.okStream])
        defer { keyed.stop() }
        try await drain(
            OpenAICompatibleClient(profile: .fake(baseURL: keyed.baseURL), apiKey: "sk-secret"),
            .hello
        )
        #expect(keyed.recordedRequests.first?.headers["authorization"] == "Bearer sk-secret")

        let keyless = try FakeOpenAIServer.start(responses: [Self.okStream])
        defer { keyless.stop() }
        var ollama = EndpointProfile.ollama
        ollama.baseURL = keyless.baseURL
        try await drain(OpenAICompatibleClient(profile: ollama, apiKey: nil), .hello)
        #expect(keyless.recordedRequests.first?.headers["authorization"] == nil)
    }

    @Test func builtInProfilesCoverTheFourEndpointsV1Supports() {
        let ids = EndpointProfile.builtIns.map(\.id)
        #expect(ids == ["openai", "openrouter", "deepseek", "ollama"])

        #expect(EndpointProfile.deepSeek.quirks.passesBackReasoningContent)
        #expect(EndpointProfile.deepSeek.quirks.ignoresSamplingParamsWhenThinking)
        #expect(EndpointProfile.deepSeek.quirks.selectsThinkingViaRequestField)
        // The V4 API retired `deepseek-chat`/`deepseek-reasoner`; thinking is a
        // request field now, not a separate model (checked against the live
        // pricing/API docs 2026-07-29).
        #expect(EndpointProfile.deepSeek.fastModel == "deepseek-v4-flash")
        #expect(EndpointProfile.deepSeek.deepModel == "deepseek-v4-pro")
        // SPEC §8: the data-jurisdiction note must be shown in setup UI.
        #expect(EndpointProfile.deepSeek.dataPolicyNote != nil)

        #expect(EndpointProfile.openAI.quirks == Quirks())
        #expect(EndpointProfile.openRouter.quirks == Quirks())
        #expect(EndpointProfile.ollama.quirks.requiresAPIKey == false)
    }
}
