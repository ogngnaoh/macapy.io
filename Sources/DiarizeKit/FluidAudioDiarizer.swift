import AVFoundation
import CaptureKit
import FluidAudio
import Foundation

/// The one production `DiarizationEngine` (slice-4 decision 1): FluidAudio's
/// offline pipeline fed in ~10s windows. `DiarizerManager` keeps its
/// `SpeakerManager` across `performCompleteDiarization(_:atTime:)` calls, so
/// speaker keys stay stable window-to-window — empirically confirmed by the
/// Phase-0 gate (windowed and whole-file runs attributed identically).
/// Memory is O(window); the session clock is cumulative fed duration, matching
/// the analyzer's timeline (audio is fed contiguously, `AudioChunk.time` is
/// nil by design).
public actor FluidAudioDiarizer: DiarizationEngine {
    private let manager: DiarizerManager
    private let windowSamples: Int
    /// Tail shorter than this at `finish()` is dropped — the segmentation
    /// model works on 10s chunks and a sub-second tail yields noise, not turns.
    private let minimumTailSamples = 16_000  // 1s
    private static let sampleRate = 16_000

    private var pending: [Float] = []
    private var windowStart: TimeInterval = 0
    /// Latest embedding per speaker key (persisted to `speakers.embedding`).
    private var embeddings: [String: [Float]] = [:]
    private var converter: BufferConverter?
    private var converterSourceFormat: AVAudioFormat?

    /// Loads the installed models — never downloads (`DiarizationModelStore`).
    /// Throws if the models aren't on disk; callers gate on `isInstalled`.
    public init(windowSeconds: TimeInterval = 10) throws {
        let manager = DiarizerManager()
        manager.initialize(models: try DiarizationModelStore.loadInstalled())
        self.manager = manager
        self.windowSamples = Int(windowSeconds * Double(Self.sampleRate))
    }

    public func ingest(_ chunk: AudioChunk) async throws -> [SpeakerTurn] {
        pending.append(contentsOf: try samples(from: chunk.buffer))
        guard pending.count >= windowSamples else { return [] }
        return try flushWindow()
    }

    public func finish() async throws -> (turns: [SpeakerTurn], embeddings: [String: Data]) {
        var turns: [SpeakerTurn] = []
        if pending.count >= minimumTailSamples {
            turns = try flushWindow()
        }
        let embeddingData = embeddings.mapValues { floats in
            floats.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        return (turns, embeddingData)
    }

    private func flushWindow() throws -> [SpeakerTurn] {
        let result = try manager.performCompleteDiarization(pending, atTime: windowStart)
        windowStart += Double(pending.count) / Double(Self.sampleRate)
        pending.removeAll(keepingCapacity: true)
        for segment in result.segments {
            embeddings[segment.speakerId] = segment.embedding
        }
        return result.segments.map {
            SpeakerTurn(
                speakerKey: $0.speakerId,
                tStart: TimeInterval($0.startTimeSeconds),
                tEnd: TimeInterval($0.endTimeSeconds)
            )
        }
    }

    /// Defensive format handling (SPEC §6.5 amendment 1: formats are queried,
    /// not assumed): 16k mono Int16 — the analyzer format both capture sources
    /// actually produce — and 16k mono Float32 read directly; anything else
    /// goes through a real `AVAudioConverter`.
    private func samples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let format = buffer.format
        if Int(format.sampleRate) == Self.sampleRate, format.channelCount == 1 {
            let frames = Int(buffer.frameLength)
            if let int16 = buffer.int16ChannelData {
                let channel = int16[0]
                return (0..<frames).map { Float(channel[$0]) / 32_768 }
            }
            if let float = buffer.floatChannelData {
                return Array(UnsafeBufferPointer(start: float[0], count: frames))
            }
        }
        return try convert(buffer)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate),
            channels: 1, interleaved: false)
        else { throw CaptureError.formatUnavailable }
        if converter == nil || converterSourceFormat != buffer.format {
            converter = try BufferConverter(from: buffer.format, to: target)
            converterSourceFormat = buffer.format
        }
        let converted = try converter!.convert(buffer)
        let frames = Int(converted.frameLength)
        guard let channel = converted.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: frames))
    }
}
