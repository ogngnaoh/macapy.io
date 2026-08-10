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
    private actor LifecycleGate {
        enum Target { case startup, providerRefresh }

        private let target: Target
        private var consumed = false
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private(set) var started = false

        init(_ target: Target) { self.target = target }

        func checkpoint(_ checkpoint: AppShellCoordinator.LifecycleCheckpoint) async {
            let matches: Bool
            switch (target, checkpoint) {
            case (.startup, .startupBeforeCommit(_)),
                 (.providerRefresh, .providerRefreshBeforeReplacement(_)):
                matches = true
            default:
                matches = false
            }
            guard matches, !consumed else { return }
            consumed = true
            started = true
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private actor BlockingClassifierLedger: SpendLedger {
        private var entries: [SpendEntry] = []
        private var classifierRelease: CheckedContinuation<Void, Never>?
        private var shouldBlockClassifier = true
        private(set) var classifierSettlementStarted = false

        func record(_ entry: SpendEntry) async throws {
            if entry.purpose == .classifier, shouldBlockClassifier {
                classifierSettlementStarted = true
                await withCheckedContinuation { classifierRelease = $0 }
            }
            entries.append(entry)
        }

        func totalCostUSD(meetingID: UUID) async throws -> Double {
            entries
                .filter { $0.meetingID == meetingID }
                .compactMap(\.estCostUSD)
                .reduce(0, +)
        }

        func releaseClassifierSettlement() {
            shouldBlockClassifier = false
            classifierRelease?.resume()
            classifierRelease = nil
        }
    }

    private actor BlockingFailingSettingsSave {
        enum SaveError: Error { case unavailable }

        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private(set) var started = false

        func save(_ settings: LiveAISettings) async throws {
            started = true
            await withCheckedContinuation { releaseContinuation = $0 }
            throw SaveError.unavailable
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    /// Holds the first capped admission before a reservation exists. The
    /// actor remains reentrant, so post-meeting work can prove that it does not
    /// need to wait for an already-cancelled pre-reservation call.
    private actor BlockingFirstTotalLedger: SpendLedger {
        private var entries: [SpendEntry] = []
        private var firstTotalRelease: CheckedContinuation<Void, Never>?
        private var shouldBlockFirstTotal = true
        private(set) var firstTotalStarted = false
        private(set) var firstTotalReturned = false

        func record(_ entry: SpendEntry) async throws { entries.append(entry) }

        func totalCostUSD(meetingID: UUID) async throws -> Double {
            if shouldBlockFirstTotal {
                shouldBlockFirstTotal = false
                firstTotalStarted = true
                await withCheckedContinuation { firstTotalRelease = $0 }
                firstTotalReturned = true
            }
            return entries
                .filter { $0.meetingID == meetingID }
                .compactMap(\.estCostUSD)
                .reduce(0, +)
        }

        func releaseFirstTotal() {
            firstTotalRelease?.resume()
            firstTotalRelease = nil
        }
    }

    private enum TestLedgerError: Error { case unavailable }

    /// Simulates a provider-complete call whose debit cannot be made durable.
    /// The meter must retain its conservative in-memory uncertainty.
    private actor FailingSpendLedger: SpendLedger {
        func record(_ entry: SpendEntry) async throws { throw TestLedgerError.unavailable }
        func totalCostUSD(meetingID: UUID) async throws -> Double { 0 }
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

    private final class CountingLiveProvider: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _structuredCalls = 0
        private var _streamCalls = 0

        var calls: (structured: Int, stream: Int) {
            lock.withLock { (_structuredCalls, _streamCalls) }
        }

        func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
            lock.withLock { _streamCalls += 1 }
            return AsyncThrowingStream { continuation in
                continuation.yield(.token("late answer"))
                continuation.yield(.completed(Completion(
                    finishReason: "stop",
                    usage: TokenUsage(promptTokens: 30, completionTokens: 3)
                )))
                continuation.finish()
            }
        }

        func completeReportingUsage<T: Decodable>(
            _ request: CompletionRequest,
            as type: T.Type
        ) async throws -> CompletedCall<T> {
            lock.withLock { _structuredCalls += 1 }
            let json = #"{"action":"suggest_answer","confidence":0.97,"target":"migration risk"}"#
            return CompletedCall(
                value: try JSONDecoder().decode(type, from: Data(json.utf8)),
                usage: TokenUsage(promptTokens: 20, completionTokens: 5)
            )
        }
    }

    private struct HighUsageLiveProvider: LLMProvider {
        private static let usage = TokenUsage(promptTokens: 10, completionTokens: 1_000_000)

        func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.token("Explain the rollback plan."))
                continuation.yield(.completed(Completion(
                    finishReason: "stop",
                    usage: Self.usage
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
                usage: Self.usage
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
        let counters: MeetingPipelineTests.Counters
        let credentials: InMemoryCredentialStore
    }

    private func makeShell(
        server: FakeOpenAIServer,
        ephemeral: Bool = false,
        aiEnabled: Bool = true,
        capUSD: Double? = nil,
        turnEnded: Bool = true,
        postMeetingProvider: (any LLMProvider)? = nil,
        liveProvider: (any LLMProvider)? = nil,
        liveSpendLedger: (any SpendLedger)? = nil,
        profiles: [EndpointProfile]? = nil,
        credentialStore: InMemoryCredentialStore? = nil,
        lifecycleCheckpoint:
            (@Sendable (AppShellCoordinator.LifecycleCheckpoint) async -> Void)? = nil,
        liveSettingsSaveOverride:
            (@Sendable (LiveAISettings) async throws -> Void)? = nil
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
        let credentials = credentialStore ?? InMemoryCredentialStore(keys: ["fake": "sk-test"])
        let coordinator = AppShellCoordinator(
            panel: MeetingPipelineTests.FakePanel(),
            installHotKey: false,
            makePipeline: { store in
                MeetingPipeline(engine: engine, sources: [source], store: store)
            },
            makeDatabase: { database },
            providerProfiles: profiles ?? [.fake(baseURL: server.baseURL)],
            credentials: credentials,
            postMeetingContextOverride: contextOverride,
            liveProviderOverride: liveProvider,
            liveSpendLedgerOverride: liveSpendLedger,
            lifecycleCheckpoint: lifecycleCheckpoint,
            liveSettingsSaveOverride: liveSettingsSaveOverride
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
        return Shell(
            coordinator: coordinator,
            database: database,
            counters: counters,
            credentials: credentials
        )
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

    @Test func blockedClassifierSettlementStopsCaptureAndDoesNotDelayNextMeeting() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.artifact])
        defer { server.stop() }
        let ledger = BlockingClassifierLedger()
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
            if await ledger.classifierSettlementStarted { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await ledger.classifierSettlementStarted)
        #expect(server.recordedRequests.isEmpty)

        // Stop directly while the metered classifier's detached settlement is
        // deliberately held open. Capture teardown must not inherit that wait.
        shell.coordinator.toggleSession()
        let settling = Task { await shell.coordinator.settle() }
        await waitUntil("first source stopped") {
            // Actor-backed assertion is made just below; this wait merely gives
            // the capture-first stop task a scheduling window.
            shell.coordinator.session.state == .idle
        }
        for _ in 0..<300 where await shell.counters.captureStops < 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await shell.counters.captureStops == 1)
        #expect(server.recordedRequests.isEmpty,
                "artifact request crossed an unsettled live reservation")

        // The first meeting's artifact remains settlement-gated, but the next
        // meeting is allowed to attach and start capture immediately.
        // Disable automatic classification for meeting two so this test stays
        // focused on the first meeting's blocked settlement.
        let settings = shell.coordinator.liveAISettingsModel()
        await settings.load()
        await settings.setSensitivity(.off)
        shell.coordinator.ephemeralNextMeeting = true
        shell.coordinator.toggleSession()
        for _ in 0..<300 where await shell.counters.captureStarts < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await shell.counters.captureStarts == 2)
        #expect(server.recordedRequests.isEmpty)

        await ledger.releaseClassifierSettlement()
        await settling.value

        #expect(server.recordedRequests.count == 1)
        let meeting = try #require(try await shell.coordinator.historyStore()?.listMeetings().first)
        #expect(try await shell.coordinator.artifactStore()?.artifacts(for: meeting.id).isEmpty == false)

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
    }

    @Test func cancelledPreReservationClassifierCannotStartLateAfterArtifact() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.artifact])
        defer { server.stop() }
        let ledger = BlockingFirstTotalLedger()
        let liveProvider = CountingLiveProvider()
        let postMeeting = OpenAICompatibleClient(
            profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
        let shell = try await makeShell(
            server: server,
            capUSD: 1,
            postMeetingProvider: postMeeting,
            liveProvider: liveProvider,
            liveSpendLedger: ledger
        )

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        for _ in 0..<300 {
            if await ledger.firstTotalStarted { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await ledger.firstTotalStarted)
        #expect(liveProvider.calls.structured == 0)

        shell.coordinator.toggleSession()
        let settling = Task { await shell.coordinator.settle() }
        for _ in 0..<300 where await shell.counters.captureStops < 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await shell.counters.captureStops == 1)
        await waitUntil("artifact generated while cancelled admission is suspended") {
            server.recordedRequests.count == 1
        }
        #expect(server.recordedRequests.count == 1)
        #expect(liveProvider.calls.structured == 0)
        #expect(liveProvider.calls.stream == 0)

        // The stale cap read resumes only after the artifact has crossed the
        // network. SpendMeter must observe cancellation before inserting its
        // reservation, so neither classifier nor generation can start late.
        await ledger.releaseFirstTotal()
        for _ in 0..<300 {
            if await ledger.firstTotalReturned { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await ledger.firstTotalReturned)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(liveProvider.calls.structured == 0)
        #expect(liveProvider.calls.stream == 0)
        #expect(server.recordedRequests.count == 1)
        await settling.value
    }

    @Test func capReleaseSignalUsesOnlyCurrentMeetingMeter() async {
        let registry = MeetingSpendRegistry()
        let oldMeeting = UUID()
        let activeMeeting = UUID()
        let oldMeter = SpendMeter(
            ledger: EphemeralSpendLedger(), pricing: .defaults, capUSD: 0.5)
        let activeMeter = SpendMeter(
            ledger: EphemeralSpendLedger(), pricing: .defaults, capUSD: 2)
        await registry.register(oldMeter, meetingID: oldMeeting)
        await registry.register(activeMeter, meetingID: activeMeeting)

        let raisedOnlyForOld = await registry.updateCaps(1, activeMeetingID: activeMeeting)
        #expect(!raisedOnlyForOld)
        #expect(await oldMeter.capUSD == 1)
        #expect(await activeMeter.capUSD == 1)

        let raisedForActive = await registry.updateCaps(1.5, activeMeetingID: activeMeeting)
        #expect(raisedForActive)
    }

    @Test func setupRequiredMeetingRecoversWithFreshKeyAndRetainedTurns() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.answer])
        defer { server.stop() }
        let shell = try await makeShell(server: server, ephemeral: true)
        let providers = shell.coordinator.providerSettingsModel()
        await providers.load()
        await providers.removeKey(for: "fake")

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        await waitUntil("setup-required transcript context") {
            shell.coordinator.copilot.latestTranscriptTime == 62
        }
        #expect(shell.coordinator.copilot.availability == .setupRequired)
        #expect(shell.coordinator.copilot.latestTranscriptTime == 62)
        #expect(server.recordedRequests.isEmpty)

        await providers.saveKey("sk-added-live", for: "fake")
        #expect(shell.coordinator.copilot.availability == .ready)
        #expect(shell.coordinator.copilot.canCatchUp)
        shell.coordinator.requestCatchUp()
        await waitUntil("catch-up after live setup") {
            shell.coordinator.copilot.card?.isStreaming == false
        }
        #expect(server.recordedRequests.count == 1)
        #expect(server.recordedRequests.first?.headers["authorization"] == "Bearer sk-added-live")

        let requested = shell.coordinator.copilot.card
        await providers.removeKey(for: "fake")
        #expect(shell.coordinator.copilot.availability == .setupRequired)
        #expect(shell.coordinator.copilot.card == requested,
                "completed requested content stays until dismissed even when setup is required")
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
    }

    @Test func cancelledStartupCannotCommitOverTheNextMeeting() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.answer])
        defer { server.stop() }
        let gate = LifecycleGate(.startup)
        let shell = try await makeShell(
            server: server,
            ephemeral: true,
            lifecycleCheckpoint: { await gate.checkpoint($0) }
        )
        try await shell.coordinator.settingsStore()?.setLiveAISettings(
            LiveAISettings(sensitivity: .off, preferredName: "Hoang"))

        shell.coordinator.toggleSession()
        for _ in 0..<300 where !(await gate.started) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.started)

        shell.coordinator.toggleSession()
        shell.coordinator.toggleSession()
        for _ in 0..<300 where await shell.counters.captureStarts < 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await shell.counters.captureStarts == 1,
                "meeting B must start while cancelled startup A is suspended")

        await gate.release()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await shell.coordinator.retainedSpendMeterCount() == 1,
                "startup A must remove only its own meter and cannot replace B's owner")
        #expect(shell.coordinator.copilot.canCatchUp)
        shell.coordinator.requestCatchUp()
        await waitUntil("meeting B catch-up") {
            shell.coordinator.copilot.card?.isStreaming == false
        }
        #expect(server.recordedRequests.count == 1)

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        #expect(await shell.coordinator.retainedSpendMeterCount() == 0)
    }

    @Test func aiOffWinsWhileStartupConfigurationIsSuspended() async throws {
        let server = try FakeOpenAIServer.start(responses: [])
        defer { server.stop() }
        let gate = LifecycleGate(.startup)
        let shell = try await makeShell(
            server: server,
            ephemeral: true,
            lifecycleCheckpoint: { await gate.checkpoint($0) }
        )

        shell.coordinator.toggleSession()
        for _ in 0..<300 where !(await gate.started) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let liveSettings = shell.coordinator.liveAISettingsModel()
        await liveSettings.load()
        await liveSettings.setEnabled(false)
        await gate.release()
        await shell.coordinator.settle()

        #expect(shell.coordinator.copilot.availability == .disabled)
        #expect(!shell.coordinator.copilot.canAsk)
        #expect(server.recordedRequests.isEmpty)
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        #expect(await shell.coordinator.retainedSpendMeterCount() == 0)
    }

    @Test func aiReenableWaitsForConcurrentTransportRevisionBeforeExposingProvider() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.answer])
        defer { server.stop() }
        let gate = LifecycleGate(.providerRefresh)
        let shell = try await makeShell(
            server: server,
            lifecycleCheckpoint: { await gate.checkpoint($0) }
        )
        try await shell.coordinator.settingsStore()?.setLiveAISettings(
            LiveAISettings(sensitivity: .off, preferredName: "Hoang"))
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()

        let live = shell.coordinator.liveAISettingsModel()
        await live.load()
        await live.setEnabled(false)
        #expect(shell.coordinator.copilot.availability == .disabled)

        let enabling = Task { await live.setEnabled(true) }
        for _ in 0..<300 where !(await gate.started) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.started)

        // Supersede the suspended enable refresh with a newer credential
        // transport revision. The current replacement may commit, but the
        // user-visible latch must remain disabled until enable has verified
        // that exact revision.
        let providers = shell.coordinator.providerSettingsModel()
        await providers.load()
        await providers.saveKey("sk-current-revision", for: "fake")
        #expect(shell.coordinator.copilot.availability == .disabled)
        #expect(!shell.coordinator.copilot.canCatchUp)

        await gate.release()
        await enabling.value
        #expect(shell.coordinator.copilot.availability == .ready)
        shell.coordinator.requestCatchUp()
        await waitUntil("catch-up after revision-gated enable") {
            shell.coordinator.copilot.card?.isStreaming == false
        }
        #expect(server.recordedRequests.count == 1)
        #expect(server.recordedRequests.first?.headers["authorization"]
            == "Bearer sk-current-revision")

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
    }

    @Test func staleProviderRefreshFromMeetingACannotMutateMeetingB() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.answer])
        defer { server.stop() }
        let gate = LifecycleGate(.providerRefresh)
        let alternate = EndpointProfile(
            id: "alternate",
            displayName: "Alternate",
            baseURL: server.baseURL,
            fastModel: "alternate-fast",
            deepModel: "alternate-deep"
        )
        let credentials = InMemoryCredentialStore(keys: [
            "fake": "sk-fake",
            "alternate": "sk-alternate",
        ])
        let shell = try await makeShell(
            server: server,
            ephemeral: true,
            profiles: [.fake(baseURL: server.baseURL), alternate],
            credentialStore: credentials,
            lifecycleCheckpoint: { await gate.checkpoint($0) }
        )
        try await shell.coordinator.settingsStore()?.setLiveAISettings(
            LiveAISettings(sensitivity: .off, preferredName: "Hoang"))
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()

        let providers = shell.coordinator.providerSettingsModel()
        await providers.load()
        let staleRefresh = Task { await providers.select(profileID: "alternate") }
        for _ in 0..<300 where !(await gate.started) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.started)

        shell.coordinator.toggleSession()
        await shell.coordinator.settleCaptureLifecycle()
        shell.coordinator.toggleSession()
        for _ in 0..<300 where await shell.counters.captureStarts < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await shell.counters.captureStarts == 2)

        // A newer transport change commits to meeting B while A's callback is
        // still suspended at the pre-replacement fence.
        await providers.select(profileID: "fake")
        await gate.release()
        await staleRefresh.value

        shell.coordinator.requestCatchUp()
        await waitUntil("meeting B provider") {
            shell.coordinator.copilot.card?.isStreaming == false
        }
        #expect(server.recordedRequests.count == 1)
        #expect(server.recordedRequests[0].jsonBody?["model"] as? String == "fake-model")
        #expect(server.recordedRequests[0].headers["authorization"] == "Bearer sk-fake")
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
    }

    @Test func rejectedStaleKeyIsReplacedDuringMeeting() async throws {
        let unauthorized = FakeOpenAIServer.Response.json(
            status: 401,
            body: #"{"error":{"message":"rejected"}}"#
        )
        let server = try FakeOpenAIServer.start(responses: [unauthorized, Self.answer])
        defer { server.stop() }
        let shell = try await makeShell(server: server, ephemeral: true)

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        await waitUntil("authentication pause") {
            shell.coordinator.copilot.availability == .setupRequired
                && server.recordedRequests.count == 1
        }

        let providers = shell.coordinator.providerSettingsModel()
        await providers.load()
        await providers.saveKey("sk-fresh", for: "fake")
        #expect(shell.coordinator.copilot.availability == .ready)
        shell.coordinator.requestCatchUp()
        await waitUntil("catch-up with replacement key") {
            shell.coordinator.copilot.card?.isStreaming == false
        }

        #expect(server.recordedRequests.count == 2)
        #expect(server.recordedRequests[0].headers["authorization"] == "Bearer sk-test")
        #expect(server.recordedRequests[1].headers["authorization"] == "Bearer sk-fresh")
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
    }

    @Test func aiOffOnRefreshesProviderWithoutResettingTranscriptContext() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            Self.classifier, Self.answer, Self.answer,
        ])
        defer { server.stop() }
        let shell = try await makeShell(server: server, ephemeral: true)

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        await waitUntil("initial suggestion") {
            shell.coordinator.copilot.card?.isStreaming == false
        }
        shell.coordinator.requestDismissCopilot()

        let settings = shell.coordinator.liveAISettingsModel()
        await settings.load()
        await settings.setEnabled(false)
        try shell.credentials.store("sk-after-off", for: "fake")
        await settings.setEnabled(true)

        #expect(shell.coordinator.copilot.latestTranscriptTime == 62)
        #expect(shell.coordinator.copilot.canCatchUp)
        shell.coordinator.requestCatchUp()
        await waitUntil("catch-up after AI re-enable") {
            shell.coordinator.copilot.card?.isStreaming == false
        }
        #expect(server.recordedRequests.count == 3)
        #expect(server.recordedRequests[2].headers["authorization"] == "Bearer sk-after-off")
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
    }

    @Test func aiReenableDoesNotExposeRetainedProviderBeforeRefreshCommits() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.answer])
        defer { server.stop() }
        let gate = LifecycleGate(.providerRefresh)
        let shell = try await makeShell(
            server: server,
            ephemeral: true,
            lifecycleCheckpoint: { await gate.checkpoint($0) }
        )
        try await shell.coordinator.settingsStore()?.setLiveAISettings(
            LiveAISettings(sensitivity: .off, preferredName: "Hoang"))
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()

        let settings = shell.coordinator.liveAISettingsModel()
        await settings.load()
        await settings.setEnabled(false)
        try shell.credentials.store("sk-after-off", for: "fake")
        let enabling = Task { await settings.setEnabled(true) }
        for _ in 0..<300 where !(await gate.started) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(shell.coordinator.copilot.availability == .disabled)
        #expect(!shell.coordinator.copilot.canAsk)
        shell.coordinator.requestCatchUp()
        #expect(server.recordedRequests.isEmpty,
                "the retained old provider must remain unreachable during refresh")

        await gate.release()
        await enabling.value
        #expect(shell.coordinator.copilot.canCatchUp)
        shell.coordinator.requestCatchUp()
        await waitUntil("catch-up after fenced enable") {
            shell.coordinator.copilot.card?.isStreaming == false
        }
        #expect(server.recordedRequests.count == 1)
        #expect(server.recordedRequests[0].headers["authorization"] == "Bearer sk-after-off")
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
    }

    @Test func settingsRebindingPreservesCompletedRequestedPresentation() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            Self.classifier, Self.answer, Self.answer,
        ])
        defer { server.stop() }
        let shell = try await makeShell(server: server, ephemeral: true)
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        await waitUntil("initial proactive") {
            shell.coordinator.copilot.card?.isStreaming == false
        }
        shell.coordinator.requestDismissCopilot()
        shell.coordinator.requestCatchUp()
        await waitUntil("requested catch-up") {
            shell.coordinator.copilot.card?.isStreaming == false
        }
        let requested = try #require(shell.coordinator.copilot.card)
        #expect(requested.requested)

        let providers = shell.coordinator.providerSettingsModel()
        await providers.load()
        await providers.setCap(0.5)
        await providers.setModelOverride("ignored", tier: .deep, for: "fake")
        await providers.saveKey("sk-rebound", for: "fake")
        #expect(shell.coordinator.copilot.card == requested,
                "cap, ignored model, and credential changes must preserve completed requested content")

        shell.coordinator.requestDismissCopilot()
        shell.coordinator.requestAsk()
        #expect(shell.coordinator.copilot.askPlaceholderVisible)
        await providers.saveKey("sk-rebound-again", for: "fake")
        #expect(shell.coordinator.copilot.askPlaceholderVisible,
                "transport rebinding must preserve an explicitly requested Ask surface")
        #expect(server.recordedRequests.count == 3)
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
    }

    @Test func profileChangeRebuildsCurrentProviderAndKeepsMeetingContext() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            Self.classifier, Self.answer, Self.answer,
        ])
        defer { server.stop() }
        let alternate = EndpointProfile(
            id: "alternate",
            displayName: "Alternate",
            baseURL: server.baseURL,
            fastModel: "alternate-fast",
            deepModel: "alternate-deep"
        )
        let credentials = InMemoryCredentialStore(keys: [
            "fake": "sk-test",
            "alternate": "sk-alternate",
        ])
        let shell = try await makeShell(
            server: server,
            ephemeral: true,
            profiles: [.fake(baseURL: server.baseURL), alternate],
            credentialStore: credentials
        )

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        await waitUntil("initial profile suggestion") {
            shell.coordinator.copilot.card?.isStreaming == false
        }

        let providers = shell.coordinator.providerSettingsModel()
        await providers.load()
        await providers.select(profileID: "alternate")
        #expect(shell.coordinator.copilot.latestTranscriptTime == 62)
        #expect(shell.coordinator.copilot.canCatchUp)
        shell.coordinator.requestCatchUp()
        await waitUntil("catch-up through alternate profile") {
            shell.coordinator.copilot.card?.isStreaming == false
        }

        #expect(server.recordedRequests.count == 3)
        #expect(server.recordedRequests[2].jsonBody?["model"] as? String == "alternate-deep")
        #expect(server.recordedRequests[2].headers["authorization"] == "Bearer sk-alternate")
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
    }

    @Test func uncertainLiveDebitSurvivesAutomaticHaltUntilCapRaised() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.artifact])
        defer { server.stop() }
        let shell = try await makeShell(
            server: server,
            capUSD: 3,
            liveProvider: HighUsageLiveProvider(),
            liveSpendLedger: FailingSpendLedger()
        )

        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        await waitUntil("high-usage live suggestion") {
            shell.coordinator.copilot.card?.isStreaming == false
        }
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()

        #expect(server.recordedRequests.isEmpty,
                "automatic artifacts must halt against the uncertain live debit")
        let meeting = try #require(try await shell.coordinator.historyStore()?.listMeetings().first)
        let retryBeforeRaise = await shell.coordinator.postMeetingAgent()?.generateArtifacts(
            meetingID: meeting.id)
        guard case .halted = retryBeforeRaise else {
            Issue.record("manual retry failed open after uncertain live debit")
            return
        }
        #expect(server.recordedRequests.isEmpty)

        let providers = shell.coordinator.providerSettingsModel()
        await providers.load()
        await providers.setCap(10)
        let retryAfterRaise = await shell.coordinator.postMeetingAgent()?.generateArtifacts(
            meetingID: meeting.id)
        guard case .drafted = retryAfterRaise else {
            Issue.record("manual retry did not recover after cap increase")
            return
        }
        #expect(server.recordedRequests.count == 1)
    }

    @Test func lazyPostMeetingMeterRetainsUncertainDebitAcrossManualRetry() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 500, body: OpenAIFixtures.errorBody(message: "temporary outage"))
        ])
        defer { server.stop() }
        let shell = try await makeShell(
            server: server,
            capUSD: nil,
            liveSpendLedger: FailingSpendLedger()
        )
        let meetings = try #require(shell.coordinator.historyStore())
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await meetings.append([
            Segment(
                id: UUID(), source: .mic, text: "I will send notes.",
                tStart: 0, tEnd: 1)
        ], to: meeting.id)
        try await meetings.endMeeting(id: meeting.id, endedAt: Date())

        let first = await shell.coordinator.postMeetingAgent()?.generateArtifacts(meetingID: meeting.id)
        guard case .failed = first else {
            Issue.record("expected the injected ledger failure, got \(String(describing: first))")
            return
        }
        #expect(server.recordedRequests.count == 1)
        #expect(await shell.coordinator.retainedSpendMeterCount() == 1)
        let uncertain = try #require(
            await shell.coordinator.retainedUncertainSpend(meetingID: meeting.id))
        #expect(uncertain > 0)
        let providers = shell.coordinator.providerSettingsModel()
        await providers.load()
        // One fresh reservation still fits under this cap. It is the retained
        // first-attempt debit that makes the retry fail admission.
        await providers.setCap(uncertain * 1.01)

        let retry = await shell.coordinator.postMeetingAgent()?.generateArtifacts(meetingID: meeting.id)
        guard case .halted = retry else {
            Issue.record("manual retry failed open after lazy meter uncertainty")
            return
        }
        #expect(server.recordedRequests.count == 1,
                "the retained uncertain debit must refuse retry before network")
        #expect(await shell.coordinator.retainedSpendMeterCount() == 1)
    }

    @Test func manualCleanupRetainsUncertaintyAndCannotStealConcurrentOwner() async throws {
        let server = try FakeOpenAIServer.start(responses: [])
        defer { server.stop() }
        let shell = try await makeShell(server: server)
        let pricing = PricingTable(rates: [
            "fake-model": ModelPricing(
                inputPerMillionUSD: 1,
                cachedInputPerMillionUSD: 0,
                outputPerMillionUSD: 1),
        ])

        let uncertainMeetingID = UUID()
        let uncertainMeter = SpendMeter(
            ledger: EphemeralSpendLedger(), pricing: pricing, capUSD: 1)
        let reservation = try await uncertainMeter.reserve(
            CompletionRequest(
                model: "fake-model",
                messages: [.user("manual retry")],
                purpose: .artifact,
                maxTokens: 100),
            meetingID: uncertainMeetingID
        )
        _ = try await uncertainMeter.settle(reservation, usage: nil)
        await shell.coordinator.retainSpendMeterForTesting(
            uncertainMeter, meetingID: uncertainMeetingID)
        await shell.coordinator.cleanupMeterAfterGeneration(
            meetingID: uncertainMeetingID,
            outcome: .failed(nil),
            expectedMeter: nil
        )
        #expect(await shell.coordinator.retainedSpendMeterCount() == 1,
                "a failed manual call's uncertain debit must remain retained")
        await shell.coordinator.cleanupMeterAfterGeneration(
            meetingID: uncertainMeetingID,
            outcome: .drafted([]),
            expectedMeter: nil
        )
        #expect(await shell.coordinator.retainedSpendMeterCount() == 0,
                "a successful owner has no retry path and releases even an uncertain meter")

        let concurrentMeetingID = UUID()
        let concurrentOwner = SpendMeter(
            ledger: EphemeralSpendLedger(), pricing: pricing, capUSD: 1)
        await shell.coordinator.retainSpendMeterForTesting(
            concurrentOwner, meetingID: concurrentMeetingID)
        await shell.coordinator.cleanupMeterAfterGeneration(
            meetingID: concurrentMeetingID,
            outcome: .skippedGenerationInFlight,
            expectedMeter: nil
        )
        #expect(await shell.coordinator.retainedSpendMeterCount() == 1,
                "the losing caller must not remove the meter owned by active generation")

        await shell.coordinator.cleanupMeterAfterGeneration(
            meetingID: concurrentMeetingID,
            outcome: .drafted([]),
            expectedMeter: nil
        )
        #expect(await shell.coordinator.retainedSpendMeterCount() == 0,
                "the successful owner releases its fallback meter")
    }

    @Test func aiOffCannotLeakEphemeralMeterOwnedByCancelledArtifactTask() async throws {
        let server = try FakeOpenAIServer.start(responses: [])
        defer { server.stop() }
        let ledger = BlockingClassifierLedger()
        let shell = try await makeShell(
            server: server,
            ephemeral: true,
            liveProvider: DeterministicLiveProvider(),
            liveSpendLedger: ledger
        )
        shell.coordinator.toggleSession()
        await shell.coordinator.settle()
        for _ in 0..<300 where !(await ledger.classifierSettlementStarted) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await ledger.classifierSettlementStarted)

        shell.coordinator.toggleSession()
        await shell.coordinator.settleCaptureLifecycle()
        #expect(await shell.coordinator.retainedSpendMeterCount() == 1)
        let settings = shell.coordinator.liveAISettingsModel()
        await settings.load()
        await settings.setEnabled(false)
        await ledger.releaseClassifierSettlement()
        await shell.coordinator.settle()

        #expect(await shell.coordinator.retainedSpendMeterCount() == 0,
                "ephemeral cleanup must outlive artifact-task cancellation")
        #expect(server.recordedRequests.isEmpty)
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
        #expect(manual == .cancelled)
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

    @Test func aiOffLatchBlocksTwoChainedArtifactsWhilePersistenceIsBlockedAndFails() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.artifact, Self.artifact])
        defer { server.stop() }
        let ledger = BlockingClassifierLedger()
        let settingsSave = BlockingFailingSettingsSave()
        let shell = try await makeShell(
            server: server,
            liveProvider: DeterministicLiveProvider(),
            liveSpendLedger: ledger,
            liveSettingsSaveOverride: { try await settingsSave.save($0) }
        )

        // Meeting A ends with its live classifier debit still settlement-gated.
        // Its automatic artifacts therefore have not reached the lazy agent.
        shell.coordinator.toggleSession()
        await shell.coordinator.settleCaptureLifecycle()
        for _ in 0..<300 where !(await ledger.classifierSettlementStarted) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await ledger.classifierSettlementStarted)
        shell.coordinator.toggleSession()
        await shell.coordinator.settleCaptureLifecycle()

        // Meeting B starts and ends while A's artifact tail is still held, so
        // its own artifact task is chained behind A.
        shell.coordinator.toggleSession()
        await shell.coordinator.settleCaptureLifecycle()
        shell.coordinator.toggleSession()
        await shell.coordinator.settleCaptureLifecycle()
        let meetings = try #require(shell.coordinator.historyStore())
        let ended = try await meetings.listMeetings()
        #expect(ended.count == 2)
        #expect(server.recordedRequests.isEmpty)

        let live = shell.coordinator.liveAISettingsModel()
        await live.load()
        let turnOff = Task { await live.setEnabled(false) }
        for _ in 0..<300 where !(await settingsSave.started) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await settingsSave.started)

        // The durable settings row is still enabled and this save will fail.
        // Releasing A must nevertheless create a disabled lazy agent and keep
        // both old tasks at zero network/zero writes.
        await ledger.releaseClassifierSettlement()
        await settingsSave.release()
        await turnOff.value
        await shell.coordinator.settle()

        #expect(server.recordedRequests.isEmpty)
        for meeting in ended {
            #expect(try await shell.coordinator.artifactStore()?.artifacts(for: meeting.id).isEmpty == true)
        }
        #expect((try await shell.coordinator.settingsStore()?.liveAISettings().aiFeaturesEnabled) == true,
                "failed persistence must not weaken the in-memory off latch")
    }

    @Test func aiOffThenOnCannotResurrectOldOrDisabledAdmissionArtifactTails() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.artifact, Self.artifact])
        defer { server.stop() }
        let ledger = BlockingClassifierLedger()
        let shell = try await makeShell(
            server: server,
            liveProvider: DeterministicLiveProvider(),
            liveSpendLedger: ledger
        )

        // Meeting A's automatic tail is admitted while AI is enabled, then
        // held behind its live classifier settlement.
        shell.coordinator.toggleSession()
        await shell.coordinator.settleCaptureLifecycle()
        for _ in 0..<300 where !(await ledger.classifierSettlementStarted) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await ledger.classifierSettlementStarted)
        shell.coordinator.toggleSession()
        await shell.coordinator.settleCaptureLifecycle()

        let live = shell.coordinator.liveAISettingsModel()
        await live.load()
        await live.setEnabled(false)

        // Meeting B starts and ends while AI is off. Its tail is chained
        // behind A but is permanently marked disabled-at-admission.
        shell.coordinator.toggleSession()
        await shell.coordinator.settleCaptureLifecycle()
        shell.coordinator.toggleSession()
        await shell.coordinator.settleCaptureLifecycle()
        let meetings = try #require(shell.coordinator.historyStore())
        let ended = try await meetings.listMeetings()
        #expect(ended.count == 2)

        // Re-enable before either tail can run. A's revision is stale and B
        // was created while disabled, so neither may cross provider admission.
        await live.setEnabled(true)
        await ledger.releaseClassifierSettlement()
        await shell.coordinator.settle()

        #expect(server.recordedRequests.isEmpty)
        for meeting in ended {
            #expect(try await shell.coordinator.artifactStore()?
                .artifacts(for: meeting.id).isEmpty == true)
        }
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
