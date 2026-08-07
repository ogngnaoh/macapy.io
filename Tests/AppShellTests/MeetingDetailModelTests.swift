import CaptureKit
import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing
import TranscribeKit

@testable import AppShell

/// The artifacts pane's state machine, built through the coordinator's real
/// factory (`meetingDetailModel(for:)`): review/pending/setup/halt derivation,
/// the approve/reject flips (check 3's UI half), and the retroactive generate
/// button reaching the same agent path (check 5's UI half). Check 6's
/// "visible-halt state set" oracle lives here.
@MainActor
struct MeetingDetailModelTests {

    private struct World {
        let coordinator: AppShellCoordinator
        let meetings: MeetingStore
        let artifacts: ArtifactStore
        let meeting: MeetingRecord

        /// The meeting's current row (endMeeting mutates the DB, not our copy).
        func freshMeeting() async throws -> MeetingRecord {
            try #require(try await meetings.meeting(id: meeting.id))
        }
    }

    private func makeWorld(
        server: FakeOpenAIServer?,
        configureProvider: Bool = true,
        capUSD: Double? = nil,
        endMeeting: Bool = true
    ) async throws -> World {
        let database = try MacapyDatabase.inMemory()
        let counters = MeetingPipelineTests.Counters()
        let coordinator = AppShellCoordinator(
            panel: MeetingPipelineTests.FakePanel(),
            installHotKey: false,
            makePipeline: { store in
                MeetingPipeline(
                    engine: MeetingPipelineTests.FakeSTTEngine(counters: counters),
                    sources: [],
                    store: store)
            },
            makeDatabase: { database },
            providerProfiles: server.map { [.fake(baseURL: $0.baseURL)] } ?? [],
            credentials: InMemoryCredentialStore(keys: ["fake": "sk-test"])
        )
        let meetings = try #require(coordinator.historyStore())
        let artifacts = try #require(coordinator.artifactStore())
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await meetings.append(
            [Segment(id: UUID(), source: .mic, text: "I will send the notes by Friday.", tStart: 0, tEnd: 1)],
            to: meeting.id)
        if endMeeting {
            try await meetings.endMeeting(id: meeting.id, endedAt: Date())
        }
        if configureProvider, server != nil {
            let settings = try #require(coordinator.settingsStore())
            try await settings.setProviderSettings(
                ProviderSettings(selectedProfileID: "fake", perMeetingCapUSD: capUSD))
        }
        return World(coordinator: coordinator, meetings: meetings, artifacts: artifacts, meeting: meeting)
    }

    // MARK: - State derivation

    @Test func existingArtifactsLoadIntoReviewState() async throws {
        let world = try await makeWorld(server: nil, configureProvider: false)
        try await world.artifacts.insertDrafts(
            [try DraftArtifact(kind: .summary, encoding: SummaryPayload(text: "done"))],
            meetingID: world.meeting.id)

        let model = world.coordinator.meetingDetailModel(for: try await world.freshMeeting())
        await model.load()

        #expect(model.state == .review)
        #expect(model.summaries.count == 1)
    }

    @Test func endedMeetingWithProviderAndNoArtifactsIsPending() async throws {
        let server = try FakeOpenAIServer.start(responses: [])
        defer { server.stop() }
        let world = try await makeWorld(server: server)

        let model = world.coordinator.meetingDetailModel(for: try await world.freshMeeting())
        await model.load()

        #expect(model.state == .pending)
    }

    @Test func endedMeetingWithoutProviderShowsTheQuietSetupPrompt() async throws {
        let world = try await makeWorld(server: nil, configureProvider: false)

        let model = world.coordinator.meetingDetailModel(for: try await world.freshMeeting())
        await model.load()

        #expect(model.state == .needsProvider)
    }

    @Test func activeMeetingShowsInProgress() async throws {
        let world = try await makeWorld(server: nil, configureProvider: false, endMeeting: false)

        let model = world.coordinator.meetingDetailModel(for: world.meeting)
        await model.load()

        #expect(model.state == .meetingInProgress)
    }

    /// Check 6's UI oracle: cap spent ⇒ the pane loads straight into the
    /// visible halt state, with the real numbers.
    @Test func capReachedLoadsIntoTheVisibleHaltState() async throws {
        let server = try FakeOpenAIServer.start(responses: [])
        defer { server.stop() }
        let world = try await makeWorld(server: server, capUSD: 0.25)
        let ledger = try #require(world.coordinator.spendLedger())
        try await ledger.record(SpendEntry(
            id: UUID(),
            meetingID: world.meeting.id,
            model: "fake-model",
            usage: TokenUsage(promptTokens: 1_000, completionTokens: 500),
            estCostUSD: 0.30,
            purpose: .generation,
            at: Date()))

        let model = world.coordinator.meetingDetailModel(for: try await world.freshMeeting())
        await model.load()

        #expect(model.state == .halted(spentUSD: 0.30, capUSD: 0.25))
    }

    // MARK: - Actions

    @Test func approveAndRejectFlipStatusAndNothingElse() async throws {
        let world = try await makeWorld(server: nil, configureProvider: false)
        let inserted = try await world.artifacts.insertDrafts(
            [
                try DraftArtifact(kind: .decision, encoding: DecisionPayload(text: "ship it")),
                try DraftArtifact(
                    kind: .actionItem,
                    encoding: ActionItemPayload(title: "notes", owner: "You", deadline: "Friday")),
            ],
            meetingID: world.meeting.id)

        let model = world.coordinator.meetingDetailModel(for: try await world.freshMeeting())
        await model.load()
        await model.approve(inserted[0].id)
        await model.reject(inserted[1].id)

        #expect(model.state == .review)
        #expect(model.decisions.first?.artifactStatus == .approved)
        #expect(model.actionItems.first?.artifactStatus == .rejected)
        // Payloads untouched by the flips (the store-level row-diff oracle is
        // ArtifactStoreTests; this pins the same guarantee at the UI model).
        #expect(model.decisions.first?.payload == inserted[0].payload)
        #expect(model.actionItems.first?.payload == inserted[1].payload)
    }

    /// The "Generate artifacts" button (retroactive path): same agent, same
    /// rows, pane lands in review.
    @Test func generateFromPendingDraftsAndEntersReview() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"summary":"Notes are coming.","decisions":[],"action_items":[{"title":"Send the notes","owner":"You","deadline":"Friday"}]}"#
            ))
        ])
        defer { server.stop() }
        let world = try await makeWorld(server: server)

        let model = world.coordinator.meetingDetailModel(for: try await world.freshMeeting())
        await model.load()
        #expect(model.state == .pending)
        await model.generate()

        #expect(model.state == .review)
        #expect(model.summaries.first?.payload(as: SummaryPayload.self)?.text == "Notes are coming.")
        #expect(model.actionItems.first?.payload(as: ActionItemPayload.self)
            == ActionItemPayload(title: "Send the notes", owner: "You", deadline: "Friday"))
        #expect(model.lastDraftedInSeconds != nil)
    }

    @Test func failedGenerationShowsTheTypedUserMessageAndStaysRetryable() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 503, body: OpenAIFixtures.errorBody(message: "overloaded")),
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"summary":"second try","decisions":[],"action_items":[]}"#)),
        ])
        defer { server.stop() }
        let world = try await makeWorld(server: server)

        let model = world.coordinator.meetingDetailModel(for: try await world.freshMeeting())
        await model.load()
        await model.generate()
        #expect(model.state == .failed(ProviderError.server(status: 503, message: "overloaded").userMessage))
        #expect(try await world.artifacts.artifacts(for: world.meeting.id).isEmpty)

        await model.generate()
        #expect(model.state == .review)
        #expect(model.summaries.first?.payload(as: SummaryPayload.self)?.text == "second try")
    }

    @Test func missingStoresShowUnavailableNotACrash() async throws {
        let world = try await makeWorld(server: nil, configureProvider: false)
        let model = MeetingDetailModel(
            meeting: try await world.freshMeeting(),
            artifactStore: nil,
            agent: nil,
            isProviderConfigured: { false },
            capStatus: { _ in nil })

        await model.load()

        #expect(model.state == .unavailable)
    }
}
