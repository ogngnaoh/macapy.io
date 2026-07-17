import AVFoundation
import CaptureKit
import Foundation
import Testing

/// Check 2 (slice 5): `FixturePlaybackSource` paces a fixture wav in real
/// time against a `ContinuousClock` — N seconds of audio take ≈N wall
/// seconds, not "as fast as the disk can read" — honors pause/resume/stop,
/// and finishes its stream at end-of-file. The fixture is synthesized at
/// test time (a short sine tone written via `AVAudioFile`), not committed:
/// this suite cares about pacing, not transcription content, so there's no
/// reason to carry another binary for it.
struct FixturePlaybackSourceTests {

    private func targetFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    }

    /// Writes `seconds` of a low sine tone to a temp 16kHz mono Int16 wav.
    /// `AVAudioFile` is scoped to this function so its close/flush (via
    /// deinit) runs before the caller reads the file back — without that,
    /// the file can read back as zero-length (verified empirically while
    /// building this test).
    private func writeSineFixture(seconds: Double) throws -> URL {
        let format = targetFormat()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frameCount = AVAudioFrameCount((seconds * format.sampleRate).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw CaptureError.formatUnavailable
        }
        buffer.frameLength = frameCount
        let channel = buffer.int16ChannelData![0]
        for i in 0..<Int(frameCount) {
            channel[i] = Int16(sin(Double(i) * 0.05) * 8_000)
        }
        try file.write(from: buffer)
        return url
    }

    @Test func deliversAudioInApproximatelyRealTimeAndFinishesAtEOF() async throws {
        let duration = 1.6
        let url = try writeSineFixture(seconds: duration)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FixturePlaybackSource(fixtureURL: url, chunkDuration: 0.1)
        let clock = ContinuousClock()
        let started = clock.now
        let audio = try await source.start(format: targetFormat())

        var chunkCount = 0
        var totalFrames: AVAudioFrameCount = 0
        for await chunk in audio {
            chunkCount += 1
            totalFrames += chunk.buffer.frameLength
        }
        let elapsed = started.duration(to: clock.now)

        #expect(chunkCount >= 14, "expected ~16 chunks of a 1.6s fixture at 0.1s each, got \(chunkCount)")
        // Bounded tolerance (flagged for verifier scrutiny in the build
        // report): pacing sleeps target ≈real-time, but read/convert
        // overhead and scheduler jitter both push wall time slightly above
        // the audio duration, essentially never below it.
        #expect(elapsed >= .milliseconds(Int((duration - 0.3) * 1_000)), "finished too fast: \(elapsed)")
        #expect(elapsed <= .milliseconds(Int((duration + 1.5) * 1_000)), "finished too slow: \(elapsed)")

        let totalSeconds = Double(totalFrames) / targetFormat().sampleRate
        #expect(totalSeconds > duration - 0.2 && totalSeconds < duration + 0.2, "got \(totalSeconds)s of audio")

        await source.stop()
    }

    @Test func pauseSuspendsPacingAndResumeContinues() async throws {
        let duration = 2.0
        let url = try writeSineFixture(seconds: duration)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FixturePlaybackSource(fixtureURL: url, chunkDuration: 0.1)
        let audio = try await source.start(format: targetFormat())

        let counter = ChunkCounter()
        let consumerTask = Task {
            for await _ in audio {
                await counter.increment()
            }
        }

        // Let a couple of chunks flow, then pause.
        try await Task.sleep(for: .milliseconds(250))
        await source.pause()

        // `pause()` only takes effect at the top of the playback loop's
        // next iteration — it doesn't interrupt a chunk that was already
        // read/converted and is mid-sleep toward its own real-time target
        // (post-fix, a chunk sleeps to its own end-time *before* being
        // yielded, so up to one such chunk can legitimately still land
        // shortly after `pause()` was called). Give that one straggler a
        // window to land, then assert pacing has *truly* suspended: two
        // samples spaced well apart must be equal.
        try await Task.sleep(for: .milliseconds(150))
        let countA = await counter.count
        try await Task.sleep(for: .milliseconds(400))
        let countB = await counter.count
        #expect(countB == countA, "chunks kept arriving while paused: \(countA) -> \(countB)")

        await source.resume()
        _ = await consumerTask.value  // drains to EOF now that pacing has resumed

        let finalCount = await counter.count
        #expect(finalCount > countB, "playback should continue delivering chunks after resume")

        await source.stop()
    }

    @Test func stopFinishesTheStreamEarly() async throws {
        let duration = 3.0  // long enough that "stop after one chunk" is clearly early
        let url = try writeSineFixture(seconds: duration)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FixturePlaybackSource(fixtureURL: url, chunkDuration: 0.1)
        let audio = try await source.start(format: targetFormat())
        var iterator = audio.makeAsyncIterator()
        _ = await iterator.next()  // first chunk arrives

        await source.stop()

        var remaining = 0
        while await iterator.next() != nil {
            remaining += 1
        }
        #expect(
            remaining < 25,
            "stop() should end the stream well before all ~30 chunks are delivered, got \(remaining) more")
    }

    /// Check (slice-5 blocker fix): a chunk covering audio up to position
    /// `k·chunkDuration` must not become observable before wall-clock has
    /// actually reached (close to) that position — otherwise the consumer
    /// sees audio "from the future" relative to real-time pacing. This is
    /// the precise regression the negative-latency blocker traced to:
    /// yielding a chunk *before* sleeping to pace it (instead of after)
    /// delivered every chunk ~one whole `chunkDuration` early, throughout
    /// the entire stream, not just at startup. None of the other tests in
    /// this suite catch it — they only assert *aggregate* drain time, which
    /// is unaffected by this bug (only *individual* chunk arrival timing
    /// is). The threshold below is deliberately set halfway between the
    /// buggy behavior (chunk k at ~`(k-1)·Δ`) and the correct one (chunk k
    /// at ~`k·Δ`), so it actually discriminates rather than passing either
    /// way — verified red against the pre-fix ordering before the fix
    /// landed (see the builder report for the red run).
    @Test func chunksAreNotDeliveredBeforeTheirOwnAudioDurationHasElapsed() async throws {
        let duration = 1.2
        let chunkDuration = 0.1
        let url = try writeSineFixture(seconds: duration)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FixturePlaybackSource(fixtureURL: url, chunkDuration: chunkDuration)
        let clock = ContinuousClock()
        let started = clock.now
        let audio = try await source.start(format: targetFormat())

        var chunkIndex = 0
        for await _ in audio {
            chunkIndex += 1
            let elapsedSinceStart = started.duration(to: clock.now)
            let midpointThreshold = (Double(chunkIndex) - 0.5) * chunkDuration - 0.02  // 20ms scheduling slack
            #expect(
                elapsedSinceStart >= .milliseconds(Int(midpointThreshold * 1_000)),
                "chunk \(chunkIndex) arrived at \(elapsedSinceStart) since start, expected >= \(midpointThreshold)s (too early)"
            )
        }

        await source.stop()
    }

    private actor ChunkCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }
}
