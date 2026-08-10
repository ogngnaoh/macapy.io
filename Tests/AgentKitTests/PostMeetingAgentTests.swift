import CaptureKit
import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing

@testable import AgentKit

private actor ProviderContextGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    private var released = false

    func suspendUntilReleased() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor AsyncFlag {
    private(set) var isSet = false

    func set() {
        isSet = true
    }
}

/// The agent's paths beyond decode: chunked map-reduce (check 4), the
/// retroactive/no-provider path (check 5), the cap gate (check 6), and the
/// skip guards (check 7's unit half).
struct PostMeetingAgentTests {

    // MARK: - Chunked map-reduce (check 4)

    /// A 3h-scale synthetic transcript against the *default* 60k budget:
    /// extraction completes via map-reduce without error, and the map/reduce
    /// request count matches the chunker's own arithmetic.
    @Test func threeHourScaleTranscriptCompletesViaMapReduce() async throws {
        // ~2,160 turns (one per 5s for 3h), ~120 chars each ⇒ ~260k chars.
        let turns: [(source: AudioSource, text: String)] = (0..<2_160).map { index in
            (
                index.isMultiple(of: 3) ? AudioSource.mic : .system,
                "Turn \(index): the reconciliation dashboard still shows drift in the ledger totals after the backfill run."
            )
        }
        let harness = try await AgentHarness.start(transcript: turns)

        let rendered = turns.map { "\($0.source == .mic ? "You" : "Them"): \($0.text)" }
        let expectedChunks = TranscriptChunker.chunks(rendered, budgetCharacters: 60_000).count
        #expect(expectedChunks > 1, "fixture must actually exercise the chunked path")

        let partial = #"{"summary":"Part covered drift.","decisions":[],"action_items":[]}"#
        let merged = #"{"summary":"Ledger drift dominated all three hours.","decisions":["Rerun the backfill."],"action_items":[]}"#
        let server = try FakeOpenAIServer.start(
            responses: (0..<expectedChunks).map { _ in
                .json(status: 200, body: OpenAIFixtures.completionBody(content: partial))
            } + [.json(status: 200, body: OpenAIFixtures.completionBody(content: merged))])
        defer { server.stop() }

        let outcome = await harness.agent(server: server).generateArtifacts(meetingID: harness.meetingID)

        guard case .drafted(let rows) = outcome else {
            Issue.record("expected .drafted, got \(outcome)")
            return
        }
        #expect(server.recordedRequests.count == expectedChunks + 1)
        #expect(rows.map(\.artifactKind) == [.summary, .decision])
        #expect(rows[0].payload(as: SummaryPayload.self)?.text == "Ledger drift dominated all three hours.")
    }

    /// The shape of the cascade, at a budget small enough to read: every part
    /// prompt names its position, and the final request merges the partials.
    @Test func mapRequestsCarryPartPositionsAndReduceCarriesThePartials() async throws {
        let turns: [(source: AudioSource, text: String)] = (0..<12).map { index in
            (.system, "Utterance number \(index) padding the transcript out.")
        }
        let harness = try await AgentHarness.start(transcript: turns)
        let rendered = turns.map { "Them: \($0.text)" }
        let expectedChunks = TranscriptChunker.chunks(rendered, budgetCharacters: 160).count
        #expect(expectedChunks > 1)

        let partial = #"{"summary":"partial","decisions":[],"action_items":[]}"#
        let merged = #"{"summary":"merged","decisions":[],"action_items":[]}"#
        let server = try FakeOpenAIServer.start(
            responses: (0..<expectedChunks).map { _ in
                .json(status: 200, body: OpenAIFixtures.completionBody(content: partial))
            } + [.json(status: 200, body: OpenAIFixtures.completionBody(content: merged))])
        defer { server.stop() }

        let outcome = await harness
            .agent(server: server, chunkBudgetCharacters: 160)
            .generateArtifacts(meetingID: harness.meetingID)

        guard case .drafted = outcome else {
            Issue.record("expected .drafted, got \(outcome)")
            return
        }
        let userMessages = server.recordedRequests.compactMap { request -> String? in
            (request.jsonBody?["messages"] as? [[String: Any]])?.last?["content"] as? String
        }
        #expect(userMessages.count == expectedChunks + 1)
        #expect(server.recordedRequests.allSatisfy {
            $0.jsonBody?["max_tokens"] as? Int == PostMeetingExtractor.maxOutputTokens
        }, "every map and reduce request must carry the explicit output ceiling")
        // Map calls run concurrently, so parts arrive in any order — but each
        // position 1...n must appear exactly once.
        let mapMessages = userMessages.dropLast()
        for part in 1...expectedChunks {
            #expect(
                mapMessages.filter { $0.contains("part \(part) of \(expectedChunks)") }.count == 1,
                "part \(part) prompt missing or duplicated")
        }
        let reduce = try #require(userMessages.last)
        #expect(reduce.contains("partial extractions"))
        #expect(reduce.contains(#""summary":"partial""#))
    }

    /// One failed chunk fails the whole extraction typed, with zero rows —
    /// never a merge over partial coverage.
    @Test func aFailedChunkFailsTheWholeExtractionWithZeroRows() async throws {
        let turns: [(source: AudioSource, text: String)] = (0..<12).map { index in
            (.system, "Utterance number \(index) padding the transcript out.")
        }
        let harness = try await AgentHarness.start(transcript: turns)
        let partial = #"{"summary":"partial","decisions":[],"action_items":[]}"#
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: partial)),
            .json(status: 500, body: OpenAIFixtures.errorBody(message: "boom")),
        ])
        defer { server.stop() }

        let outcome = await harness
            .agent(server: server, chunkBudgetCharacters: 160)
            .generateArtifacts(meetingID: harness.meetingID)

        guard case .failed(.some(let error)) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(error == .server(status: 500, message: "boom"))
        #expect(try await harness.artifacts.artifacts(for: harness.meetingID).isEmpty)
    }

    // MARK: - Retroactive path (check 5)

    @Test func noProviderLeavesMeetingPendingThenRetroactiveGenerateMatchesTheAutomaticPath() async throws {
        // Attempt with no provider: pending, no crash, zero rows.
        let harness = try await AgentHarness.start()
        let pending = await harness.agentWithoutProvider().generateArtifacts(meetingID: harness.meetingID)
        #expect(pending == .skippedNoProvider)
        #expect(try await harness.artifacts.artifacts(for: harness.meetingID).isEmpty)

        // The automatic path on an identical meeting, for comparison.
        let automaticHarness = try await AgentHarness.start()
        let automaticServer = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json))
        ])
        defer { automaticServer.stop() }
        let automatic = await automaticHarness
            .agent(server: automaticServer)
            .generateArtifacts(meetingID: automaticHarness.meetingID)
        guard case .drafted(let automaticRows) = automatic else {
            Issue.record("automatic path did not draft: \(automatic)")
            return
        }

        // Retroactive generate on the pending meeting, once a provider exists.
        let retroServer = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json))
        ])
        defer { retroServer.stop() }
        let retroactive = await harness.agent(server: retroServer).generateArtifacts(meetingID: harness.meetingID)
        guard case .drafted(let retroRows) = retroactive else {
            Issue.record("retroactive path did not draft: \(retroactive)")
            return
        }

        // Same artifacts, modulo identity columns: kind/payload/status match 1:1.
        #expect(retroRows.map { [$0.kind, $0.payload, $0.status] }
            == automaticRows.map { [$0.kind, $0.payload, $0.status] })
    }

    // MARK: - Cap gate (check 6)

    @Test func capReachedIssuesNoRequestAndLeavesTranscriptIntact() async throws {
        let harness = try await AgentHarness.start()
        // Pre-spend past the cap on this meeting.
        try await harness.ledger.record(SpendEntry(
            id: UUID(),
            meetingID: harness.meetingID,
            model: "fake-model",
            usage: TokenUsage(promptTokens: 1_000, completionTokens: 1_000),
            estCostUSD: 0.30,
            purpose: .generation,
            at: Date()))
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json))
        ])
        defer { server.stop() }
        let segmentsBefore = try await harness.meetings.segments(for: harness.meetingID)

        let outcome = await harness
            .agent(server: server, capUSD: 0.25)
            .generateArtifacts(meetingID: harness.meetingID)

        #expect(outcome == .halted(spentUSD: 0.30, capUSD: 0.25))
        #expect(server.recordedRequests.isEmpty, "a capped extraction must not even build a request")
        #expect(try await harness.artifacts.artifacts(for: harness.meetingID).isEmpty)
        #expect(try await harness.meetings.segments(for: harness.meetingID) == segmentsBefore)
        #expect(try await harness.meetings.meeting(id: harness.meetingID) != nil)
    }

    // MARK: - Skip guards

    @Test func ephemeralMeetingIsNeverExtracted() async throws {
        let harness = try await AgentHarness.start(ephemeral: true)
        let server = try FakeOpenAIServer.start(responses: [])
        defer { server.stop() }

        let outcome = await harness.agent(server: server).generateArtifacts(meetingID: harness.meetingID)

        #expect(outcome == .skippedEphemeral)
        #expect(server.recordedRequests.isEmpty)
        #expect(try await harness.artifacts.artifacts(for: harness.meetingID).isEmpty)
    }

    @Test func emptyTranscriptSkipsWithoutACall() async throws {
        let harness = try await AgentHarness.start(transcript: [])
        let server = try FakeOpenAIServer.start(responses: [])
        defer { server.stop() }

        let outcome = await harness.agent(server: server).generateArtifacts(meetingID: harness.meetingID)

        #expect(outcome == .skippedEmptyTranscript)
        #expect(server.recordedRequests.isEmpty)
    }

    @Test func existingArtifactsAreNeverSilentlyRegenerated() async throws {
        let harness = try await AgentHarness.start()
        try await harness.artifacts.insertDrafts(
            [try DraftArtifact(kind: .summary, encoding: SummaryPayload(text: "already here"))],
            meetingID: harness.meetingID)
        let server = try FakeOpenAIServer.start(responses: [])
        defer { server.stop() }

        let outcome = await harness.agent(server: server).generateArtifacts(meetingID: harness.meetingID)

        #expect(outcome == .skippedExistingArtifacts)
        #expect(server.recordedRequests.isEmpty)
        #expect(try await harness.artifacts.artifacts(for: harness.meetingID).count == 1)
    }

    /// Actor reentrancy: two generations racing for one meeting (the
    /// meeting-end trigger vs. the detail pane's button) must produce exactly
    /// one extraction call and one set of rows.
    @Test func concurrentGenerationsForOneMeetingDraftExactlyOnce() async throws {
        let harness = try await AgentHarness.start()
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json))
        ])
        defer { server.stop() }
        let agent = harness.agent(server: server)

        async let first = agent.generateArtifacts(meetingID: harness.meetingID)
        async let second = agent.generateArtifacts(meetingID: harness.meetingID)
        let outcomes = await [first, second]

        let drafted = outcomes.filter { if case .drafted = $0 { true } else { false } }
        #expect(drafted.count == 1, "exactly one racer must draft; got \(outcomes)")
        #expect(server.recordedRequests.count == 1)
        #expect(try await harness.artifacts.artifacts(for: harness.meetingID).count
            == ExtractionFixture.expectedKinds().count)
    }

    @Test func successfulGenerationRecordsTheG3WallTime() async throws {
        let harness = try await AgentHarness.start()
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json))
        ])
        defer { server.stop() }
        let agent = harness.agent(server: server)

        _ = await agent.generateArtifacts(meetingID: harness.meetingID)

        let recorded = await agent.lastDraftedInSeconds
        #expect(recorded != nil)
        #expect((recorded ?? -1) >= 0)
    }

    @Test func globalAIOffCancelsManualGenerationBeforePersistenceAndAllowsRetry() async throws {
        let harness = try await AgentHarness.start()
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json)),
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json)),
        ])
        defer { server.stop() }
        let upstream = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
        let delayed = DelayFirstCompletionProvider(upstream: upstream)
        let agent = PostMeetingAgent(meetings: harness.meetings, artifacts: harness.artifacts) { _ in
            PostMeetingProviderContext(provider: delayed, model: "fake-model")
        }

        let attempt = Task { await agent.generateArtifacts(meetingID: harness.meetingID) }
        for _ in 0..<300 where server.recordedRequests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.recordedRequests.count == 1)
        await agent.setGenerationEnabled(false)

        #expect(await attempt.value == .cancelled)
        #expect(try await harness.artifacts.artifacts(for: harness.meetingID).isEmpty)

        await agent.setGenerationEnabled(true)
        let retry = await agent.generateArtifacts(meetingID: harness.meetingID)
        guard case .drafted = retry else {
            Issue.record("cancelled generation should stay retryable, got \(retry)")
            return
        }
        #expect(server.recordedRequests.count == 2)
    }

    @Test func globalAIOffDuringProviderAdmissionMakesZeroRequestsAndRemainsRetryable() async throws {
        let harness = try await AgentHarness.start()
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json)),
        ])
        defer { server.stop() }
        let gate = ProviderContextGate()
        let agent = PostMeetingAgent(meetings: harness.meetings, artifacts: harness.artifacts) { _ in
            await gate.suspendUntilReleased()
            return PostMeetingProviderContext(
                provider: OpenAICompatibleClient(
                    profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
                model: "fake-model"
            )
        }

        let attempt = Task { await agent.generateArtifacts(meetingID: harness.meetingID) }
        for _ in 0..<300 {
            if await gate.entered { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.entered)
        await agent.setGenerationEnabled(false)
        await gate.release()

        #expect(await attempt.value == .cancelled)
        #expect(server.recordedRequests.isEmpty)
        #expect(try await harness.artifacts.artifacts(for: harness.meetingID).isEmpty)

        await agent.setGenerationEnabled(true)
        guard case .drafted = await agent.generateArtifacts(meetingID: harness.meetingID) else {
            Issue.record("AI-off admission cancellation must remain retryable")
            return
        }
        #expect(server.recordedRequests.count == 1)
    }

    @Test func rapidAIOffThenOnCannotResurrectAnAdmittedOldAttempt() async throws {
        let harness = try await AgentHarness.start()
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json)),
        ])
        defer { server.stop() }
        let gate = ProviderContextGate()
        let agent = PostMeetingAgent(meetings: harness.meetings, artifacts: harness.artifacts) { _ in
            await gate.suspendUntilReleased()
            return PostMeetingProviderContext(
                provider: OpenAICompatibleClient(
                    profile: .fake(baseURL: server.baseURL), apiKey: "sk-test"),
                model: "fake-model"
            )
        }

        let oldAttempt = Task { await agent.generateArtifacts(meetingID: harness.meetingID) }
        for _ in 0..<300 {
            if await gate.entered { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.entered)
        await agent.setGenerationEnabled(false)
        await agent.setGenerationEnabled(true)
        await gate.release()

        #expect(await oldAttempt.value == .cancelled)
        #expect(server.recordedRequests.isEmpty)
        #expect(try await harness.artifacts.artifacts(for: harness.meetingID).isEmpty)

        guard case .drafted = await agent.generateArtifacts(meetingID: harness.meetingID) else {
            Issue.record("a fresh post-toggle attempt should draft")
            return
        }
        #expect(server.recordedRequests.count == 1)
    }

    @Test func globalAIOffDrainsAnUninterruptiblePersistenceBoundaryBeforeReturning() async throws {
        let harness = try await AgentHarness.start()
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json)),
        ])
        defer { server.stop() }
        let upstream = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
        let persistenceGate = ProviderContextGate()
        let cancellationObserved = AsyncFlag()
        let disableReturned = AsyncFlag()
        let artifactStore = harness.artifacts
        let agent = PostMeetingAgent(
            meetings: harness.meetings,
            artifacts: artifactStore,
            makeContext: { _ in
                PostMeetingProviderContext(provider: upstream, model: "fake-model")
            },
            persistDrafts: { drafts, meetingID in
                // Model a transaction boundary which has been admitted and
                // cannot be interrupted. Cancellation is observed, but the
                // owned write still finishes atomically when the gate opens.
                await withTaskCancellationHandler {
                    await persistenceGate.suspendUntilReleased()
                } onCancel: {
                    Task { await cancellationObserved.set() }
                }
                return try await artifactStore.insertDrafts(drafts, meetingID: meetingID)
            }
        )

        let attempt = Task { await agent.generateArtifacts(meetingID: harness.meetingID) }
        for _ in 0..<300 {
            if await persistenceGate.entered { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await persistenceGate.entered)

        let disable = Task {
            await agent.setGenerationEnabled(false)
            await disableReturned.set()
        }
        for _ in 0..<300 {
            if await cancellationObserved.isSet { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await cancellationObserved.isSet)
        #expect(!(await disableReturned.isSet), "AI-off must still be draining persistence")
        #expect(try await artifactStore.artifacts(for: harness.meetingID).isEmpty)

        // Re-enable while the old off call is still draining. The epoch, not
        // the mutable enabled bit, must keep the old attempt cancelled.
        await agent.setGenerationEnabled(true)
        await persistenceGate.release()
        await disable.value

        #expect(await disableReturned.isSet)
        #expect(await attempt.value == .cancelled)
        let rowsAtReturn = try await artifactStore.artifacts(for: harness.meetingID)
        #expect(rowsAtReturn.count == ExtractionFixture.expectedKinds().count)
        try await Task.sleep(for: .milliseconds(25))
        #expect(try await artifactStore.artifacts(for: harness.meetingID) == rowsAtReturn,
                "no owned transaction may commit after AI-off returns")

        #expect(await agent.generateArtifacts(meetingID: harness.meetingID)
            == .skippedExistingArtifacts)
        #expect(try await artifactStore.artifacts(for: harness.meetingID) == rowsAtReturn)
        #expect(server.recordedRequests.count == 1, "retry must not duplicate a committed set")
    }

    @Test func globalAIOffBeforePersistenceTransactionWritesNothingAndFreshRetrySucceeds() async throws {
        let harness = try await AgentHarness.start()
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json)),
            .json(status: 200, body: OpenAIFixtures.completionBody(content: ExtractionFixture.json)),
        ])
        defer { server.stop() }
        let upstream = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
        let beforeTransaction = ProviderContextGate()
        let artifactStore = harness.artifacts
        let agent = PostMeetingAgent(
            meetings: harness.meetings,
            artifacts: artifactStore,
            makeContext: { _ in
                PostMeetingProviderContext(provider: upstream, model: "fake-model")
            },
            persistDrafts: { drafts, meetingID in
                // This gate is still before the actual store transaction.
                // Cancellation opens it, then the explicit check prevents
                // the old attempt from ever crossing the write boundary.
                await withTaskCancellationHandler {
                    await beforeTransaction.suspendUntilReleased()
                } onCancel: {
                    Task { await beforeTransaction.release() }
                }
                try Task.checkCancellation()
                return try await artifactStore.insertDrafts(drafts, meetingID: meetingID)
            }
        )

        let oldAttempt = Task { await agent.generateArtifacts(meetingID: harness.meetingID) }
        for _ in 0..<300 {
            if await beforeTransaction.entered { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await beforeTransaction.entered)

        await agent.setGenerationEnabled(false)

        #expect(await oldAttempt.value == .cancelled)
        #expect(try await artifactStore.artifacts(for: harness.meetingID).isEmpty)

        await agent.setGenerationEnabled(true)
        guard case .drafted(let retryRows) = await agent.generateArtifacts(meetingID: harness.meetingID) else {
            Issue.record("a fresh post-toggle attempt should persist one draft set")
            return
        }
        #expect(retryRows.count == ExtractionFixture.expectedKinds().count)
        #expect(try await artifactStore.artifacts(for: harness.meetingID).count == retryRows.count)
        #expect(server.recordedRequests.count == 2)
    }
}
