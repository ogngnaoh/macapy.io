import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// OpenAI (and OpenRouter) only attach the usage-bearing final chunk when the
/// request opts in via `stream_options.include_usage` — without it, every
/// streamed call reports `usage == nil`, the metering decorator books nothing,
/// and the per-meeting cap goes blind (slice-2 critic pass, critical finding).
/// DeepSeek volunteers usage by default, which is exactly why live checks
/// against the one live-verified profile could never catch this.
struct StreamingUsageTests {

    @Test func streamingRequestsOptInToUsageReporting() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.contentDelta("hi"),
                OpenAIFixtures.finish(),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        for try await _ in client.stream(.hello) {}

        let body = try #require(server.recordedRequests.first?.jsonBody)
        let options = try #require(body["stream_options"] as? [String: Any])
        #expect(options["include_usage"] as? Bool == true)
    }

    @Test func nonStreamingRequestsCarryNoStreamOptions() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: #"{"answer":"yes"}"#))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        struct Reply: Codable { let answer: String }
        _ = try await client.complete(.hello, as: Reply.self)

        let body = try #require(server.recordedRequests.first?.jsonBody)
        #expect(body["stream_options"] == nil)
    }

    @Test func usageOnATrailingEmptyChoicesChunkReachesTheTerminalEvent() async throws {
        // The real OpenAI shape: finish_reason on one chunk, usage on a later
        // chunk whose `choices` array is empty.
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.contentDelta("hi"),
                OpenAIFixtures.finish(reason: "stop"),
                OpenAIFixtures.usageChunk(promptTokens: 7, completionTokens: 3, cachedTokens: 2),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        var events: [LLMEvent] = []
        for try await event in client.stream(.hello) { events.append(event) }

        #expect(events.last == .completed(Completion(
            finishReason: "stop",
            usage: TokenUsage(promptTokens: 7, cachedTokens: 2, completionTokens: 3)
        )))
    }
}
