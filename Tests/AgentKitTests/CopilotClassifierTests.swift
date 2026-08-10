import CaptureKit
import Foundation
import ProviderKit
import ProviderTestSupport
import Testing

@testable import AgentKit

struct CopilotClassifierTests {
    private func turns() -> [CopilotTurn] {
        (0..<12).map { index in
            let text: String
            switch index {
            case 0: text = "excluded-zero"
            case 1: text = "excluded-one"
            default: text = "kept-\(index)"
            }
            return CopilotTurn(
                source: index.isMultiple(of: 3) ? .mic : .system,
                text: text,
                tStart: Double(index),
                tEnd: Double(index) + 0.8
            )
        }
    }

    @Test func classifierUsesFastStrictNonThinkingRequestAndLastTenTurns() async throws {
        let json = #"{"action":"suggest_answer","confidence":0.96,"target":"migration risk"}"#
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: json))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        let result = try await CopilotClassifier(provider: client, model: "fake-fast")
            .classify(recentTurns: turns(), preferredName: "  Hoang  ")

        #expect(result.action == .suggestAnswer)
        #expect(result.confidence == 0.96)
        let body = try #require(server.recordedRequests.first?.jsonBody)
        #expect(body["model"] as? String == "fake-fast")
        #expect(body["temperature"] as? Double == 0)
        #expect(body["max_tokens"] as? Int == CopilotClassifier.outputTokenCeiling)
        #expect(body["thinking"] == nil, "non-DeepSeek endpoints must not receive unknown thinking fields")
        let format = try #require(body["response_format"] as? [String: Any])
        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(schema["name"] as? String == "copilot_classifier_decision")
        #expect(schema["strict"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect((messages.first?["content"] as? String)?.contains("Hoang") == true)
        let transcript = try #require(messages.last?["content"] as? String)
        #expect(!transcript.contains("excluded-zero"))
        #expect(!transcript.contains("excluded-one"))
        #expect(transcript.contains("kept-2"))
        #expect(transcript.contains("kept-11"))
    }

    @Test func deepSeekClassifierUsesJSONObjectQuirkAndExplicitlyDisablesThinking() async throws {
        let json = #"{"action":"none","confidence":0.2,"target":null}"#
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: json))
        ])
        defer { server.stop() }
        var profile = EndpointProfile.deepSeek
        profile.baseURL = server.baseURL
        let client = OpenAICompatibleClient(profile: profile, apiKey: "sk-test")

        _ = try await CopilotClassifier(provider: client, model: "deepseek-v4-flash")
            .classify(recentTurns: turns())

        let body = try #require(server.recordedRequests.first?.jsonBody)
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect((messages.last?["content"] as? String)?.contains("JSON Schema") == true)
        let actualCharacters = messages.compactMap { $0["content"] as? String }
            .reduce(0) { $0 + $1.count }
        #expect(CopilotClassifier.requestCharacterCount(recentTurns: turns())
            == actualCharacters)
    }

    @Test func oversizedLastTenAreRejectedBeforeAnyProviderCall() async throws {
        let server = try FakeOpenAIServer.start(responses: [])
        defer { server.stop() }
        let client = OpenAICompatibleClient(
            profile: .fake(baseURL: server.baseURL),
            apiKey: "sk-test"
        )
        let hostile = (0..<10).map { index in
            CopilotTurn(
                source: .system,
                text: String(repeating: "x", count: 7_000) + "-\(index)",
                tStart: Double(index),
                tEnd: Double(index + 1)
            )
        }

        await #expect(throws: CopilotContextError.self) {
            try await CopilotClassifier(provider: client, model: "fast")
                .classify(recentTurns: hostile)
        }
        #expect(server.recordedRequests.isEmpty)
    }

    @Test(arguments: [
        "not json",
        #"{"action":"catch_up","confidence":0.99,"target":"the last bit"}"#,
        #"{"action":"suggest_answer","confidence":0.95,"target":null}"#,
    ])
    func malformedOrForbiddenRepliesFailTyped(_ content: String) async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: content))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        await #expect(throws: ProviderError.self) {
            try await CopilotClassifier(provider: client, model: "fake-fast")
                .classify(recentTurns: turns())
        }
    }
}
