import AVFoundation
import CaptureKit
import Foundation
import TranscribeKit
import os

/// Orchestrates one meeting's capture → transcription → store flow. `@MainActor`
/// (created and torn down from the coordinator). Owns per-source event tasks
/// that apply `TranscriptEvent`s to the store; `stop()` finishes the capture
/// streams (which makes each engine finalize) and awaits the tail drain.
@MainActor
final class MeetingPipeline {
    private let engine: any STTEngine
    private let sources: [any AudioCaptureSource]
    private let store: TranscriptStore
    private let locale: Locale
    private var eventTasks: [Task<Void, Never>] = []
    private var stopped = false
    private let log = Logger(subsystem: "io.macapy.app", category: "MeetingPipeline")

    /// Invoked on a mid-stream transcription failure (the coordinator stops the
    /// session). Errors thrown from `start()` propagate to the caller instead.
    var onFailure: (@MainActor (any Error) -> Void)?

    init(
        engine: any STTEngine,
        sources: [any AudioCaptureSource],
        store: TranscriptStore,
        locale: Locale = .current
    ) {
        self.engine = engine
        self.sources = sources
        self.store = store
        self.locale = locale
    }

    /// Flips the pipeline to "stopping" synchronously, so a `start()` still
    /// suspended in `prepare()`/format negotiation bails at its next checkpoint
    /// instead of bringing capture up after a stop already began.
    func markStopped() {
        stopped = true
    }

    func start() async throws {
        try await engine.prepare(locale: locale)
        if stopped { return }
        let baseFormat = try await engine.preferredInputFormat()
        if stopped { return }

        let commonFormat = baseFormat.commonFormat
        let sampleRate = baseFormat.sampleRate
        let channels = baseFormat.channelCount
        let interleaved = baseFormat.isInterleaved
        for source in sources {
            // A fresh format instance per source: a non-Sendable value created
            // here and handed straight to the (actor) source is region-isolated,
            // so it crosses cleanly. Reusing one `baseFormat` instance across
            // loop iterations would not (it can't be proven single-send).
            guard let format = AVAudioFormat(
                commonFormat: commonFormat,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: interleaved
            ) else {
                throw TranscribeError.assetsUnavailable(locale, underlying: nil)
            }
            let audio = try await source.start(format: format)
            if stopped {
                await source.stop()
                continue
            }
            let src = source.source
            let events = engine.transcribe(audio, source: src)
            let task = Task { @MainActor [weak self, store] in
                do {
                    for try await event in events {
                        store.apply(event, from: src)
                    }
                } catch {
                    self?.log.error("source \(src.rawValue) failed: \(error.localizedDescription)")
                    self?.onFailure?(error)
                }
            }
            eventTasks.append(task)
        }
    }

    func stop() async {
        stopped = true
        for source in sources {
            await source.stop()
        }
        // Draining: each capture stream is now finished, so each engine
        // finalizes and emits its remaining finals before ending the event
        // stream. Awaiting the tasks guarantees those finals reached the store.
        for task in eventTasks {
            _ = await task.value
        }
        eventTasks.removeAll()
    }

    func pause() async {
        for source in sources {
            await source.pause()
        }
    }

    func resume() async {
        for source in sources {
            await source.resume()
        }
    }
}
