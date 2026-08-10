import CaptureKit
import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing
import TranscribeKit

@testable import AppShell

@MainActor
struct LiveCopilotCoordinatorTests {
    private struct Shell {
        let coordinator: AppShellCoordinator
        let database: MacapyDatabase
    }

    private func makeShell(
        server: FakeOpenAIServer,
        ephemeral: Bool = false,
        aiEnabled: Bool = true,
        capUSD: Double? = nil,
        turnEnded: Bool = true
    ) async throws -> Shell {
        let database = try MacapyDatabase.inMemory()
        let counters = MeetingPipelineTests.Counters()
        var events: [TranscriptEvent] = [
            .final(Segment(
                id: UUID(), source: .system,
                text: "Hoang, can you explain the migration risk?",
                tStart: 61, tEnd: 62)),
        ]
        if turnEnded { events.append(.turnEnded) }
        let engine = MeetingPipelineTests.FakeSTTEngine(
            live: [.system: events],
            counters: counters
        )
        let source = MeetingPipelineTests.FakeCaptureSource(source: .system, counters: counters)
        let coordinator = AppShellCoordinator(
            panel: MeetingPipelineTests.FakePanel(),
            installHotKey: false,
            makePipeline: { store in
                MeetingPipeline(engine: engine, sources: [source], store: store)
            },
            makeDatabase: { database },
            providerProfiles: [.fake(baseURL: server.baseURL)],
            credentials: InMemoryCredentialStore(keys: ["fake": "sk-test"])
        )
        coordinator.ephemeralNextMeeting = ephemeral
        let settings = try #require(coordinator.settingsStore())
        try await settings.setProviderSettings(ProviderSettings(
            selectedProfileID: "fake",
            fastModelOverrides: ["fake": "ignored-fast"],
            deepModelOverrides: ["fake": "ignored-deep"],
            perMeetingCapUSD: capUSD
        ))
        try await settings.setLiveAISettings(LiveAISettings(
            aiFeaturesEnabled: aiEnabled,
            sensitivity: .quiet,
            preferredName: "Hoang"
        ))
        try await settings.setPricing(PricingTable(rates: [
            "fake-model": ModelPricing(
                inputPerMillionUSD: 1,
                cachedInputPerMillionUSD: 0.1,
                outputPerMillionUSD: 2),
        ]))
        return Shell(coordinator: coordinator, database: database)
    }

    @discardableResult
    private func waitUntil(
        _ label: String,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(label)")
        return false
    }

    private static var classifier: FakeOpenAIServer.Response {
        .json(status: 200, body: OpenAIFixtures.completionBody(
            content: #"{"action":"suggest_answer","confidence":0.97,"target":"migration risk"}"#
        ))
    }

    private static var answer: FakeOpenAIServer.Response {
        .sse(frames: [
            OpenAIFixtures.contentDelta("Explain the rollback plan."),
            OpenAIFixtures.finish(
                reason: "stop", promptTokens: 30, completionTokens: 6),
            OpenAIFixtures.done,
        ])
    }

    private static var artifact: FakeOpenAIServer.Response {
        .json(status: 200, body: OpenAIFixtures.completionBody(
            content: #"{"summary":"Migration risk was discussed.","decisions":[],"action_items":[]}"#
        ))
    }

    @Test func turnConsumerAttachesAfterResetBeforeImmediateCaptureTurn() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            Self.classifier, Self.answer, Self.artifact,
        ])
        defer { server.stop() }
        let shell = try await makeShell(server: server)

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        await waitUntil("immediate proactive card") {
            shell.coordinator.copilot.card?.isStreaming == false
        }

        #expect(shell.coordinator.copilot.card?.text == "Explain the rollback plan.")
        #expect(server.recordedRequests.count == 2,
                "the non-replaying turn must reach classifier and generation")
        #expect(server.recordedRequests[0].jsonBody?["model"] as? String == "fake-model")
        #expect(server.recordedRequests[1].jsonBody?["model"] as? String == "fake-model")
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        #expect(server.recordedRequests.count == 3)
        #expect(server.recordedRequests[2].jsonBody?["model"] as? String == "fake-model")
        let meeting = try #require(try await shell.coordinator.historyStore()?.listMeetings().first)
        let entries = try await shell.coordinator.spendLedger()?.entries(meetingID: meeting.id)
        #expect(entries?.map(\.purpose) == [.classifier, .generation, .artifact])
    }

    @Test func ephemeralLiveCallsBookNoPersistentSpendRows() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.classifier, Self.answer])
        defer { server.stop() }
        let shell = try await makeShell(server: server, ephemeral: true)

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        await waitUntil("ephemeral suggestion") {
            shell.coordinator.copilot.card?.isStreaming == false
        }
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()

        #expect(server.recordedRequests.count == 2)
        #expect(try await shell.coordinator.spendLedger()?.allEntries().isEmpty == true)
        #expect(try await shell.coordinator.historyStore()?.listMeetings().isEmpty == true)
    }

    @Test func liveSpendAndPostMeetingArtifactShareOneMeetingCap() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            Self.classifier, Self.answer, Self.artifact,
        ])
        defer { server.stop() }
        // Admits the bounded classifier and answer reservations, but not the
        // artifact extractor's conservative 4,096-output-token reservation.
        let shell = try await makeShell(server: server, capUSD: 0.005)

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        await waitUntil("live calls under cap") {
            shell.coordinator.copilot.card?.isStreaming == false
        }
        #expect(server.recordedRequests.count == 2)

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()

        #expect(server.recordedRequests.count == 2,
                "post-meeting extraction must observe the live meeting meter/cap")
        let meeting = try #require(try await shell.coordinator.historyStore()?.listMeetings().first)
        #expect(try await shell.coordinator.artifactStore()?.artifacts(for: meeting.id).isEmpty == true)
        let purposes = try await shell.coordinator.spendLedger()?.entries(meetingID: meeting.id).map(\.purpose)
        #expect(purposes == [.classifier, .generation])
    }

    @Test func ephemeralCapStillStopsAIWithZeroDiskResidue() async throws {
        let server = try FakeOpenAIServer.start(responses: [])
        defer { server.stop() }
        let shell = try await makeShell(
            server: server,
            ephemeral: true,
            capUSD: 0.000_001
        )

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        await waitUntil("ephemeral cap state") {
            if case .paused = shell.coordinator.copilot.availability { return true }
            return false
        }

        #expect(server.recordedRequests.isEmpty)
        #expect(try await shell.coordinator.spendLedger()?.allEntries().isEmpty == true)
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
    }

    @Test func globalAIOffBlocksLiveAndPostMeetingCallsButNotTranscript() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.artifact])
        defer { server.stop() }
        let shell = try await makeShell(server: server, aiEnabled: false)

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        await waitUntil("transcript while AI is off") {
            shell.coordinator.store.segments.count == 1
        }
        #expect(shell.coordinator.store.segments.count == 1)
        #expect(shell.coordinator.copilot.availability == .disabled)
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()

        #expect(server.recordedRequests.isEmpty)
        let meeting = try #require(try await shell.coordinator.historyStore()?.listMeetings().first)
        #expect(try await shell.coordinator.artifactStore()?.artifacts(for: meeting.id).isEmpty == true)
        #expect(try await shell.coordinator.historyStore()?.segments(for: meeting.id).count == 1)
        let manual = await shell.coordinator.postMeetingAgent()?.generateArtifacts(meetingID: meeting.id)
        #expect(manual == .skippedNoProvider)
        #expect(server.recordedRequests.isEmpty)
    }
}
