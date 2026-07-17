import AVFoundation
import CaptureKit
import Foundation
import Testing
import TranscribeKit

@testable import AppShell

/// Check 4: the AppShell seam. `FakeSTTEngine` + `FakeCaptureSource` drive the
/// real `MeetingPipeline`/`AppShellCoordinator` with no audio hardware, no mic
/// TCC, and no app launch (a fake panel stands in for the NSPanel).
@MainActor
struct MeetingPipelineTests {

    // MARK: - Test doubles

    /// Shared, thread-safe call counters for the fakes.
    actor Counters {
        private(set) var captureStarts = 0
        private(set) var transcribeCalls = 0
        func captureStarted() { captureStarts += 1 }
        func transcribeCalled() { transcribeCalls += 1 }
    }

    enum FakeEngineError: Error { case prepareFailed, midStream }

    /// Emits scripted events immediately (`live`), then — once the capture
    /// stream finishes (i.e. `stop()`) — emits `drain`, then finishes. Can be
    /// configured to fail in `prepare()` or mid-stream, and to start slowly.
    struct FakeSTTEngine: STTEngine {
        var live: [AudioSource: [TranscriptEvent]] = [:]
        var drain: [AudioSource: [TranscriptEvent]] = [:]
        var failPrepare = false
        var failMidStream = false
        var prepareDelayNanos: UInt64 = 0
        let counters: Counters

        func prepare(locale: Locale) async throws {
            if prepareDelayNanos > 0 { try? await Task.sleep(nanoseconds: prepareDelayNanos) }
            if failPrepare { throw FakeEngineError.prepareFailed }
        }

        func preferredInputFormat() async throws -> AVAudioFormat {
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        }

        func transcribe(
            _ audio: AsyncStream<AudioChunk>, source: AudioSource
        ) -> AsyncThrowingStream<TranscriptEvent, Error> {
            let live = self.live[source] ?? []
            let drain = self.drain[source] ?? []
            let failMidStream = self.failMidStream
            let counters = self.counters
            return AsyncThrowingStream { continuation in
                let task = Task {
                    await counters.transcribeCalled()
                    for event in live { continuation.yield(event) }
                    if failMidStream {
                        continuation.finish(throwing: FakeEngineError.midStream)
                        return
                    }
                    // Wait for the capture stream to end (stop()).
                    for await _ in audio {}
                    for event in drain { continuation.yield(event) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// Actor capture source whose audio stream finishes on `stop()`.
    actor FakeCaptureSource: AudioCaptureSource {
        nonisolated let source: AudioSource
        private let counters: Counters
        private var continuation: AsyncStream<AudioChunk>.Continuation?

        init(source: AudioSource, counters: Counters) {
            self.source = source
            self.counters = counters
        }

        func start(format: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
            await counters.captureStarted()
            let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
            self.continuation = continuation
            return stream
        }

        func pause() async {}
        func resume() async {}
        func stop() async {
            continuation?.finish()
            continuation = nil
        }
    }

    /// No-op panel so the coordinator never builds an NSPanel/NSHostingView.
    final class FakePanel: PanelPresenting {
        private(set) var shown = false
        func show(session: SessionController, store: TranscriptStore) { shown = true }
        func hide() { shown = false }
    }

    // MARK: - Helpers

    private func makeCoordinator(
        engine: FakeSTTEngine, source: FakeCaptureSource
    ) -> AppShellCoordinator {
        AppShellCoordinator(panel: FakePanel(), installHotKey: false) { store in
            MeetingPipeline(engine: engine, sources: [source], store: store)
        }
    }

    private func seg(_ text: String, _ source: AudioSource, _ t: TimeInterval) -> Segment {
        Segment(id: UUID(), source: source, text: text, tStart: t, tEnd: t + 1)
    }

    /// Polls a MainActor condition up to ~3s.
    @discardableResult
    private func waitUntil(_ label: String, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("timed out waiting for: \(label)")
        return false
    }

    // MARK: - Checks

    @Test func startPopulatesStoreFromScriptedEvents() async {
        let counters = Counters()
        let engine = FakeSTTEngine(
            live: [.mic: [
                .volatile(text: "hel", tStart: 0, tEnd: 1),
                .final(seg("hello world", .mic, 0)),
            ]],
            counters: counters
        )
        let source = FakeCaptureSource(source: .mic, counters: counters)
        let coordinator = makeCoordinator(engine: engine, source: source)

        coordinator.toggleSession()  // start
        #expect(coordinator.session.isCapturing)
        await waitUntil("segment applied") { coordinator.store.segments.map(\.text) == ["hello world"] }
        #expect(coordinator.store.segments.map(\.text) == ["hello world"])

        coordinator.toggleSession()  // stop
        await coordinator.settle()
    }

    @Test func stopDrainsPendingFinals() async {
        let counters = Counters()
        let engine = FakeSTTEngine(
            live: [.mic: [.final(seg("live", .mic, 0))]],
            drain: [.mic: [.final(seg("drained", .mic, 1))]],
            counters: counters
        )
        let source = FakeCaptureSource(source: .mic, counters: counters)
        let coordinator = makeCoordinator(engine: engine, source: source)

        coordinator.toggleSession()  // start
        await waitUntil("live final applied") { coordinator.store.segments.map(\.text) == ["live"] }

        coordinator.toggleSession()  // stop → capture finishes → drain flushed
        await coordinator.settle()
        #expect(coordinator.session.state == .idle)
        #expect(coordinator.store.segments.map(\.text) == ["live", "drained"])
    }

    @Test func engineErrorReturnsSessionToIdle() async {
        let counters = Counters()
        var engine = FakeSTTEngine(counters: counters)
        engine.failPrepare = true
        let source = FakeCaptureSource(source: .mic, counters: counters)
        let coordinator = makeCoordinator(engine: engine, source: source)

        coordinator.toggleSession()  // start → prepare throws
        await waitUntil("returned to idle") { coordinator.session.state == .idle }
        #expect(coordinator.session.state == .idle)
        #expect(coordinator.store.segments.isEmpty)
    }

    @Test func midStreamEngineErrorReturnsSessionToIdle() async {
        let counters = Counters()
        var engine = FakeSTTEngine(
            live: [.mic: [.final(seg("partial", .mic, 0))]],
            counters: counters
        )
        engine.failMidStream = true
        let source = FakeCaptureSource(source: .mic, counters: counters)
        let coordinator = makeCoordinator(engine: engine, source: source)

        coordinator.toggleSession()  // start → emits one final, then stream errors
        await waitUntil("returned to idle after mid-stream error") { coordinator.session.state == .idle }
        #expect(coordinator.session.state == .idle)
    }

    @Test func rapidTogglesNeverWedgeOrDoubleStart() async {
        let counters = Counters()
        var engine = FakeSTTEngine(
            live: [.mic: [.final(seg("x", .mic, 0))]],
            counters: counters
        )
        engine.prepareDelayNanos = 30_000_000  // slow-starting: 30ms
        let source = FakeCaptureSource(source: .mic, counters: counters)
        let coordinator = makeCoordinator(engine: engine, source: source)

        // Churn: on/off pairs, ending idle.
        for _ in 0..<8 {
            coordinator.toggleSession()  // on
            coordinator.toggleSession()  // off
        }
        await coordinator.settle()
        #expect(coordinator.session.state == .idle, "churn must settle to idle")

        // Never double-started a single logical session: at most one transcribe
        // per on-transition, and each pipeline starts capture at most once.
        let transcribeCalls = await counters.transcribeCalls
        let captureStarts = await counters.captureStarts
        #expect(transcribeCalls <= 8, "double-start detected: \(transcribeCalls) transcribe calls")
        #expect(captureStarts <= 8, "double-start detected: \(captureStarts) capture starts")

        // Not wedged: a clean start still works afterward.
        coordinator.toggleSession()  // on
        await waitUntil("post-churn start works") { coordinator.store.segments.map(\.text) == ["x"] }
        #expect(coordinator.session.isCapturing)

        coordinator.toggleSession()  // off
        await coordinator.settle()
    }
}
