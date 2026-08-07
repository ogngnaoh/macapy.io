import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// Slice-2 open item, ruled on in slice 3: a structured (non-streaming) call
/// whose `finish_reason` is anything but a natural stop throws
/// `ProviderError.truncated` — even when the payload happens to parse. A
/// `length`-cut extraction that still decoded would silently draft partial
/// artifacts, the exact failure check 2 exists to prevent.
struct FinishReasonTests {

    private struct Payload: Codable, Equatable {
        let summary: String
    }

    private static var request: CompletionRequest {
        CompletionRequest(
            model: "fake-model",
            messages: [.user("extract")],
            purpose: .artifact,
            responseFormat: ResponseFormat(
                name: "payload",
                schema: try! JSONSchema([
                    "type": "object",
                    "properties": ["summary": ["type": "string"]],
                    "required": ["summary"],
                    "additionalProperties": false,
                ]))
        )
    }

    @Test(arguments: ["length", "content_filter"])
    func nonStopFinishReasonThrowsTruncatedEvenWhenTheJSONParses(reason: String) async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"summary":"parses fine but may be incomplete"}"#,
                finishReason: reason))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        await #expect(throws: ProviderError.truncated(finishReason: reason)) {
            _ = try await client.complete(Self.request, as: Payload.self)
        }
    }

    @Test func naturalStopStillDecodes() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"summary":"whole"}"#, finishReason: "stop"))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        let value = try await client.complete(Self.request, as: Payload.self)
        #expect(value == Payload(summary: "whole"))
    }
}
