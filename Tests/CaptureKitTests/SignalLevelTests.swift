import AVFoundation
import CaptureKit
import Foundation
import Testing

/// Slice-4 check 11: RMS is exact arithmetic over known signals, and the meter
/// hands the latest per-source level across isolation domains.
struct SignalLevelTests {

    private func int16Buffer(_ fill: (Int) -> Int16, frames: Int = 1600) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.int16ChannelData![0]
        for i in 0..<frames { channel[i] = fill(i) }
        return buffer
    }

    private func floatBuffer(_ fill: (Int) -> Float, frames: Int = 1600) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for i in 0..<frames { channel[i] = fill(i) }
        return buffer
    }

    @Test func silenceIsZero() {
        #expect(AudioLevel.rms(of: int16Buffer { _ in 0 }) == 0)
        #expect(AudioLevel.rms(of: floatBuffer { _ in 0 }) == 0)
    }

    @Test func emptyBufferIsZero() {
        let buffer = int16Buffer({ _ in 0 }, frames: 16)
        buffer.frameLength = 0
        #expect(AudioLevel.rms(of: buffer) == 0)
    }

    @Test func constantAmplitudeIsThatAmplitude() {
        // Int16 16384 = 0.5 full-scale.
        let level = AudioLevel.rms(of: int16Buffer { _ in 16_384 })
        #expect(abs(level - 0.5) < 0.001)

        let floatLevel = AudioLevel.rms(of: floatBuffer { _ in 0.25 })
        #expect(abs(floatLevel - 0.25) < 0.0001)
    }

    @Test func sineIsAmplitudeOverSqrtTwo() {
        // Whole periods so the discrete RMS matches a/√2 tightly: 100 cycles
        // over 1600 samples.
        let amplitude: Float = 0.8
        let level = AudioLevel.rms(of: floatBuffer { i in
            amplitude * sin(Float(i) * 2 * .pi * 100 / 1600)
        })
        #expect(abs(level - amplitude / Float(2.0.squareRoot())) < 0.005)
    }

    @Test func meterReturnsLatestLevelPerSource() {
        let meter = SignalLevelMeter()
        #expect(meter.level(for: .mic) == 0)

        meter.record(source: .mic, level: 0.4)
        meter.record(source: .system, level: 0.7)
        meter.record(source: .mic, level: 0.1)

        #expect(meter.level(for: .mic) == 0.1)
        #expect(meter.level(for: .system) == 0.7)

        meter.reset()
        #expect(meter.level(for: .mic) == 0)
        #expect(meter.level(for: .system) == 0)
    }

    @Test func meterSurvivesConcurrentRecordAndPoll() async {
        let meter = SignalLevelMeter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for i in 0..<2_000 {
                        meter.record(source: i.isMultiple(of: 2) ? .mic : .system, level: Float(i % 100) / 100)
                    }
                }
                group.addTask {
                    for _ in 0..<2_000 {
                        let level = meter.level(for: .mic)
                        #expect(level >= 0 && level < 1)
                    }
                }
            }
        }
    }
}
