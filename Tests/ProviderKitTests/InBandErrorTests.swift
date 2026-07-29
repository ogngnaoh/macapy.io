import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// OpenAI-compatible proxies (OpenRouter documents this) report failures that
/// happen *after* SSE headers are sent as an in-band `data: {"error": …}` event
/// under HTTP 200, usually followed by `[DONE]`. Swallowing that event lets a
/// failed, truncated generation present as a clean completion — the exact
/// half-artifact-persisted-as-whole failure the truncation guard exists to
/// prevent (slice-2 critic pass).
struct InBandErrorTests {

    private func run(
        frames: [String],
        truncateAfterFrames: Int? = nil
    ) async throws -> (events: [LLMEvent], thrown: Error?) {
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: frames, truncateAfterFrames: truncateAfterFrames)
        ])
        defer { server.stop() }
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")

        var events: [LLMEvent] = []
        var thrown: Error?
        do {
            for try await event in client.stream(.hello) { events.append(event) }
        } catch {
            thrown = error
        }
        return (events, thrown)
    }

    @Test func anErrorEventFollowedByDONESurfacesTypedInsteadOfCompletingCleanly() async throws {
        let (events, thrown) = try await run(frames: [
            OpenAIFixtures.contentDelta("half an ans"),
            OpenAIFixtures.errorEvent(message: "Upstream provider error"),
            OpenAIFixtures.done,
        ])

        #expect(events.contains(.token("half an ans")), "tokens delivered before the failure stay delivered")
        #expect(!events.contains { if case .completed = $0 { true } else { false } },
                "a failed stream must never present as a clean completion")
        guard case .inStreamError(let message) = thrown as? ProviderError else {
            Issue.record("expected ProviderError.inStreamError, got \(String(describing: thrown))")
            return
        }
        #expect(message == "Upstream provider error")
    }

    @Test func anInBandErrorWithA429CodeMapsToRateLimited() async throws {
        let (_, thrown) = try await run(frames: [
            OpenAIFixtures.errorEvent(message: "slow down", code: 429),
            OpenAIFixtures.done,
        ])

        guard case .rateLimited(let message) = thrown as? ProviderError else {
            Issue.record("expected ProviderError.rateLimited, got \(String(describing: thrown))")
            return
        }
        #expect(message == "slow down")
    }

    @Test func anInBandErrorWithA5xxCodeMapsToServer() async throws {
        let (_, thrown) = try await run(frames: [
            OpenAIFixtures.errorEvent(message: "upstream 502", code: 502),
            OpenAIFixtures.done,
        ])

        guard case .server(let status, let message) = thrown as? ProviderError else {
            Issue.record("expected ProviderError.server, got \(String(describing: thrown))")
            return
        }
        #expect(status == 502)
        #expect(message == "upstream 502")
    }

    /// OpenAI's own error shape is an object, but proxies also emit the bare
    /// string form — `{"error": "upstream overloaded"}`. Matching only the
    /// object form let a string-form failure present as a clean completion
    /// (fix-review D3).
    @Test func aStringFormErrorEventAlsoSurfacesTyped() async throws {
        let (events, thrown) = try await run(frames: [
            OpenAIFixtures.contentDelta("half an ans"),
            #"{"error":"upstream overloaded"}"#,
            OpenAIFixtures.done,
        ])

        #expect(!events.contains { if case .completed = $0 { true } else { false } })
        guard case .inStreamError(let message) = thrown as? ProviderError else {
            Issue.record("expected ProviderError.inStreamError, got \(String(describing: thrown))")
            return
        }
        #expect(message == "upstream overloaded")
    }

    /// The inverse guard: some endpoints put `"error": null` on perfectly
    /// healthy chunks — a present-but-null key must not kill the stream.
    @Test func aNullErrorFieldOnAHealthyChunkIsIgnored() async throws {
        let (events, thrown) = try await run(frames: [
            #"{"choices":[{"delta":{"content":"hi"},"finish_reason":null}],"error":null}"#,
            OpenAIFixtures.finish(),
            OpenAIFixtures.done,
        ])

        #expect(thrown == nil)
        #expect(events.contains(.token("hi")))
    }

    @Test func anInBandErrorFollowedByEOFStillCarriesTheProviderMessage() async throws {
        // The connection dies right after the error event: the provider's
        // actual message must surface, not a generic truncation error.
        let (_, thrown) = try await run(
            frames: [
                OpenAIFixtures.contentDelta("half"),
                OpenAIFixtures.errorEvent(message: "moderation block"),
            ],
            truncateAfterFrames: 2
        )

        guard case .inStreamError(let message) = thrown as? ProviderError else {
            Issue.record("expected ProviderError.inStreamError, got \(String(describing: thrown))")
            return
        }
        #expect(message == "moderation block")
    }
}
