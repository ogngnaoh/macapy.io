import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing

/// A ledger-write failure must never destroy a completed result (fix-review
/// D1). The provider already billed the call; eating a finished artifact — or
/// leaking a raw `GRDB.DatabaseError` through the `LLMProvider` contract —
/// over a bookkeeping row is the worse trade. Reproduced against the real
/// GRDB store with the exact state FR-013 creates: a per-meeting deletion
/// cascading while a call is in flight, so the `spend_ledger` insert fails
/// its `meetings` foreign key.
struct MeteredBookingFailureTests {

    private static var request: CompletionRequest {
        CompletionRequest(
            model: "fake-model",
            messages: [.user("hi")],
            purpose: .generation
        )
    }

    private func fixture(
        responses: [FakeOpenAIServer.Response]
    ) throws -> (server: FakeOpenAIServer, provider: MeteredProvider, store: SpendLedgerStore) {
        let server = try FakeOpenAIServer.start(responses: responses)
        let store = SpendLedgerStore(database: try MacapyDatabase.inMemory())
        let meter = SpendMeter(ledger: store, pricing: PricingTable(rates: [:]), capUSD: nil)
        // A meeting id with no `meetings` row: the FK on `spend_ledger` fails.
        let provider = MeteredProvider(
            upstream: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            meter: meter,
            meetingID: UUID()
        )
        return (server, provider, store)
    }

    @Test func aLedgerWriteFailureNeverDestroysAStreamedResult() async throws {
        let (server, provider, store) = try fixture(responses: [
            .sse(frames: [
                OpenAIFixtures.contentDelta("hello"),
                OpenAIFixtures.finish(reason: "stop", promptTokens: 100, completionTokens: 10),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }

        var events: [LLMEvent] = []
        for try await event in provider.stream(Self.request) { events.append(event) }

        #expect(events.contains(.token("hello")))
        #expect(events.contains { if case .completed = $0 { true } else { false } },
                "the completed result must outlive the bookkeeping failure")
        #expect(try await store.allEntries().isEmpty,
                "the meeting is gone; there is no valid row to write")
    }

    @Test func aLedgerWriteFailureNeverDestroysAStructuredResult() async throws {
        let (server, provider, store) = try fixture(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"answer":"yes"}"#,
                promptTokens: 200,
                completionTokens: 20
            ))
        ])
        defer { server.stop() }

        struct Reply: Codable, Equatable { let answer: String }
        let reply = try await provider.complete(Self.request, as: Reply.self)

        #expect(reply == Reply(answer: "yes"),
                "the decoded artifact must outlive the bookkeeping failure")
        #expect(try await store.allEntries().isEmpty)
    }
}
