import CaptureKit
import Foundation
import ProviderKit
import ProviderTestSupport
import Testing

@testable import AgentKit

struct CopilotGeneratorTests {
    private func turns() -> [CopilotTurn] {
        [
            CopilotTurn(source: .system, text: "old context", tStart: 0, tEnd: 1),
            CopilotTurn(source: .mic, text: "I can explain the migration.", tStart: 51, tEnd: 53),
            CopilotTurn(source: .system, text: "Can you summarize the migration risk?", tStart: 138, tEnd: 140),
        ]
    }

    private func collect(
        _ stream: AsyncThrowingStream<CopilotTextEvent, Error>
    ) async -> (events: [CopilotTextEvent], error: (any Error)?) {
        var events: [CopilotTextEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    @Test func suggestedAnswerStreamsContentSuppressesReasoningAndRequiresNaturalStop() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.reasoningDelta("private chain"),
                OpenAIFixtures.contentDelta("Mention the "),
                OpenAIFixtures.contentDelta("rollback plan."),
                OpenAIFixtures.finish(reason: "stop"),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }
        var profile = EndpointProfile.deepSeek
        profile.baseURL = server.baseURL
        let generator = CopilotGenerator(
            provider: OpenAICompatibleClient(profile: profile, apiKey: "sk-test"),
            model: "deepseek-v4-pro"
        )

        let result = await collect(generator.suggestedAnswer(
            turns: turns(),
            target: "migration risk"
        ))

        #expect(result.error == nil)
        #expect(result.events == [
            .delta("Mention the "),
            .delta("rollback plan."),
            .completed("Mention the rollback plan."),
        ])
        let body = try #require(server.recordedRequests.first?.jsonBody)
        #expect(body["model"] as? String == "deepseek-v4-pro")
        #expect(body["max_tokens"] as? Int == CopilotGenerator.shortOutputTokenCeiling)
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        #expect(body["temperature"] as? Double == 0)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let user = try #require(messages.last?["content"] as? String)
        #expect(user.contains("at most 60 words"))
        #expect(user.contains("Can you summarize the migration risk?"))
    }

    @Test(arguments: ["length", "content_filter", "tool_calls"])
    func nonStopCompletionClearsPartialOutput(_ reason: String) async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.contentDelta("unsafe partial"),
                OpenAIFixtures.finish(reason: reason),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }
        let generator = CopilotGenerator(
            provider: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            model: "fake-deep"
        )

        let result = await collect(generator.suggestedAnswer(turns: turns(), target: "risk"))

        #expect(result.events == [.delta("unsafe partial"), .cleared])
        #expect(result.error as? ProviderError == .truncated(finishReason: reason))
    }

    @Test func catchUpUsesOnlyTheLastNinetyTranscriptSeconds() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.contentDelta("They discussed migration risk."),
                OpenAIFixtures.finish(),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }
        let generator = CopilotGenerator(
            provider: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            model: "fake-deep"
        )

        let result = await collect(generator.catchUp(turns: turns()))

        #expect(result.error == nil)
        let body = try #require(server.recordedRequests.first?.jsonBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let user = try #require(messages.last?["content"] as? String)
        #expect(!user.contains("old context"))
        #expect(user.contains("I can explain the migration."))
        #expect(user.contains("Can you summarize the migration risk?"))
        #expect(user.contains("at most 60 words"))
    }

    @Test func commitmentUsesDeepGenerationWithExplicitCeiling() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.contentDelta("Send the plan by Friday."),
                OpenAIFixtures.finish(),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }
        let generator = CopilotGenerator(
            provider: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            model: "fake-deep"
        )

        _ = await collect(generator.commitment(turns: turns(), target: "You will send the plan by Friday"))

        let body = try #require(server.recordedRequests.first?.jsonBody)
        #expect(body["max_tokens"] as? Int == CopilotGenerator.shortOutputTokenCeiling)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let user = try #require(messages.last?["content"] as? String)
        #expect(user.contains("deadline only if the transcript states one"))
        #expect(user.contains("You will send the plan by Friday"))
    }

    @Test func answerCannotExceedSixtyWordsEvenWhenProviderIgnoresPrompt() async throws {
        let overlong = (1...65).map { "word\($0)" }.joined(separator: " ")
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.contentDelta(overlong),
                OpenAIFixtures.finish(),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }
        let generator = CopilotGenerator(
            provider: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            model: "fake-deep"
        )

        let result = await collect(generator.suggestedAnswer(turns: turns(), target: "risk"))

        let completed = result.events.compactMap { event -> String? in
            guard case .completed(let text) = event else { return nil }
            return text
        }.first
        #expect(completed?.split(whereSeparator: \.isWhitespace).count == 60)
        #expect(completed?.contains("word60") == true)
        #expect(completed?.contains("word61") == false)
    }
}
