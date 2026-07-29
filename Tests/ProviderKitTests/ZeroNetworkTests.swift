import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// Acceptance check 7: with no provider configured, no code path constructs a
/// network request — the unit-level regression for PRD G4 / SPEC G6 ("a meeting
/// can be run end-to-end with zero network traffic at all").
///
/// `.serialized` because `RecordingURLProtocol` counts requests process-wide.
@Suite(.serialized)
struct ZeroNetworkTests {

    private func registry(keys: [String: String] = [:]) -> ProviderRegistry {
        RecordingURLProtocol.reset()
        return ProviderRegistry(
            credentials: InMemoryCredentialStore(keys: keys),
            session: RecordingURLProtocol.session()
        )
    }

    @Test func noProfileSelectedYieldsNoClientAndNoRequest() throws {
        let registry = registry()

        let client = try registry.client(for: ProviderSettings())

        #expect(client == nil, "unconfigured must resolve to no client at all")
        #expect(RecordingURLProtocol.recordedRequests.isEmpty)
    }

    @Test func selectedProfileWithoutAKeyStaysQuietRatherThanFailingLoudly() throws {
        // PRD edge case: "No AI credentials configured → AI surfaces show a
        // quiet setup prompt, never an error."
        let registry = registry()

        let client = try registry.client(for: ProviderSettings(selectedProfileID: "deepseek"))

        #expect(client == nil)
        #expect(RecordingURLProtocol.recordedRequests.isEmpty)
    }

    @Test func keylessLocalProfileNeedsNoCredentialToResolve() throws {
        // Ollama requires no key; "configured" must not mean "has a key".
        let registry = registry()

        let client = try registry.client(for: ProviderSettings(selectedProfileID: "ollama"))

        #expect(client != nil)
        #expect(RecordingURLProtocol.recordedRequests.isEmpty, "resolving a client must not itself call out")
    }

    /// The guard above would pass vacuously if the registry never produced a
    /// working client. This is the other half: configured *does* reach the
    /// network, exactly once, and only then.
    @Test func aConfiguredProfileDoesReachTheNetworkWhenItStreams() async throws {
        let registry = registry(keys: ["deepseek": "sk-test"])
        let client = try #require(try registry.client(for: ProviderSettings(selectedProfileID: "deepseek")))

        // `RecordingURLProtocol` refuses every request, so this always throws;
        // what's under test is that a request got constructed and attempted.
        do { for try await _ in client.stream(.hello) {} } catch {}

        #expect(RecordingURLProtocol.recordedRequests.count == 1)
        #expect(RecordingURLProtocol.recordedRequests.first?.url?.absoluteString
            == "https://api.deepseek.com/v1/chat/completions")
    }
}
