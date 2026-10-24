import CaptureKit
import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing
import TranscribeKit

@testable import AgentKit

struct ArtifactRegenerationRaceTests {
    @Test func correctionArrivingBeforeGenerationCommitSurvivesAndReloads() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let artifacts = ArtifactStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await meetings.append([
            Segment(id: UUID(), source: .mic, text: "The release is Friday.", tStart: 0, tEnd: 2),
        ], to: meeting.id)
        try await meetings.endMeeting(id: meeting.id, endedAt: Date())
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"summary":"Model output","decisions":[],"action_items":[]}"#)),
        ])
        defer { server.stop() }
        let provider = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
        let agent = PostMeetingAgent(
            meetings: meetings, artifacts: artifacts,
            makeContext: { _ in PostMeetingProviderContext(provider: provider, model: "fake-model") },
            persistDrafts: { drafts, meetingID in
                // Deterministically interleave a second writer after the
                // pre-network check and before this generation's transaction.
                let row = try await artifacts.insertDrafts([
                    try DraftArtifact(kind: .summary, encoding: SummaryPayload(text: "earlier output")),
                ], meetingID: meetingID)[0]
                _ = try await artifacts.edit(id: row.id, expectedRevision: 0, content: .summary("Human correction"))
                return try await artifacts.insertDrafts(drafts, meetingID: meetingID)
            })
        let outcome = await agent.generateArtifacts(meetingID: meeting.id)
        #expect(outcome == .skippedExistingArtifacts)
        let rows = try await artifacts.artifacts(for: meeting.id)
        #expect(rows.count == 1)
        #expect(rows[0].payload(as: SummaryPayload.self)?.text == "Human correction")
        #expect(rows[0].isUserEdited)
        #expect(rows[0].revision == 1)
        #expect(server.recordedRequests.count == 1)
    }
}
