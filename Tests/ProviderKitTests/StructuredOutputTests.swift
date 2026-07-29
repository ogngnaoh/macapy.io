import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// Acceptance check 2: `complete<T>` validates the final object against the
/// schema type; malformed and truncated payloads throw typed errors with no
/// partial object escaping.
///
/// This is the path the post-meeting agent (slice 3) extracts artifacts on —
/// a half-decoded summary silently becoming a draft artifact is the failure
/// this check exists to prevent.
struct StructuredOutputTests {

    private struct MeetingArtifacts: Codable, Equatable {
        let summary: String
        let decisions: [String]
    }

    private static let schema = try! JSONSchema([
        "type": "object",
        "properties": [
            "summary": ["type": "string"],
            "decisions": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["summary", "decisions"],
        "additionalProperties": false,
    ])

    private static var request: CompletionRequest {
        CompletionRequest(
            model: "fake-model",
            messages: [.user("extract artifacts")],
            purpose: .artifact,
            responseFormat: ResponseFormat(name: "meeting_artifacts", schema: schema)
        )
    }

    @Test func completeDecodesTheFinalObject() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"summary":"we shipped the spine","decisions":["ship M1","start M2"]}"#
            ))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        let artifacts = try await client.complete(Self.request, as: MeetingArtifacts.self)

        #expect(artifacts == MeetingArtifacts(
            summary: "we shipped the spine",
            decisions: ["ship M1", "start M2"]
        ))
    }

    @Test func completeSendsTheSchemaAsAStrictResponseFormat() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"summary":"x","decisions":[]}"#
            ))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        _ = try await client.complete(Self.request, as: MeetingArtifacts.self)

        let body = try #require(server.recordedRequests.first?.jsonBody)
        #expect(body["stream"] as? Bool == false)
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let jsonSchema = try #require(format["json_schema"] as? [String: Any])
        #expect(jsonSchema["name"] as? String == "meeting_artifacts")
        #expect(jsonSchema["strict"] as? Bool == true)
        let schema = try #require(jsonSchema["schema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["summary", "decisions"])
    }

    @Test func truncatedPayloadThrowsRatherThanYieldingAPartialObject() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"summary":"we shipped the spine","deci"#
            ))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        var thrown: Error?
        do { _ = try await client.complete(Self.request, as: MeetingArtifacts.self) } catch { thrown = error }

        guard case .decodingFailed = thrown as? ProviderError else {
            Issue.record("expected ProviderError.decodingFailed, got \(String(describing: thrown))")
            return
        }
    }

    @Test func payloadMissingARequiredFieldThrowsDecodingFailed() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: #"{"summary":"no decisions key"}"#))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        var thrown: Error?
        do { _ = try await client.complete(Self.request, as: MeetingArtifacts.self) } catch { thrown = error }

        guard case .decodingFailed = thrown as? ProviderError else {
            Issue.record("expected ProviderError.decodingFailed, got \(String(describing: thrown))")
            return
        }
    }

    @Test func aBodyThatIsNotAChatCompletionThrowsMalformedResponse() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: #"{"unexpected":"shape"}"#)
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        var thrown: Error?
        do { _ = try await client.complete(Self.request, as: MeetingArtifacts.self) } catch { thrown = error }

        guard case .malformedResponse = thrown as? ProviderError else {
            Issue.record("expected ProviderError.malformedResponse, got \(String(describing: thrown))")
            return
        }
    }

    @Test func completeMapsTransportFailuresToTheSameTypedErrorsAsStreaming() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 429, body: OpenAIFixtures.errorBody(message: "slow down", type: "rate_limit_error"))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        await #expect(throws: ProviderError.rateLimited(message: "slow down")) {
            _ = try await client.complete(Self.request, as: MeetingArtifacts.self)
        }
    }
}
