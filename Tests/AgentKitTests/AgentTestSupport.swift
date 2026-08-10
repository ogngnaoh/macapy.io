import CaptureKit
import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import TranscribeKit

@testable import AgentKit

/// One in-memory database with a persisted meeting + transcript, and an agent
/// pointed at a `FakeOpenAIServer` through the same metered provider chain the
/// app wires (V5): `OpenAICompatibleClient` → `SpendMeter` → `MeteredProvider`.
struct AgentHarness {
    let database: MacapyDatabase
    let meetings: MeetingStore
    let artifacts: ArtifactStore
    let ledger: InMemorySpendLedger
    let meetingID: UUID

    /// A rate for `fake-model` so booked calls cost money and the cap can trip.
    static let pricing = PricingTable(rates: [
        "fake-model": ModelPricing(
            inputPerMillionUSD: 1.0, cachedInputPerMillionUSD: 0.1, outputPerMillionUSD: 2.0)
    ])

    static func start(
        transcript: [(source: AudioSource, text: String)] = [
            (.system, "If we cut over on the 3rd, the backfill must land first."),
            (.mic, "I can own the runbook. Draft by Thursday."),
            (.system, "Agreed - flag stays off until reconciliation passes."),
        ],
        ephemeral: Bool = false
    ) async throws -> AgentHarness {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let artifacts = ArtifactStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: ephemeral)
        let segments = transcript.enumerated().map { index, line in
            Segment(
                id: UUID(),
                source: line.source,
                text: line.text,
                tStart: Double(index),
                tEnd: Double(index) + 0.9)
        }
        try await meetings.append(segments, to: meeting.id)
        try await meetings.endMeeting(id: meeting.id, endedAt: Date())
        return AgentHarness(
            database: database,
            meetings: meetings,
            artifacts: artifacts,
            ledger: InMemorySpendLedger(),
            meetingID: meeting.id)
    }

    /// An agent whose provider context is the app's real chain against the
    /// fake server. `capUSD` non-nil makes the meter capped (check 6).
    func agent(
        server: FakeOpenAIServer,
        capUSD: Double? = nil,
        chunkBudgetCharacters: Int = 60_000
    ) -> PostMeetingAgent {
        let ledger = ledger
        let baseURL = server.baseURL
        return PostMeetingAgent(
            meetings: meetings,
            artifacts: artifacts,
            chunkBudgetCharacters: chunkBudgetCharacters
        ) { meetingID in
            let client = OpenAICompatibleClient(profile: .fake(baseURL: baseURL), apiKey: "sk-test")
            let meter = SpendMeter(ledger: ledger, pricing: Self.pricing, capUSD: capUSD)
            return PostMeetingProviderContext(
                provider: MeteredProvider(upstream: client, meter: meter, meetingID: meetingID),
                model: "fake-model")
        }
    }

    /// An agent for the unconfigured state: context resolves to `nil`, the
    /// same non-answer `ProviderRegistry.client(for:)` gives with no key.
    func agentWithoutProvider() -> PostMeetingAgent {
        PostMeetingAgent(meetings: meetings, artifacts: artifacts) { _ in nil }
    }
}

/// A wire-correct extraction payload with unambiguous content, reused across
/// suites so assertions read against one fixture.
enum ExtractionFixture {
    static let json = """
        {"summary":"The team planned the cutover and its guardrails.",\
        "decisions":["Cut over on Aug 3 behind a flag."],\
        "action_items":[\
        {"title":"Draft the backfill runbook","owner":"You","deadline":"Thursday"},\
        {"title":"Share the reconciliation report","owner":null,"deadline":null}]}
        """

    /// The draft rows that payload must become, as (kind, decoded payload).
    static func expectedKinds() -> [ArtifactKind] {
        [.summary, .decision, .actionItem, .actionItem]
    }
}

/// Lets lifecycle tests hold the first completed fake-server response before
/// it reaches AgentKit's persistence checkpoint. Cancellation interrupts the
/// sleep; later retry calls pass straight through.
final class DelayFirstCompletionProvider: LLMProvider, @unchecked Sendable {
    private let upstream: any LLMProvider
    private let lock = NSLock()
    private var shouldDelay = true

    init(upstream: any LLMProvider) {
        self.upstream = upstream
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        upstream.stream(request)
    }

    func completeReportingUsage<T: Decodable>(
        _ request: CompletionRequest,
        as type: T.Type
    ) async throws -> CompletedCall<T> {
        let completed = try await upstream.completeReportingUsage(request, as: type)
        let delay = lock.withLock {
            defer { shouldDelay = false }
            return shouldDelay
        }
        if delay { try await Task.sleep(for: .seconds(30)) }
        return completed
    }
}
