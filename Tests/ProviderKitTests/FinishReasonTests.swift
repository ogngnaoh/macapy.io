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

    @Test func missingFinishReasonIsRejectedAsUnknownTruncation() async throws {
        let body = #"{"choices":[{"message":{"content":"{\"summary\":\"not terminal\"}"}}]}"#
        let server = try FakeOpenAIServer.start(responses: [.json(status: 200, body: body)])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        await #expect(throws: ProviderError.truncated(finishReason: "unknown")) {
            _ = try await client.complete(Self.request, as: Payload.self)
        }
    }

    @Test func hostileFinishReasonNeverEscapesInTheTypedErrorOrLogDescription() async throws {
        let hostile = "SECRET transcript excerpt\nforge=success"
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"summary":"parses"}"#,
                finishReason: hostile
            ))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        do {
            _ = try await client.complete(Self.request, as: Payload.self)
            Issue.record("expected truncation")
        } catch let error as ProviderError {
            #expect(error == .truncated(finishReason: "unknown"))
            #expect(!error.logDescription.contains(hostile))
            #expect(error.logDescription == "truncated(unknown)")
        }
    }
}
