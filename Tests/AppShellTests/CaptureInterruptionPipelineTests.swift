import AVFoundation
import CaptureKit
import Foundation
import PersistKit
import Testing
import TranscribeKit

@testable import AppShell

@MainActor
struct CaptureInterruptionPipelineTests {
    actor Source: AudioCaptureSource {
        nonisolated let source: AudioSource = .mic
        nonisolated let channel = CaptureInterruptionChannel()
        nonisolated var interruptions: AsyncStream<CaptureInterruption> { channel.stream() }
        private var reporter: CaptureInterruptionChannel.Reporter?
        private var continuation: AsyncStream<AudioChunk>.Continuation?
        func start(format: AVAudioFormat) -> AsyncStream<AudioChunk> {
            reporter = channel.begin(source: source)
            let made = AsyncStream<AudioChunk>.makeStream()
            continuation = made.continuation
            return made.stream
        }
        func emit(_ reason: CaptureInterruption.Reason) { reporter?(reason) }
        func stop() { channel.end(); continuation?.finish(); continuation = nil }
        func pause() {}
        func resume() { reporter?(.resumeFailed) }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Capture interruption did not reach the expected state")
    }

    @Test(arguments: [CaptureInterruption.Reason.routeChanged, .conversionFailed, .resumeFailed])
    func runtimeFailureStopsVisiblyAndDrainsTail(reason: CaptureInterruption.Reason) async throws {
        let source = Source()
        let live = Segment(id: UUID(), source: .mic, text: "Fictional live text.", tStart: 0, tEnd: 1)
        let tail = Segment(id: UUID(), source: .mic, text: "Fictional committed tail.", tStart: 1, tEnd: 2)
        let engine = MeetingPipelineTests.FakeSTTEngine(live: [.mic: [.final(live)]], drain: [.mic: [.final(tail)]], counters: .init())
        let coordinator = AppShellCoordinator(panel: MeetingPipelineTests.FakePanel(), installHotKey: false,
                                             makePipeline: { MeetingPipeline(engine: engine, sources: [source], store: $0) },
                                             makeDatabase: { try MacapyDatabase.inMemory() })
        coordinator.toggleSession()
        await coordinator.settleCaptureLifecycle()
        await source.emit(reason)
        await waitUntil { coordinator.session.failure != nil }
        await coordinator.settleCaptureLifecycle()
        #expect(coordinator.session.failure == (reason == .routeChanged ? .audioRoute : .captureInterrupted))
        #expect(!coordinator.session.isActive)
        let meetings = try #require(coordinator.historyStore())
        let meeting = try #require(try await meetings.listMeetings().first)
        #expect(try await meetings.segments(for: meeting.id).map(\.text) == [live.text, tail.text])
    }

    @Test func deliberateStopDoesNotBecomeAnUnexpectedEOFError() async throws {
        let source = Source()
        let engine = MeetingPipelineTests.FakeSTTEngine(counters: .init())
        let pipeline = MeetingPipeline(engine: engine, sources: [source], store: TranscriptStore())
        var errors = 0
        pipeline.onFailure = { _ in errors += 1 }
        try await pipeline.start(mode: .ephemeral)
        await pipeline.stop()
        #expect(errors == 0)
        #expect(pipeline.sttErrorCounter.count == 0)
    }

    @Test func unexpectedLiveEOFIsAVisibleFailure() async throws {
        struct Engine: STTEngine {
            func prepare(locale: Locale) async throws {}
            func preferredInputFormat() async throws -> AVAudioFormat {
                AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
            }
            func transcribe(_ audio: AsyncStream<AudioChunk>, source: AudioSource) -> AsyncThrowingStream<TranscriptEvent, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let pipeline = MeetingPipeline(engine: Engine(), sources: [Source()], store: TranscriptStore())
        var failure: SessionFailure?
        pipeline.onFailure = { failure = SessionFailure.classify($0) }
        try await pipeline.start(mode: .ephemeral)
        await waitUntil { failure != nil }
        #expect(failure == .captureInterrupted)
        await pipeline.stop()
    }
}
