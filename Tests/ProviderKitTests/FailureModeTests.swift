import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// Acceptance check 4: a mid-stream disconnect surfaces a typed error and
/// leaves the client reusable; 429 and 5xx map to typed errors; a scripted
/// fail → succeed recovery sequence completes.
///
/// These are the reliability guarantees PRD §7 rests on — the copilot cascade
/// and post-meeting agent must degrade, not crash, when the provider misbehaves.
struct FailureModeTests {

    private func collect(
        _ client: OpenAICompatibleClient,
        _ request: CompletionRequest = .hello
    ) async throws -> [LLMEvent] {
        var events: [LLMEvent] = []
        for try await event in client.stream(request) { events.append(event) }
        return events
    }

    @Test func midStreamDisconnectSurfacesTransportErrorAfterTheTokensItDidDeliver() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sse(
                frames: [
                    OpenAIFixtures.contentDelta("half a "),
                    OpenAIFixtures.contentDelta("sentence"),
                    OpenAIFixtures.finish(),
                    OpenAIFixtures.done,
                ],
                truncateAfterFrames: 2
            )
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        var delivered: [LLMEvent] = []
        var thrown: Error?
        do {
            for try await event in client.stream(.hello) { delivered.append(event) }
        } catch {
            thrown = error
        }

        #expect(delivered == [.token("half a "), .token("sentence")])
        guard case .transport = thrown as? ProviderError else {
            Issue.record("expected ProviderError.transport, got \(String(describing: thrown))")
            return
        }
        // No `.completed` may escape a truncated stream — a caller that saw one
        // would persist a half-finished artifact as if it were whole.
        #expect(!delivered.contains { if case .completed = $0 { return true } else { return false } })
    }

    @Test func clientStaysUsableAfterAMidStreamDisconnect() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [OpenAIFixtures.contentDelta("cut")], truncateAfterFrames: 1),
            .sse(frames: [OpenAIFixtures.contentDelta("recovered"), OpenAIFixtures.finish(), OpenAIFixtures.done]),
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        _ = try? await collect(client)
        let second = try await collect(client)

        #expect(second == [.token("recovered"), .completed(Completion(finishReason: "stop", usage: nil))])
    }

    @Test func rateLimitMapsToTypedErrorCarryingTheEndpointMessage() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 429, body: OpenAIFixtures.errorBody(message: "Rate limit reached", type: "rate_limit_error"))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        await #expect(throws: ProviderError.rateLimited(message: "Rate limit reached")) {
            _ = try await collect(client)
        }
    }

    @Test func serverErrorMapsToTypedErrorCarryingItsStatus() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 503, body: OpenAIFixtures.errorBody(message: "upstream unavailable"))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        await #expect(throws: ProviderError.server(status: 503, message: "upstream unavailable")) {
            _ = try await collect(client)
        }
    }

    @Test func unauthorizedMapsToHTTPErrorRatherThanRateLimitOrServer() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 401, body: OpenAIFixtures.errorBody(message: "Invalid API key", type: "invalid_request_error"))
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-wrong")

        await #expect(throws: ProviderError.http(status: 401, message: "Invalid API key")) {
            _ = try await collect(client)
        }
    }

    @Test func aFailThenSucceedSequenceCompletesOnTheRetry() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 429, body: OpenAIFixtures.errorBody(message: "slow down", type: "rate_limit_error")),
            .sse(frames: [OpenAIFixtures.contentDelta("after the wait"), OpenAIFixtures.finish(), OpenAIFixtures.done]),
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        await #expect(throws: ProviderError.self) { _ = try await collect(client) }
        let recovered = try await collect(client)

        #expect(recovered == [.token("after the wait"), .completed(Completion(finishReason: "stop", usage: nil))])
    }

    @Test func malformedSSEChunkThrowsTypedErrorInsteadOfBeingSkipped() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [OpenAIFixtures.contentDelta("fine so far"), "{not json at all", OpenAIFixtures.done])
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        var thrown: Error?
        do { _ = try await collect(client) } catch { thrown = error }

        guard case .malformedResponse = thrown as? ProviderError else {
            Issue.record("expected ProviderError.malformedResponse, got \(String(describing: thrown))")
            return
        }
    }
}

extension CompletionRequest {
    static var hello: CompletionRequest {
        CompletionRequest(model: "fake-model", messages: [.user("hi")], purpose: .generation)
    }
}
