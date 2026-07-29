import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// The `LLMProvider` contract says transport failures surface "typed as
/// `ProviderError`" — that must include the failures URLSession itself throws
/// (connection refused, DNS, TLS, mid-stream RST), not only the graceful-close
/// truncation the protocol guard catches. Raw `URLError` breaks every caller's
/// `catch let e as ProviderError` degrade path and logs as `error=unknown`
/// (slice-2 critic pass).
struct TransportErrorTests {

    @Test func aConnectFailureSurfacesAsTypedTransport() async throws {
        let client = OpenAICompatibleClient(
            profile: .fake(baseURL: URL(string: "http://127.0.0.1:9/v1")!),
            apiKey: "sk-test",
            session: ConnectFailingURLProtocol.session()
        )

        var thrown: Error?
        do {
            for try await _ in client.stream(.hello) {}
        } catch {
            thrown = error
        }

        guard case .transport = thrown as? ProviderError else {
            Issue.record("expected ProviderError.transport, got \(String(describing: thrown))")
            return
        }
    }

    @Test func aMidStreamConnectionLossSurfacesAsTypedTransport() async throws {
        // Note: URLSession discards the stub's already-delivered bytes when the
        // protocol fails immediately after them, so no token assertion here —
        // tokens-before-failure-stay-delivered is established by the fake
        // server's truncation and in-band error tests. This test pins the
        // *typed* surfacing of a URLSession-thrown mid-stream failure.
        let client = OpenAICompatibleClient(
            profile: .fake(baseURL: URL(string: "http://127.0.0.1:9/v1")!),
            apiKey: "sk-test",
            session: MidStreamFailingURLProtocol.session()
        )

        var thrown: Error?
        do {
            for try await _ in client.stream(.hello) {}
        } catch {
            thrown = error
        }

        guard case .transport = thrown as? ProviderError else {
            Issue.record("expected ProviderError.transport, got \(String(describing: thrown))")
            return
        }
    }

    /// URLSession reports our own task cancellation as `URLError(.cancelled)`,
    /// never as Swift's `CancellationError` — without normalization the
    /// cancellation guard is dead code and a dismissed suggestion logs as a
    /// failed LLM call (fix-review D2, proven against OSLogStore).
    @Test func urlSessionCancellationNormalizesToCancellationError() {
        #expect(OpenAICompatibleClient.mappedTransport(URLError(.cancelled)) is CancellationError)
    }

    @Test func realTransportFailuresStillMapToTypedTransport() {
        let mapped = OpenAICompatibleClient.mappedTransport(URLError(.cannotConnectToHost))

        guard case .transport = mapped as? ProviderError else {
            Issue.record("expected ProviderError.transport, got \(mapped)")
            return
        }
    }

    @Test func aConnectFailureOnStructuredCallsSurfacesAsTypedTransport() async throws {
        let client = OpenAICompatibleClient(
            profile: .fake(baseURL: URL(string: "http://127.0.0.1:9/v1")!),
            apiKey: "sk-test",
            session: ConnectFailingURLProtocol.session()
        )

        var thrown: Error?
        do {
            struct Reply: Codable { let answer: String }
            _ = try await client.complete(.hello, as: Reply.self)
        } catch {
            thrown = error
        }

        guard case .transport = thrown as? ProviderError else {
            Issue.record("expected ProviderError.transport, got \(String(describing: thrown))")
            return
        }
    }
}
