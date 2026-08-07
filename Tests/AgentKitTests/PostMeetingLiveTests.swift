import CaptureKit
import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing
import TranscribeKit

@testable import AgentKit

/// Live checks 9 and 11 (slice-03, re-expressed 2026-08-06 under the
/// no-manual-checks ruling): the real extraction path against the real
/// DeepSeek endpoint. Skipped, never failed, without the key — see
/// `LiveCredentials`. Spends a fraction of a cent of the author's credit per
/// run, booked through the same metered chain as production.
@Suite(.enabled(if: LiveCredentials.hasDeepSeek))
struct PostMeetingLiveTests {

    /// A fixture meeting with *unambiguous* ground truth: one explicitly
    /// agreed decision, and action items with named owners and stated
    /// deadlines. Assertions bound LLM nondeterminism by checking this core,
    /// never exact payloads (check 9's wording).
    private static let fixtureTranscript: [(source: AudioSource, text: String)] = [
        (.system, "Okay, the only real question today is the beta date."),
        (.mic, "Engineering is ready. I'd say we commit."),
        (.system, "Then let's decide it: the beta ships on September 1st. Agreed?"),
        (.mic, "Agreed, September 1st it is."),
        (.system, "Priya, can you have the staging environment set up by next Wednesday?"),
        (.system, "Priya here - yes, staging will be ready by next Wednesday."),
        (.system, "And Marcus will draft the pricing page copy, due Friday."),
        (.system, "Marcus speaking - fine, pricing copy by Friday."),
        (.mic, "I'll write the release notes by Monday."),
        (.system, "Great. That's everything - see you all at standup."),
    ]

    private struct LiveHarness {
        let meetings: MeetingStore
        let artifacts: ArtifactStore
        let ledger: InMemorySpendLedger
        let meetingID: UUID

        /// The production chain against first-party DeepSeek (author ruling
        /// 2026-07-29: real transcripts route to DeepSeek knowingly), deep
        /// tier, metered with real default pricing.
        func agent(key: String, profile: EndpointProfile = .deepSeek) -> PostMeetingAgent {
            let ledger = ledger
            return PostMeetingAgent(meetings: meetings, artifacts: artifacts) { meetingID in
                let client = OpenAICompatibleClient(profile: profile, apiKey: key)
                let meter = SpendMeter(ledger: ledger, pricing: .defaults, capUSD: nil)
                return PostMeetingProviderContext(
                    provider: MeteredProvider(upstream: client, meter: meter, meetingID: meetingID),
                    model: profile.deepModel)
            }
        }
    }

    private func makeHarness() async throws -> LiveHarness {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let artifacts = ArtifactStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        let segments = Self.fixtureTranscript.enumerated().map { index, line in
            Segment(
                id: UUID(), source: line.source, text: line.text,
                tStart: Double(index * 5), tEnd: Double(index * 5) + 4)
        }
        try await meetings.append(segments, to: meeting.id)
        try await meetings.endMeeting(id: meeting.id, endedAt: Date())
        return LiveHarness(
            meetings: meetings, artifacts: artifacts,
            ledger: InMemorySpendLedger(), meetingID: meeting.id)
    }

    /// Check 9: fixture ground truth through the real path, schema-valid
    /// draft rows, G3 wall time < 60s (the number is printed for the
    /// milestone record).
    @Test func liveExtractionDraftsTheUnambiguousCoreWithinSixtySeconds() async throws {
        let key = try #require(LiveCredentials.deepSeekKey)
        let harness = try await makeHarness()
        let agent = harness.agent(key: key)

        let startedAt = Date()
        let outcome = await agent.generateArtifacts(meetingID: harness.meetingID)
        let wallSeconds = Date().timeIntervalSince(startedAt)
        print("G3 live wall time: \(String(format: "%.1f", wallSeconds))s (trigger to last artifact row)")

        guard case .drafted(let rows) = outcome else {
            Issue.record("live extraction did not draft: \(outcome)")
            return
        }
        #expect(wallSeconds < 60, "G3: meeting end to artifacts must be under 60s")

        // Schema-valid rows, all draft.
        #expect(rows.allSatisfy { $0.artifactStatus == .draft })
        let summaries = rows.filter { $0.artifactKind == .summary }
        #expect(summaries.count == 1)
        #expect(summaries.first?.payload(as: SummaryPayload.self)?.text.isEmpty == false)

        // The explicitly agreed decision appears.
        let decisionTexts = rows.filter { $0.artifactKind == .decision }
            .compactMap { $0.payload(as: DecisionPayload.self)?.text.lowercased() }
        #expect(!decisionTexts.isEmpty, "the fixture's one explicit decision was not extracted")
        #expect(
            decisionTexts.contains { $0.contains("september") || $0.contains("sept") },
            "no decision mentions the agreed September date: \(decisionTexts)")

        // Named owners and stated deadlines survive extraction (FR-008).
        let items = rows.filter { $0.artifactKind == .actionItem }
            .compactMap { $0.payload(as: ActionItemPayload.self) }
        func item(ownedBy name: String) -> ActionItemPayload? {
            items.first { $0.owner?.lowercased().contains(name) == true }
        }
        let priya = try #require(item(ownedBy: "priya"), "Priya's staging item is missing: \(items)")
        #expect(priya.deadline?.lowercased().contains("wednesday") == true)
        let marcus = try #require(item(ownedBy: "marcus"), "Marcus's pricing item is missing: \(items)")
        #expect(marcus.deadline?.lowercased().contains("friday") == true)
        let releaseNotes = items.first {
            $0.title.lowercased().contains("release notes") || $0.deadline?.lowercased().contains("monday") == true
        }
        #expect(releaseNotes != nil, "the user's release-notes commitment is missing: \(items)")

        // Booked through the metered chain with real usage and a real rate.
        let spend = await harness.ledger.entries
        #expect(spend.allSatisfy { $0.purpose == .artifact })
        #expect(!spend.isEmpty)
        #expect(spend.allSatisfy { ($0.estCostUSD ?? 0) > 0 })
    }

    /// Check 11: extraction against a dead local port fails typed and leaves
    /// the meeting artifacts-pending; the retroactive generate against live
    /// DeepSeek then drafts via the same path. Deterministic stand-in for
    /// "meeting ended with the network off".
    @Test func deadEndpointLeavesPendingThenLiveGenerateRecovers() async throws {
        let key = try #require(LiveCredentials.deepSeekKey)
        let harness = try await makeHarness()

        // TCP port 9 (discard) on loopback: nothing listens there — an
        // immediate, deterministic connection refusal.
        let deadProfile = EndpointProfile(
            id: "dead",
            displayName: "Dead endpoint",
            baseURL: URL(string: "http://127.0.0.1:9/v1")!,
            fastModel: "none",
            deepModel: "none")
        let deadOutcome = await harness.agent(key: key, profile: deadProfile)
            .generateArtifacts(meetingID: harness.meetingID)

        guard case .failed(.some(.transport)) = deadOutcome else {
            Issue.record("expected a typed transport failure, got \(deadOutcome)")
            return
        }
        #expect(try await harness.artifacts.artifacts(for: harness.meetingID).isEmpty,
            "a failed extraction must leave zero artifact rows (pending state)")
        #expect(try await harness.meetings.meeting(id: harness.meetingID)?.hasEnded == true)

        let liveOutcome = await harness.agent(key: key).generateArtifacts(meetingID: harness.meetingID)
        guard case .drafted(let rows) = liveOutcome else {
            Issue.record("retroactive live generate did not draft: \(liveOutcome)")
            return
        }
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.artifactStatus == .draft })
    }
}
