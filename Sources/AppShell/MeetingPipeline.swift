import AVFoundation
import CaptureKit
import Foundation
import PersistKit
import TranscribeKit
import os

/// How a meeting's transcript is persisted (slice-04 doc decision 2/4):
/// `.persistent` writes through the given, app-lifetime `MeetingStore`;
/// `.ephemeral` writes to a fresh, private in-memory database that's
/// discarded when the meeting ends — same write path, zero disk rows by
/// construction.
enum PersistenceMode {
    case persistent(MeetingStore)
    case ephemeral
}

/// Orchestrates one meeting's capture → transcription → store → persistence
/// flow. `@MainActor` (created and torn down from the coordinator). Owns
/// per-source event tasks that apply `TranscriptEvent`s to the store; `stop()`
/// finishes the capture streams (which makes each engine finalize) and awaits
/// the tail drain, then flushes and closes out the meeting's persistence.
@MainActor
final class MeetingPipeline {
    private let engine: any STTEngine
    private let sources: [any AudioCaptureSource]
    private let store: TranscriptStore
    private let locale: Locale
    private var eventTasks: [Task<Void, Never>] = []
    private var stopped = false
    private let log = Logger(subsystem: "io.macapy.app", category: "MeetingPipeline")

    private var meetingStore: MeetingStore?
    private var meetingID: MeetingRecord.ID?
    private var segmentWriter: SegmentWriter?
    private var writerTask: Task<Void, Never>?

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

    func start(mode: PersistenceMode) async throws {
        let resolvedStore: MeetingStore
        let ephemeral: Bool
        switch mode {
        case .persistent(let store):
            resolvedStore = store
            ephemeral = false
        case .ephemeral:
            // A fresh, private in-memory database per meeting (slice-04 doc
            // decision 2) — never touches disk, so it's discarded for free
            // when this pipeline (and its store reference) goes away.
            resolvedStore = MeetingStore(database: try MacapyDatabase.inMemory())
            ephemeral = true
        }
        let meeting = try await resolvedStore.beginMeeting(startedAt: Date(), ephemeral: ephemeral)
        meetingStore = resolvedStore
        meetingID = meeting.id

        // BINDING (slice-04 doc Notes, from the slice-2 critic):
        // `TranscriptStore.finalsStream()` has no replay and `reset()`
        // finishes all continuations, so the `SegmentWriter` must attach
        // *now* — before `engine.prepare()`/capture start below, i.e. before
        // anything in this method could cause a final to be produced — or an
        // immediate/boundary final would be silently lost. The coordinator
        // calls `store.reset()` immediately before `start()`, so this attach
        // always happens strictly after that reset and gets a live
        // continuation; a fresh `SegmentWriter` is created here on every call,
        // satisfying "re-attach after every reset" by construction.
        let writer = SegmentWriter(store: resolvedStore, meetingID: meeting.id)
        segmentWriter = writer
        let finals = store.finalsStream()
        writerTask = Task { await writer.run(consuming: finals) }

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
        // stream. Awaiting the tasks guarantees those finals reached the store
        // (and, from there, the SegmentWriter's finalsStream — see start()) —
        // every final for this meeting has been synchronously yielded by the
        // time this loop returns.
        for task in eventTasks {
            _ = await task.value
        }
        eventTasks.removeAll()

        // End this meeting's finals stream now (not at the *next* meeting's
        // reset()) so the SegmentWriter's trailing flush runs immediately.
        // AsyncStream guarantees every value yielded above is delivered to
        // the writer before it observes this as "ended" — flushAndStop()
        // deterministically waits on exactly that, no actor-scheduling
        // assumptions involved (see SegmentWriter's doc comment for the race
        // this replaced).
        store.finishFinalsStreams()
        if let segmentWriter {
            do {
                try await segmentWriter.flushAndStop()
            } catch {
                log.error("final segment flush failed: \(error.localizedDescription)")
            }
        }
        if let meetingStore, let meetingID {
            do {
                try await meetingStore.endMeeting(id: meetingID, endedAt: Date())
            } catch {
                log.error("endMeeting failed: \(error.localizedDescription)")
            }
        }
        segmentWriter = nil
        writerTask = nil
        meetingStore = nil
        meetingID = nil
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
