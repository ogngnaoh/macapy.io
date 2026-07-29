import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// Acceptance check 1: SSE chunks decode to an ordered `LLMEvent` stream;
/// first-token and completion events observed; the stream ends cleanly.
struct StreamingClientTests {

    @Test func streamDecodesSSEChunksIntoOrderedEventsAndEndsCleanly() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.contentDelta("Hel"),
                OpenAIFixtures.contentDelta("lo"),
                OpenAIFixtures.contentDelta("!"),
                OpenAIFixtures.finish(reason: "stop", promptTokens: 12, completionTokens: 3),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }

        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
        let request = CompletionRequest(
            model: "fake-model",
            messages: [.user("say hello")],
            purpose: .generation
        )

        var events: [LLMEvent] = []
        for try await event in client.stream(request) {
            events.append(event)
        }

        #expect(events == [
            .token("Hel"),
            .token("lo"),
            .token("!"),
            .completed(Completion(
                finishReason: "stop",
                usage: TokenUsage(promptTokens: 12, cachedTokens: 0, completionTokens: 3)
            )),
        ])
    }
}
