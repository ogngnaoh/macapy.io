import Foundation
import GRDB
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing

/// A ledger-write failure must never destroy a completed result (fix-review
/// D1). The provider already billed the call; eating a finished artifact — or
/// leaking a raw `GRDB.DatabaseError` through the `LLMProvider` contract —
/// over a bookkeeping row is the worse trade. Reproduced against the real
/// GRDB store by failing the ledger insert after valid durable admission.
/// A missing source now fails before dispatch; true in-flight deletion is
/// covered by BackgroundUsageStoreTests without a networked test server.
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
    ) async throws -> (server: FakeOpenAIServer, provider: MeteredProvider, store: SpendLedgerStore) {
        let server = try FakeOpenAIServer.start(responses: responses)
        let database = try MacapyDatabase.inMemory()
        let meeting = try await MeetingStore(database: database).beginMeeting(startedAt: Date(), ephemeral: false)
        try await database.dbWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER synthetic_booking_failure BEFORE INSERT ON spend_ledger BEGIN SELECT RAISE(ABORT,'synthetic settlement failure'); END")
        }
        let store = SpendLedgerStore(database: database)
        let meter = SpendMeter(ledger: store, pricing: PricingTable(rates: [:]), capUSD: nil)
        let provider = MeteredProvider(
            upstream: OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
            meter: meter,
            meetingID: meeting.id
        )
        return (server, provider, store)
    }

    @Test func aLedgerWriteFailureNeverDestroysAStreamedResult() async throws {
        let (server, provider, store) = try await fixture(responses: [
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
                "the synthetic settlement failure must not fabricate a ledger row")
    }

    @Test func aLedgerWriteFailureNeverDestroysAStructuredResult() async throws {
        let (server, provider, store) = try await fixture(responses: [
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
