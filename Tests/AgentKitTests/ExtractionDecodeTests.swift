import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing

@testable import AgentKit

/// Acceptance check 2: malformed, truncated, and schema-violating extraction
/// payloads produce a typed failure and **zero** partial artifact rows — plus
/// the slice-2 open item ruled on here: a non-stop `finish_reason` on a
/// structured call is truncation, same bucket.
struct ExtractionDecodeTests {

    private func run(bodies: [FakeOpenAIServer.Response]) async throws
        -> (outcome: PostMeetingAgent.Outcome, rows: [ArtifactRecord])
    {
        let server = try FakeOpenAIServer.start(responses: bodies)
        defer { server.stop() }
        let harness = try await AgentHarness.start()
        let outcome = await harness.agent(server: server).generateArtifacts(meetingID: harness.meetingID)
        let rows = try await harness.artifacts.artifacts(for: harness.meetingID)
        return (outcome, rows)
    }

    @Test func aWellFormedPayloadLandsAsDraftRows() async throws {
        let (outcome, rows) = try await run(bodies: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json))
        ])

        guard case .drafted(let drafted) = outcome else {
            Issue.record("expected .drafted, got \(outcome)")
            return
        }
        #expect(drafted == rows)
        #expect(rows.map(\.artifactKind) == ExtractionFixture.expectedKinds())
        #expect(rows.allSatisfy { $0.artifactStatus == .draft })
        #expect(rows[0].payload(as: SummaryPayload.self)?.text
            == "The team planned the cutover and its guardrails.")
        #expect(rows[1].payload(as: DecisionPayload.self)?.text == "Cut over on Aug 3 behind a flag.")
        #expect(rows[2].payload(as: ActionItemPayload.self)
            == ActionItemPayload(title: "Draft the backfill runbook", owner: "You", deadline: "Thursday"))
        #expect(rows[3].payload(as: ActionItemPayload.self)
            == ActionItemPayload(title: "Share the reconciliation report", owner: nil, deadline: nil))
    }

    @Test func malformedPayloadFailsTypedWithZeroRows() async throws {
        let (outcome, rows) = try await run(bodies: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: "the model rambled prose"))
        ])

        guard case .failed(.some(.decodingFailed)) = outcome else {
            Issue.record("expected .failed(.decodingFailed), got \(outcome)")
            return
        }
        #expect(rows.isEmpty)
    }

    @Test func truncatedJSONPayloadFailsTypedWithZeroRows() async throws {
        let (outcome, rows) = try await run(bodies: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: #"{"summary":"we agr"#))
        ])

        guard case .failed(.some(.decodingFailed)) = outcome else {
            Issue.record("expected .failed(.decodingFailed), got \(outcome)")
            return
        }
        #expect(rows.isEmpty)
    }

    @Test func schemaViolatingPayloadFailsTypedWithZeroRows() async throws {
        let (outcome, rows) = try await run(bodies: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"summary":"fine","decisions":[]}"#))  // action_items missing
        ])

        guard case .failed(.some(.decodingFailed)) = outcome else {
            Issue.record("expected .failed(.decodingFailed), got \(outcome)")
            return
        }
        #expect(rows.isEmpty)
    }

    @Test func lengthFinishReasonFailsAsTruncationEvenWhenTheJSONParses() async throws {
        let (outcome, rows) = try await run(bodies: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: ExtractionFixture.json, finishReason: "length"))
        ])

        #expect(outcome == .failed(.truncated(finishReason: "length")))
        #expect(rows.isEmpty)
    }

    @Test func contentFilterFinishReasonFailsAsTruncation() async throws {
        let (outcome, rows) = try await run(bodies: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: ExtractionFixture.json, finishReason: "content_filter"))
        ])

        #expect(outcome == .failed(.truncated(finishReason: "content_filter")))
        #expect(rows.isEmpty)
    }

    @Test func serverErrorFailsTypedWithZeroRows() async throws {
        let (outcome, rows) = try await run(bodies: [
            .json(status: 503, body: OpenAIFixtures.errorBody(message: "overloaded"))
        ])

        #expect(outcome == .failed(.server(status: 503, message: "overloaded")))
        #expect(rows.isEmpty)
    }

    /// The request itself is the contract: deep model, strict schema by name,
    /// the transcript with You/Them attribution, and `Purpose.artifact`
    /// booked (spend integration half of decision 6).
    @Test func extractionRequestCarriesSchemaTranscriptAndBooksArtifactSpend() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json))
        ])
        defer { server.stop() }
        let harness = try await AgentHarness.start()

        _ = await harness.agent(server: server).generateArtifacts(meetingID: harness.meetingID)

        let body = try #require(server.recordedRequests.first?.jsonBody)
        #expect(body["model"] as? String == "fake-model")
        let format = try #require(body["response_format"] as? [String: Any])
        let jsonSchema = try #require(format["json_schema"] as? [String: Any])
        #expect(jsonSchema["name"] as? String == "meeting_extraction")
        #expect(jsonSchema["strict"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let user = try #require(messages.last?["content"] as? String)
        #expect(user.contains("You: I can own the runbook. Draft by Thursday."))
        #expect(user.contains("Them: If we cut over on the 3rd, the backfill must land first."))

        let entries = await harness.ledger.entries
        #expect(entries.count == 1)
        #expect(entries.first?.purpose == .artifact)
        #expect(entries.first?.meetingID == harness.meetingID)
        #expect((entries.first?.estCostUSD ?? 0) > 0)
    }
}
