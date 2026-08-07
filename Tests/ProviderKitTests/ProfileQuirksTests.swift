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

    /// Slice-3 live finding: first-party DeepSeek 400s on `json_schema`
    /// ("This response_format type is unavailable now"). With the quirk, the
    /// wire carries `json_object` plus a trailing system message holding the
    /// schema — and the caller's own messages are untouched before it.
    @Test func jsonObjectQuirkDowngradesResponseFormatAndAppendsTheSchema() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: #"{"answer":"4"}"#))
        ])
        defer { server.stop() }
        var profile = EndpointProfile.deepSeek
        profile.baseURL = server.baseURL
        let client = OpenAICompatibleClient(profile: profile, apiKey: "sk-test")

        struct Answer: Decodable { let answer: String }
        let request = CompletionRequest(
            model: "deepseek-v4-pro",
            messages: [.system("You add numbers."), .user("2+2, as JSON")],
            purpose: .artifact,
            responseFormat: ResponseFormat(
                name: "answer",
                schema: try JSONSchema([
                    "type": "object",
                    "properties": ["answer": ["type": "string"]],
                    "required": ["answer"],
                    "additionalProperties": false,
                ]))
        )
        _ = try await client.complete(request, as: Answer.self)

        let body = try #require(server.recordedRequests.first?.jsonBody)
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_object")
        #expect(format["json_schema"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages[0]["content"] as? String == "You add numbers.")
        #expect(messages[1]["content"] as? String == "2+2, as JSON")
        let trailing = try #require(messages.last)
        #expect(trailing["role"] as? String == "system")
        let schemaMessage = try #require(trailing["content"] as? String)
        #expect(schemaMessage.contains("JSON Schema"))
        #expect(schemaMessage.contains(#""answer""#))
    }

    /// The neutral dialect is untouched by the quirk: strict `json_schema` on
    /// the wire, no appended message (the existing structured-output tests
    /// pin the format itself; this pins the *absence* of the schema message).
    @Test func withoutTheQuirkNoSchemaMessageIsAppended() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: #"{"answer":"4"}"#))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        struct Answer: Decodable { let answer: String }
        let request = CompletionRequest(
            model: "fake-model",
            messages: [.user("2+2, as JSON")],
            purpose: .artifact,
            responseFormat: ResponseFormat(
                name: "answer",
                schema: try JSONSchema([
                    "type": "object",
                    "properties": ["answer": ["type": "string"]],
                    "required": ["answer"],
                    "additionalProperties": false,
                ]))
        )
        _ = try await client.complete(request, as: Answer.self)

        let body = try #require(server.recordedRequests.first?.jsonBody)
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
    }

    @Test func builtInProfilesCoverTheFourEndpointsV1Supports() {
        let ids = EndpointProfile.builtIns.map(\.id)
        #expect(ids == ["openai", "openrouter", "deepseek", "ollama"])

        #expect(EndpointProfile.deepSeek.quirks.passesBackReasoningContent)
        #expect(EndpointProfile.deepSeek.quirks.ignoresSamplingParamsWhenThinking)
        #expect(EndpointProfile.deepSeek.quirks.selectsThinkingViaRequestField)
        // Live-proven in slice 3: first-party DeepSeek supports only
        // json_object structured output.
        #expect(EndpointProfile.deepSeek.quirks.usesJSONObjectResponseFormat)
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
