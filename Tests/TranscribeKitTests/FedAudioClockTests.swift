import AVFoundation
import CaptureKit
import Testing
import TranscribeKit

struct FedAudioClockTests {
    private func chunk(frames: AVAudioFrameCount, sampleRate: Double = 16_000) -> AudioChunk {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return AudioChunk(buffer: buffer)
    }

    @Test func sourcesAdvanceIndependentlyWithoutDoubleCounting() {
        let clock = FedAudioClock()
        clock.record(chunk(frames: 16_000), source: .mic)
        clock.record(chunk(frames: 8_000), source: .system)

        #expect(clock.seconds(for: .mic) == 1)
        #expect(clock.seconds(for: .system) == 0.5)
        #expect(clock.clampedEventEnd(9, source: .mic) == 1)
        #expect(clock.clampedEventEnd(9, source: .system) == 0.5)
    }

    @Test func clampCannotMoveNegativeOrFutureEventAnchorsOutsideFedRange() {
        let clock = FedAudioClock()
        clock.record(chunk(frames: 4_000), source: .mic)
        #expect(clock.clampedEventEnd(-2, source: .mic) == 0)
        #expect(clock.clampedEventEnd(0.1, source: .mic) == 0.1)
        #expect(clock.clampedEventEnd(2, source: .mic) == 0.25)
        #expect(clock.clampedEventEnd(2, source: .system) == 0)
    }
}
