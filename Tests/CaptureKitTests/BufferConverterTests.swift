import AVFoundation
import CaptureKit
import Foundation
import Testing

/// Check 2: `BufferConverter` turns a synthesized 48kHz float buffer into the
/// target format with the right format and a plausible frame count — no audio
/// hardware involved.
struct BufferConverterTests {

    private func floatFormat(_ sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    private func int16Format(_ sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    }

    /// Fills a buffer with a low-frequency sine so the converter has real signal.
    private func sineBuffer(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = sin(Float(i) * 0.05) * 0.5
        }
        return buffer
    }

    @Test func converts48kFloatTo16kInt16() throws {
        let input = floatFormat(48_000)
        let target = int16Format(16_000)
        let converter = try BufferConverter(from: input, to: target)

        let inFrames: AVAudioFrameCount = 4_800  // 0.1s @ 48kHz
        let out = try converter.convert(sineBuffer(input, frames: inFrames))

        #expect(out.format.sampleRate == 16_000)
        #expect(out.format.commonFormat == .pcmFormatInt16)
        #expect(out.format.channelCount == 1)

        // 3:1 downsample → ~1600 frames; allow slack for converter priming.
        #expect(out.frameLength > 1_400, "got \(out.frameLength)")
        #expect(out.frameLength < 1_800, "got \(out.frameLength)")
    }

    @Test func producesFreshOutputBufferPerConversion() throws {
        let input = floatFormat(48_000)
        let target = int16Format(16_000)
        let converter = try BufferConverter(from: input, to: target)

        let a = try converter.convert(sineBuffer(input, frames: 4_800))
        let b = try converter.convert(sineBuffer(input, frames: 4_800))
        // Distinct buffer objects — the ownership rule (producer never touches a
        // yielded buffer) holds because each conversion allocates its own output.
        #expect(a !== b)
    }

    @Test func convertsAcrossManyChunksWithoutError() throws {
        let input = floatFormat(48_000)
        let target = int16Format(16_000)
        let converter = try BufferConverter(from: input, to: target)

        var total: AVAudioFrameCount = 0
        for _ in 0..<10 {
            let out = try converter.convert(sineBuffer(input, frames: 4_800))
            total += out.frameLength
        }
        // 10 × 0.1s @ 16kHz ≈ 16000 frames, within priming slack.
        #expect(total > 15_000, "got \(total)")
        #expect(total < 17_000, "got \(total)")
    }
}
