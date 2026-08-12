import AgentKit
import AVFoundation
import CaptureKit
import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing
import TranscribeKit

@testable import AppShell

private final class DiagnosticsSteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]

    init(_ values: [Date]) { self.values = values }

    func now() -> Date {
        lock.withLock {
            values.isEmpty ? Date(timeIntervalSince1970: 0) : values.removeFirst()
        }
    }
}

private struct DiagnosticsCopilotProvider: LLMProvider {
    let decisionJSON: String
    let text: String

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.token(text))
            continuation.yield(.completed(Completion(
                finishReason: "stop",
                usage: TokenUsage(promptTokens: 5, completionTokens: 2)
            )))
            continuation.finish()
        }
    }

    func completeReportingUsage<T: Decodable>(
        _ request: CompletionRequest,
        as type: T.Type
    ) async throws -> CompletedCall<T> {
        CompletedCall(
            value: try JSONDecoder().decode(type, from: Data(decisionJSON.utf8)),
            usage: TokenUsage(promptTokens: 5, completionTokens: 2)
        )
    }
}

@MainActor
struct LiveDiagnosticsTests {
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

    private func turn(_ text: String = "Hoang, can you explain the migration risk?") -> TranscriptTurn {
        TranscriptTurn(
            source: .system,
            text: text,
            segmentIDs: [UUID()],
            tStart: 60,
            tEnd: 62
        )
    }

    @Test(arguments: [
        ("suggest_answer", "migration risk"),
        ("flag_commitment", "Send the runbook Friday"),
    ])
    func g2RunsFromAdmissionToWinningFirstTokenForBothProactiveActions(
        action: String,
        target: String
    ) async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = DiagnosticsSteppingClock([
            start,
            start.addingTimeInterval(0.345),
        ])
        let recorder = SuggestionLatencyRecorder()
        let provider = DiagnosticsCopilotProvider(
            decisionJSON:
                "{\"action\":\"\(action)\",\"confidence\":0.97,\"target\":\"\(target)\"}",
            text: "Visible output"
        )
        let model = LiveCopilotModel(
            suggestionLatencyRecorder: recorder,
            diagnosticsNow: clock.now
        )
        model.beginMeeting(
            provider: provider,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings(preferredName: "Hoang")
        )

        await model.receive(turn(), userSpeaking: false)
        await waitUntil("proactive output") { model.card?.isStreaming == false }

        let report = recorder.report()
        #expect(report.count == 1)
        #expect(abs(report.p95Ms - 345) < 0.001)
        #expect(report.pendingCount == 0)
        #expect(report.excludedNegativeCount == 0)

        model.stopMeeting()
        #expect(recorder.report().count == 1, "ended meeting remains visible")
        model.beginMeeting(
            provider: nil,
            fastModel: "fast",
            deepModel: "deep",
            settings: LiveAISettings()
        )
        #expect(recorder.report().totalTriggerCount == 0, "new meeting resets G2")
    }

    @Test func midstreamSTTFailureAndEndedMeetingValuesReachOneCoherentSnapshot() async throws {
        let counters = MeetingPipelineTests.Counters()
        let engine = MeetingPipelineTests.FakeSTTEngine(
            failMidStream: true,
            counters: counters
        )
        let source = MeetingPipelineTests.FakeCaptureSource(source: .mic, counters: counters)
        let database = try MacapyDatabase.inMemory()
        let coordinator = AppShellCoordinator(
            panel: MeetingPipelineTests.FakePanel(),
            installHotKey: false,
            makePipeline: { store in
                MeetingPipeline(engine: engine, sources: [source], store: store)
            },
            makeDatabase: { database }
        )

        coordinator.toggleSession()
        await waitUntil("pipeline returned idle") { coordinator.session.state == .idle }
        await coordinator.settle()

        let snapshot = await coordinator.diagnosticsSnapshot()
        #expect(snapshot.hasMeeting)
        #expect(snapshot.speech != nil)
        #expect(snapshot.sttErrorCount == 1)
        #expect(snapshot.droppedChunks == 0)
        #expect(snapshot.memoryBytes != nil)
        #expect(snapshot.artifactG3Seconds == nil)

        let repeated = await coordinator.diagnosticsSnapshot()
        #expect(repeated.sttErrorCount == snapshot.sttErrorCount)
        #expect(repeated.speech == snapshot.speech)
    }

    @Test func sttPreparationFailureIsCountedWithoutLosingTheEndedSnapshot() async throws {
        let counters = MeetingPipelineTests.Counters()
        let engine = MeetingPipelineTests.FakeSTTEngine(
            failPrepare: true,
            counters: counters
        )
        let source = MeetingPipelineTests.FakeCaptureSource(source: .mic, counters: counters)
        let database = try MacapyDatabase.inMemory()
        let coordinator = AppShellCoordinator(
            panel: MeetingPipelineTests.FakePanel(),
            installHotKey: false,
            makePipeline: { store in
                MeetingPipeline(engine: engine, sources: [source], store: store)
            },
            makeDatabase: { database }
        )

        coordinator.toggleSession()
        await waitUntil("prepare failure returned idle") {
            coordinator.session.state == .idle
        }
        await coordinator.settle()

        let snapshot = await coordinator.diagnosticsSnapshot()
        #expect(snapshot.hasMeeting)
        #expect(snapshot.sttErrorCount == 1)
    }

    @Test func successfulArtifactG3IsPolledWithoutIssuingADiagnosticsRequest() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 200, body: OpenAIFixtures.completionBody(
                content: #"{"summary":"Done","decisions":[],"action_items":[]}"#
            ))
        ])
        defer { server.stop() }
        let database = try MacapyDatabase.inMemory()
        let counters = MeetingPipelineTests.Counters()
        let segment = Segment(
            id: UUID(),
            source: .mic,
            text: "We agreed to ship Friday.",
            tStart: 0,
            tEnd: 1
        )
        let engine = MeetingPipelineTests.FakeSTTEngine(
            live: [.mic: [.final(segment)]],
            counters: counters
        )
        let source = MeetingPipelineTests.FakeCaptureSource(source: .mic, counters: counters)
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
        let settings = try #require(coordinator.settingsStore())
        try await settings.setProviderSettings(ProviderSettings(selectedProfileID: "fake"))

        coordinator.toggleSession()
        await coordinator.settle()
        coordinator.toggleSession()
        await coordinator.settle()

        #expect(server.recordedRequests.count == 1)
        let snapshot = await coordinator.diagnosticsSnapshot()
        #expect(snapshot.artifactG3Seconds != nil)
        #expect(snapshot.artifactG3Seconds! >= 0)
        #expect(server.recordedRequests.count == 1,
            "polling diagnostics must not make a provider request")
    }
}

private struct FedClockEventEngine: STTEngine {
    func prepare(locale: Locale) async throws {}

    func preferredInputFormat() async throws -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
    }

    func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        source: AudioSource
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await _ in audio {
                    continuation.yield(.volatile(text: "x", tStart: 0, tEnd: 999))
                    continuation.yield(.final(Segment(
                        id: UUID(), source: source, text: "x", tStart: 0, tEnd: 999)))
                    break
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor OneChunkSource: AudioCaptureSource {
    nonisolated let source: AudioSource

    init(source: AudioSource) { self.source = source }

    func start(format: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        return AsyncStream { continuation in
            continuation.yield(AudioChunk(buffer: buffer))
            continuation.finish()
        }
    }

    func pause() async {}
    func resume() async {}
    func stop() async {}
}

@MainActor
struct ProductionFedClockPipelineTests {
    @Test func realFanOutTapClampsEachSourceWithoutCombiningTheirDurations() async throws {
        let clock = FedAudioClock()
        let recorder = LatencyRecorder(sessionStart: Date())
        let pipeline = MeetingPipeline(
            engine: FedClockEventEngine(),
            sources: [OneChunkSource(source: .mic), OneChunkSource(source: .system)],
            store: TranscriptStore(),
            recorder: recorder,
            fedAudioClock: clock
        )
        try await pipeline.start(mode: .ephemeral)
        _ = await pipeline.stop()

        let expected = 1.0 / 16_000.0
        #expect(abs(clock.seconds(for: .mic) - expected) < 0.000_000_1)
        #expect(abs(clock.seconds(for: .system) - expected) < 0.000_000_1)
        let report = recorder.report()
        #expect(report.volatile.totalCount == 2)
        #expect(report.final.totalCount == 2)
        #expect(report.volatile.excludedNegativeCount == 0)
        #expect(report.final.excludedNegativeCount == 0)
    }
}
