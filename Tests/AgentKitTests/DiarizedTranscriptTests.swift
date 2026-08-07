import CaptureKit
import Foundation
import PersistKit
import ProviderTestSupport
import Testing
import TranscribeKit

@testable import AgentKit

/// Slice-4 check 8 (agent half): the extraction prompt renders diarized
/// speakers as S1/S2, unattributed them-lines as Them, mic as You — the
/// one-line boundary the slice plan named at PostMeetingAgent's transcript
/// build.
struct DiarizedTranscriptTests {

    @Test func extractionPromptCarriesDiarizedLabels() async throws {
        let harness = try await AgentHarness.start(transcript: [
            (.system, "If we cut over on the 3rd, the backfill must land first."),
            (.mic, "I can own the runbook."),
            (.system, "Shadow mode doubles our write load."),
            (.system, "Unattributed mumble in the back."),
        ])
        let segments = try await harness.meetings.segments(for: harness.meetingID)

        // S1 = the first system voice, S2 = the second; the last them-line
        // stays unattributed on purpose.
        let s1 = SpeakerRecord(id: UUID(), meetingID: harness.meetingID, label: "S1", embedding: nil)
        let s2 = SpeakerRecord(id: UUID(), meetingID: harness.meetingID, label: "S2", embedding: nil)
        try await harness.meetings.insertSpeakers([s1, s2])
        try await harness.meetings.assignSpeakers(
            [segments[0].id: s1.id, segments[2].id: s2.id],
            meetingID: harness.meetingID
        )

        let body = #"{"summary":"Cutover prep.","decisions":[],"action_items":[]}"#
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: body))
        ])
        defer { server.stop() }

        let outcome = await harness.agent(server: server).generateArtifacts(meetingID: harness.meetingID)
        guard case .drafted = outcome else {
            Issue.record("expected .drafted, got \(outcome)")
            return
        }

        let userMessages = server.recordedRequests.compactMap { request -> String? in
            (request.jsonBody?["messages"] as? [[String: Any]])?.last?["content"] as? String
        }
        let userMessage = try #require(userMessages.first)
        #expect(userMessage.contains("S1: If we cut over"))
        #expect(userMessage.contains("You: I can own the runbook."))
        #expect(userMessage.contains("S2: Shadow mode"))
        #expect(userMessage.contains("Them: Unattributed mumble"))
    }
}
