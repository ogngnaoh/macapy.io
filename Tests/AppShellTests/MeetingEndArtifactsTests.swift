import CaptureKit
import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing
import TranscribeKit

@testable import AppShell

/// Acceptance checks 1 and 7, end-to-end through the shell: a real
/// `AppShellCoordinator` + `MeetingPipeline` (fake engine/capture, fake
/// OpenAI server) ends a meeting and draft artifacts land — or, for
/// ephemeral/unconfigured meetings, provably don't.
@MainActor
struct MeetingEndArtifactsTests {

    private struct Shell {
        let coordinator: AppShellCoordinator
        let database: MacapyDatabase
    }

    /// A coordinator whose provider catalog is one fake profile aimed at
    /// `server`, keyed via an in-memory credential store — the production
    /// wiring with the network and Keychain swapped out at the same seams the
    /// app uses.
    private func makeShell(
        server: FakeOpenAIServer?,
        configureProvider: Bool = true
    ) async throws -> Shell {
        let database = try MacapyDatabase.inMemory()
        let counters = MeetingPipelineTests.Counters()
        let engine = MeetingPipelineTests.FakeSTTEngine(
            live: [
                .mic: [.final(Segment(
                    id: UUID(), source: .mic,
                    text: "I can own the runbook. Draft by Thursday.",
                    tStart: 0, tEnd: 1))],
                .system: [.final(Segment(
                    id: UUID(), source: .system,
                    text: "Cut over on the 3rd once the backfill lands.",
                    tStart: 1, tEnd: 2))],
            ],
            counters: counters)
        let mic = MeetingPipelineTests.FakeCaptureSource(source: .mic, counters: counters)
        let system = MeetingPipelineTests.FakeCaptureSource(source: .system, counters: counters)
        let coordinator = AppShellCoordinator(
            panel: MeetingPipelineTests.FakePanel(),
            installHotKey: false,
            makePipeline: { store in
                MeetingPipeline(engine: engine, sources: [mic, system], store: store)
            },
            makeDatabase: { database },
            providerProfiles: server.map { [.fake(baseURL: $0.baseURL)] } ?? [],
            credentials: InMemoryCredentialStore(keys: ["fake": "sk-test"])
        )
        if configureProvider, server != nil {
            let settings = try #require(coordinator.settingsStore())
            try await settings.setProviderSettings(ProviderSettings(selectedProfileID: "fake"))
        }
        return Shell(coordinator: coordinator, database: database)
    }

    private func runOneMeeting(_ shell: Shell, ephemeral: Bool = false) async {
        shell.coordinator.ephemeralNextMeeting = ephemeral
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
    }

    /// Check 1: meeting end → extraction request issued → artifact rows in
    /// `draft` with the scripted kinds and payloads, booked as `artifact`
    /// spend.
    @Test func meetingEndDraftsArtifactsThroughTheFullShell() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"summary":"Cutover planned behind the backfill.","decisions":["Cut over on the 3rd."],"action_items":[{"title":"Draft the runbook","owner":"You","deadline":"Thursday"}]}"#
            ))
        ])
        defer { server.stop() }
        let shell = try await makeShell(server: server)

        await runOneMeeting(shell)

        let meetings = try #require(shell.coordinator.historyStore())
        let meeting = try #require(try await meetings.listMeetings().first)
        let artifacts = try #require(shell.coordinator.artifactStore())
        let rows = try await artifacts.artifacts(for: meeting.id)
        #expect(rows.map(\.artifactKind) == [.summary, .decision, .actionItem])
        #expect(rows.allSatisfy { $0.artifactStatus == .draft })
        #expect(rows[0].payload(as: SummaryPayload.self)?.text == "Cutover planned behind the backfill.")
        #expect(rows[2].payload(as: ActionItemPayload.self)
            == ActionItemPayload(title: "Draft the runbook", owner: "You", deadline: "Thursday"))

        // The one extraction request actually went over the wire, transcript
        // attributed, and was booked to this meeting as artifact spend.
        #expect(server.recordedRequests.count == 1)
        let user = try #require(
            (server.recordedRequests.first?.jsonBody?["messages"] as? [[String: Any]])?
                .last?["content"] as? String)
        #expect(user.contains("You: I can own the runbook. Draft by Thursday."))
        #expect(user.contains("Them: Cut over on the 3rd once the backfill lands."))
        let ledger = try #require(shell.coordinator.spendLedger())
        let spend = try await ledger.entries(meetingID: meeting.id)
        #expect(spend.map(\.purpose) == [.artifact])
    }

    /// Check 7: an ephemeral meeting triggers nothing — no request, no
    /// artifact row, and (the M1 invariant, still true) no meeting row.
    @Test func ephemeralMeetingNeverTriggersExtraction() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixtureBody.minimal))
        ])
        defer { server.stop() }
        let shell = try await makeShell(server: server)

        await runOneMeeting(shell, ephemeral: true)

        #expect(server.recordedRequests.isEmpty)
        let meetings = try #require(shell.coordinator.historyStore())
        #expect(try await meetings.listMeetings().isEmpty)
        let artifactCount = try await shell.database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifacts") ?? -1
        }
        #expect(artifactCount == 0)
    }

    /// Check 5's shell half: no provider configured ⇒ the meeting ends
    /// normally, stays artifacts-pending (zero rows), and nothing crashes.
    /// The retroactive generate over the same path is proven in
    /// `PostMeetingAgentTests`; its UI entry point in `MeetingDetailModelTests`.
    @Test func unconfiguredProviderLeavesTheMeetingArtifactsPending() async throws {
        let shell = try await makeShell(server: nil, configureProvider: false)

        await runOneMeeting(shell)

        let meetings = try #require(shell.coordinator.historyStore())
        let meeting = try #require(try await meetings.listMeetings().first)
        #expect(meeting.status == "ended")
        #expect(try await meetings.segments(for: meeting.id).count == 2)
        let artifacts = try #require(shell.coordinator.artifactStore())
        #expect(try await artifacts.artifacts(for: meeting.id).isEmpty)
    }
}

/// Minimal valid extraction body for tests that only need *a* response.
private enum ExtractionFixtureBody {
    static let minimal = #"{"summary":"s","decisions":[],"action_items":[]}"#
}
