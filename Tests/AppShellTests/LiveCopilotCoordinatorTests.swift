import AgentKit
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
    private actor BlockingGenerationLedger: SpendLedger {
        private var entries: [SpendEntry] = []
        private var generationRelease: CheckedContinuation<Void, Never>?
        private var shouldBlockGeneration = true
        private(set) var generationSettlementStarted = false

        func record(_ entry: SpendEntry) async throws {
            if entry.purpose == .generation, shouldBlockGeneration {
                generationSettlementStarted = true
                await withCheckedContinuation { generationRelease = $0 }
            }
            entries.append(entry)
        }

        func totalCostUSD(meetingID: UUID) async throws -> Double {
            entries
                .filter { $0.meetingID == meetingID }
                .compactMap(\.estCostUSD)
                .reduce(0, +)
        }

        func releaseGenerationSettlement() {
            shouldBlockGeneration = false
            generationRelease?.resume()
            generationRelease = nil
        }
    }

    private struct DeterministicLiveProvider: LLMProvider {
        func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.token("Explain the rollback plan."))
                continuation.yield(.completed(Completion(
                    finishReason: "stop",
                    usage: TokenUsage(promptTokens: 30, completionTokens: 6)
                )))
                continuation.finish()
            }
        }

        func completeReportingUsage<T: Decodable>(
            _ request: CompletionRequest,
            as type: T.Type
        ) async throws -> CompletedCall<T> {
            let json = #"{"action":"suggest_answer","confidence":0.97,"target":"migration risk"}"#
            return CompletedCall(
                value: try JSONDecoder().decode(type, from: Data(json.utf8)),
                usage: TokenUsage(promptTokens: 20, completionTokens: 5)
            )
        }
    }

    private final class DelayFirstCompletionProvider: LLMProvider, @unchecked Sendable {
        private let upstream: any LLMProvider
        private let lock = NSLock()
        private var shouldDelay = true

        init(upstream: any LLMProvider) { self.upstream = upstream }

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

    private struct Shell {
        let coordinator: AppShellCoordinator
        let database: MacapyDatabase
    }

    private func makeShell(
        server: FakeOpenAIServer,
        ephemeral: Bool = false,
        aiEnabled: Bool = true,
        capUSD: Double? = nil,
        turnEnded: Bool = true,
        postMeetingProvider: (any LLMProvider)? = nil,
        liveProvider: (any LLMProvider)? = nil,
        liveSpendLedger: (any SpendLedger)? = nil
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
        let contextOverride: (@Sendable (UUID) async throws -> PostMeetingProviderContext?)?
        if let postMeetingProvider {
            contextOverride = { @Sendable _ in
                PostMeetingProviderContext(provider: postMeetingProvider, model: "fake-model")
            }
        } else {
            contextOverride = nil
        }
        let coordinator = AppShellCoordinator(
            panel: MeetingPipelineTests.FakePanel(),
            installHotKey: false,
            makePipeline: { store in
                MeetingPipeline(engine: engine, sources: [source], store: store)
            },
            makeDatabase: { database },
            providerProfiles: [.fake(baseURL: server.baseURL)],
            credentials: InMemoryCredentialStore(keys: ["fake": "sk-test"]),
            postMeetingContextOverride: contextOverride,
            liveProviderOverride: liveProvider,
            liveSpendLedgerOverride: liveSpendLedger
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

    private func fileSizes(in directory: URL) throws -> [String: Int] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        )
        return try Dictionary(uniqueKeysWithValues: urls.compactMap { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            return (url.lastPathComponent, values.fileSize ?? 0)
        })
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

    @Test func ephemeralLiveAILeavesOnDiskDatabaseRowsAndSensitiveBytesUntouched() async throws {
        let canary = "M3_EPHEMERAL_CANARY_7EDB3E6B"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macapy-ephemeral-live-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("macapy.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try MacapyDatabase.onDisk(at: databaseURL)
        let server = try FakeOpenAIServer.start(responses: [Self.classifier, Self.answer])
        defer { server.stop() }
        let counters = MeetingPipelineTests.Counters()
        let engine = MeetingPipelineTests.FakeSTTEngine(
            live: [.system: [
                .final(Segment(
                    id: UUID(), source: .system,
                    text: "Hoang, can you explain \(canary)?",
                    tStart: 61, tEnd: 62)),
                .turnEnded,
            ]],
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
        coordinator.ephemeralNextMeeting = true
        let settings = try #require(coordinator.settingsStore())
        try await settings.setProviderSettings(ProviderSettings(selectedProfileID: "fake"))
        try await settings.setLiveAISettings(LiveAISettings(preferredName: "Hoang"))
        try await settings.setPricing(PricingTable(rates: [
            "fake-model": ModelPricing(
                inputPerMillionUSD: 1,
                cachedInputPerMillionUSD: 0.1,
                outputPerMillionUSD: 2),
        ]))
        // Force every persistent store to initialize before the baseline; any
        // later growth is attributable to the ephemeral meeting itself.
        _ = try #require(coordinator.historyStore())
        _ = try #require(coordinator.spendLedger())
        _ = try #require(coordinator.artifactStore())
        let before = try fileSizes(in: directory)

        coordinator.toggleSession()
        await coordinator.settle()
        await waitUntil("ephemeral on-disk suggestion") {
            coordinator.copilot.card?.isStreaming == false
        }
        coordinator.toggleSession()
        await coordinator.settle()

        #expect(try await coordinator.historyStore()?.listMeetings().isEmpty == true)
        #expect(try await coordinator.spendLedger()?.allEntries().isEmpty == true)
        // Artifacts have a required FK to meetings; assert the direct lookup
        // too so an accidental orphan/write-path regression is visible.
        #expect(try await coordinator.artifactStore()?.artifacts(for: UUID()).isEmpty == true)
        #expect(try fileSizes(in: directory) == before)
        let needle = Data(canary.utf8)
        for url in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        {
            let bytes = try Data(contentsOf: url)
            #expect(bytes.range(of: needle) == nil, "canary leaked to \(url.lastPathComponent)")
        }
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

    @Test func teardownWaitsForCancelledLiveReservationBeforePostMeetingGeneration() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.artifact])
        defer { server.stop() }
        let ledger = BlockingGenerationLedger()
        let postMeeting = OpenAICompatibleClient(
            profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
        let shell = try await makeShell(
            server: server,
            postMeetingProvider: postMeeting,
            liveProvider: DeterministicLiveProvider(),
            liveSpendLedger: ledger
        )

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        for _ in 0..<300 {
            if await ledger.generationSettlementStarted { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await ledger.generationSettlementStarted)
        #expect(server.recordedRequests.isEmpty)

        // Exercise the kill-switch cancellation path while the metered live
        // stream's detached ledger settlement is deliberately held open, then
        // re-enable AI so the meeting-end extractor should run once safe.
        let settings = shell.coordinator.liveAISettingsModel()
        await settings.load()
        await settings.setEnabled(false)
        #expect(shell.coordinator.copilot.availability == .disabled)
        await settings.setEnabled(true)

        shell.coordinator.toggleSession()
        let settling = Task { await shell.coordinator.settle() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(server.recordedRequests.isEmpty,
                "artifact request crossed an unsettled live reservation")

        await ledger.releaseGenerationSettlement()
        await settling.value

        #expect(server.recordedRequests.count == 1)
        let meeting = try #require(try await shell.coordinator.historyStore()?.listMeetings().first)
        #expect(try await shell.coordinator.artifactStore()?.artifacts(for: meeting.id).isEmpty == false)
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
        #expect(!shell.coordinator.copilot.canAsk)
        let providerSettings = shell.coordinator.providerSettingsModel()
        await providerSettings.load()
        await providerSettings.setCap(0.000_000_5)
        #expect(!shell.coordinator.copilot.canAsk, "lowering the cap must keep the hard pause latched")
        await providerSettings.setCap(1)
        #expect(shell.coordinator.copilot.canAsk, "raising the cap admits explicit work again")
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

    @Test func globalAIOffCancelsAutomaticArtifactGenerationBeforePersistence() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.artifact])
        defer { server.stop() }
        let upstream = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
        let delayed = DelayFirstCompletionProvider(upstream: upstream)
        let shell = try await makeShell(
            server: server,
            turnEnded: false,
            postMeetingProvider: delayed
        )

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        shell.coordinator.toggleSession()
        await waitUntil("automatic artifact request") { server.recordedRequests.count == 1 }

        let settings = shell.coordinator.liveAISettingsModel()
        await settings.load()
        await settings.setEnabled(false)
        await shell.coordinator.settle()

        let meeting = try #require(try await shell.coordinator.historyStore()?.listMeetings().first)
        #expect(try await shell.coordinator.artifactStore()?.artifacts(for: meeting.id).isEmpty == true)
        #expect(try await shell.coordinator.historyStore()?.segments(for: meeting.id).count == 1)
    }

    @Test func globalAIOffCancelsManualArtifactsQuietlyAndManualRetryStillWorks() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.artifact, Self.artifact])
        defer { server.stop() }
        let upstream = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
        let delayed = DelayFirstCompletionProvider(upstream: upstream)
        let shell = try await makeShell(
            server: server,
            turnEnded: false,
            postMeetingProvider: delayed
        )
        let meetings = try #require(shell.coordinator.historyStore())
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await meetings.append(
            [Segment(
                id: UUID(), source: .mic, text: "I will send notes.",
                tStart: 0, tEnd: 1)],
            to: meeting.id
        )
        try await meetings.endMeeting(id: meeting.id, endedAt: Date())
        let ended = try #require(try await meetings.meeting(id: meeting.id))
        let detail = shell.coordinator.meetingDetailModel(for: ended)
        await detail.load()

        let generation = Task { await detail.generate() }
        await waitUntil("manual artifact request") { server.recordedRequests.count == 1 }
        let settings = shell.coordinator.liveAISettingsModel()
        await settings.load()
        await settings.setEnabled(false)
        await generation.value

        #expect(detail.state == .pending)
        #expect(try await shell.coordinator.artifactStore()?.artifacts(for: meeting.id).isEmpty == true)

        await settings.setEnabled(true)
        await detail.generate()
        #expect(detail.state == .review)
        #expect(server.recordedRequests.count == 2)
    }
}
