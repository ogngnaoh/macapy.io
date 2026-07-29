import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// Live checks against the **real** DeepSeek endpoint — the one profile
/// live-verified in M2 (slice-02 doc, scope item 7).
///
/// Gated on the key being present, so the suite is *skipped*, never failed, on
/// a fresh clone, in CI, and for any contributor. Live results deliberately do
/// not gate a slice ship — machine checks 1–8 do that. What these add is the
/// single thing a fake server structurally cannot: evidence that the
/// hand-written fixtures still describe how DeepSeek actually behaves.
///
/// Run with `direnv allow` done (see `.envrc`), or:
///     MACAPY_DEEPSEEK_KEY=… swift test --filter DeepSeekLiveTests
@Suite(.enabled(if: LiveCredentials.hasDeepSeek))
struct DeepSeekLiveTests {

    private func client(key: String) -> OpenAICompatibleClient {
        OpenAICompatibleClient(profile: .deepSeek, apiKey: key)
    }

    private func tinyRequest(maxTokens: Int) -> CompletionRequest {
        CompletionRequest(
            model: EndpointProfile.deepSeek.fastModel,
            messages: [.user("Reply with exactly the word: ok")],
            purpose: .generation,
            maxTokens: maxTokens
        )
    }

    /// The happy path, kept deliberately tiny — a check that spends real money
    /// should spend as little of it as possible.
    ///
    /// The usage assertion is the load-bearing one: `SpendMeter` books every
    /// call from `Completion.usage`, so an endpoint that streams content but
    /// reports no usage would silently produce a ledger of zero-cost rows and
    /// a cap that never trips (FR-015).
    @Test func streamsTokensAndReportsUsageFromTheRealEndpoint() async throws {
        let key = try #require(LiveCredentials.deepSeekKey)

        var tokens = ""
        var completion: Completion?
        for try await event in client(key: key).stream(tinyRequest(maxTokens: 8)) {
            switch event {
            case .token(let text): tokens += text
            case .reasoning: break
            case .completed(let done): completion = done
            }
        }

        #expect(!tokens.isEmpty, "the real endpoint streamed no answer content")

        let done = try #require(completion, "stream ended without a .completed event")
        #expect(done.finishReason != nil)

        let usage = try #require(done.usage, "DeepSeek reported no usage — the spend ledger depends on it")
        #expect(usage.promptTokens > 0)
        #expect(usage.completionTokens > 0)
    }

    /// Costs nothing to run — a rejected key burns no tokens — and it pins the
    /// one mapping the fake server can only assert by fiat: that DeepSeek's
    /// *real* 401 body lands on `.http(status:)` rather than
    /// `.malformedResponse`. The settings screen's "The API key was rejected"
    /// copy is written off that case, so a mismatch here would show a user the
    /// wrong explanation for the most common setup mistake there is.
    @Test func aRejectedKeyMapsToATypedHTTPErrorNotAParseFailure() async throws {
        var caught: (any Error)?
        do {
            for try await _ in client(key: "sk-000000000000000000000000000000").stream(tinyRequest(maxTokens: 1)) {}
        } catch {
            caught = error
        }

        let error = try #require(caught, "the real endpoint accepted an obviously bogus key")
        let providerError = try #require(error as? ProviderError, "expected a typed ProviderError, got \(error)")

        guard case .http(let status, _) = providerError else {
            Issue.record("expected .http for a rejected key, got \(providerError)")
            return
        }
        #expect(status == 401 || status == 402 || status == 403, "unexpected rejection status \(status)")
    }
}
