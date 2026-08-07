import AVFoundation
import CaptureKit
import Foundation
import PersistKit
import Testing
import TranscribeKit

@testable import AppShell

/// Slice-4 checks 6 (MemoryFootprint sanity) and 12 (diagnostics wiring):
/// the memory reading is real, the tile formatting is pinned, and a stalled
/// engine's evictions reach the pipeline's coordinator-facing counter exactly.
@Suite(.serialized)
struct DiagnosticsTests {

    // MARK: - Check 6: MemoryFootprint sanity

    @Test func footprintReadsPositive() {
        let bytes = MemoryFootprint.currentBytes()
        #expect(bytes != nil)
        #expect(bytes! > 0)
    }

    @Test func touchingSixtyFourMegabytesRaisesTheFootprint() {
        let before = MemoryFootprint.currentBytes()!
        let size = 64 * 1_048_576
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { allocation.deallocate() }
        // Touch every page so the pages become resident — allocation alone
        // reserves address space, not physical footprint.
        memset(allocation, 0x5A, size)
        let after = MemoryFootprint.currentBytes()!
        #expect(after >= before + 48 * 1_048_576)
    }

    // MARK: - Check 12: tile formatting pins

    @Test func formattingIsPinned() {
        #expect(DiagnosticsFormat.ms(32.94) == "32.9")
        #expect(DiagnosticsFormat.ms(85.351) == "85.4")
        #expect(DiagnosticsFormat.ms(0) == "0.0")
        #expect(DiagnosticsFormat.mb(212 * 1_048_576) == "212")
        #expect(DiagnosticsFormat.mb(212 * 1_048_576 + 524_288) == "212")
        #expect(DiagnosticsFormat.mb(0) == "0")
        #expect(DiagnosticsFormat.reserved == "—")
    }

    // MARK: - Check 12: stalled engine → exact drop count at the seam

    /// The realistic stall: holds the audio stream alive (as a wedged real
    /// analyzer would) but never drains it, so the bounded branch evicts.
    /// Ends its event stream immediately so `stop()` isn't blocked on events
    /// that will never come.
    private struct StallingEngine: STTEngine {
        private final class Holder: @unchecked Sendable {
            private let lock = NSLock()
            private var held: [AsyncStream<AudioChunk>] = []
            func hold(_ stream: AsyncStream<AudioChunk>) {
                lock.withLock { held.append(stream) }
            }
        }

        private let holder = Holder()

        func prepare(locale: Locale) async throws {}

        func preferredInputFormat() async throws -> AVAudioFormat {
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        }

        func transcribe(
            _ audio: AsyncStream<AudioChunk>, source: AudioSource
        ) -> AsyncThrowingStream<TranscriptEvent, Error> {
            holder.hold(audio)  // alive but never drained — the stall
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
    }

    /// Yields a scripted number of chunks on start, finishes on stop().
    private actor ScriptedSource: AudioCaptureSource {
        nonisolated let source: AudioSource = .mic
        private let chunkCount: Int
        private var continuation: AsyncStream<AudioChunk>.Continuation?

        init(chunkCount: Int) {
            self.chunkCount = chunkCount
        }

        func start(format: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
            let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
            self.continuation = continuation
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
            buffer.frameLength = 8
            for _ in 0..<chunkCount {
                continuation.yield(AudioChunk(buffer: buffer, time: nil))
            }
            return stream
        }

        func pause() async {}
        func resume() async {}

        func stop() async {
            continuation?.finish()
            continuation = nil
        }
    }

    @MainActor
    @Test func stalledEngineDropCountIsExactAtTheCoordinatorSeam() async throws {
        let store = TranscriptStore()
        let chunkCount = 350
        let pipeline = MeetingPipeline(
            engine: StallingEngine(),
            sources: [ScriptedSource(chunkCount: chunkCount)],
            store: store
        )
        try await pipeline.start(mode: .ephemeral)
        _ = await pipeline.stop()

        // One source, one STT branch, bound = default 100: everything beyond
        // the newest 100 was evicted, and the count survives stop().
        #expect(pipeline.droppedChunks == chunkCount - BoundedAudioFanOut.defaultBound)
    }
}
