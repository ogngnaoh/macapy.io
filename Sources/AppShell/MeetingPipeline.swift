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
    /// Latency instrumentation (slice-05 doc decision 1): injected so tests
    /// can inspect it, defaulted to a fresh real recorder so it's "on" by
    /// construction — no separate enable flag. Exposed to the coordinator via
    /// `currentRecorder` for the diagnostics section.
    let recorder: LatencyRecorder
    /// Per-source signal levels for the strip (slice-4 decision 5), written by
    /// the fan-out tap, polled by the UI. Same on-by-construction pattern as
    /// `recorder`.
    let signalMeter = SignalLevelMeter()
    /// One drop counter per source, in `sources` order (slice-4 decision 4).
    /// Diagnostics sums them via `droppedChunks`.
    private var dropCounters: [BoundedAudioFanOut.DropCounter] = []
    private var forwardingTasks: [Task<Void, Never>] = []
    private var eventTasks: [Task<Void, Never>] = []
    private var stopped = false
    private let log = Logger(subsystem: "io.macapy.app", category: "MeetingPipeline")

    private var meetingStore: MeetingStore?
    private var meetingID: MeetingRecord.ID?
    private var isEphemeral = false
    private var segmentWriter: SegmentWriter?
    private var writerTask: Task<Void, Never>?

    /// Invoked on a mid-stream transcription failure (the coordinator stops the
    /// session). Errors thrown from `start()` propagate to the caller instead.
    var onFailure: (@MainActor (any Error) -> Void)?

    init(
        engine: any STTEngine,
        sources: [any AudioCaptureSource],
        store: TranscriptStore,
        locale: Locale = .current,
        recorder: LatencyRecorder = LatencyRecorder(sessionStart: Date())
    ) {
        self.engine = engine
        self.sources = sources
        self.store = store
        self.locale = locale
        self.recorder = recorder
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
        isEphemeral = ephemeral

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
            // Memory-watch seam (slice-4 decisions 4+5): the raw capture
            // stream is unbounded by design; everything downstream consumes a
            // bounded branch, so an analyzer stall evicts oldest chunks (with
            // an exact surfaced count) instead of growing memory. The tap
            // computes RMS per chunk for the signal strip. One STT branch per
            // source in M2 phase 1; the them-stream diarizer joins as a second
            // branch in phase 5.
            let meter = signalMeter
            let fanOut = BoundedAudioFanOut.split(audio, branchCount: 1) { chunk in
                meter.record(source: src, level: AudioLevel.rms(of: chunk.buffer))
            }
            dropCounters.append(fanOut.drops)
            forwardingTasks.append(fanOut.forwarding)
            let events = engine.transcribe(fanOut.branches[0], source: src)
            let recorder = self.recorder
            let task = Task { @MainActor [weak self, store, recorder] in
                do {
                    for try await event in events {
                        // Recorded right at the hook point events become
                        // visible to the store/panel (slice-05 doc decision
                        // 3's documented approximation of G1) — before
                        // store.apply(), so the timestamp reflects arrival,
                        // not whatever apply()/SwiftUI diffing costs.
                        let arrivalWall = Date()
                        switch event {
                        case let .volatile(_, _, tEnd):
                            recorder.record(kind: .volatile, audioTEnd: tEnd, arrivalWall: arrivalWall)
                        case let .final(segment):
                            recorder.record(kind: .final, audioTEnd: segment.tEnd, arrivalWall: arrivalWall)
                        case .turnEnded:
                            break
                        }
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

    /// Returns the ended meeting's id when it was persistent — the
    /// post-meeting agent's trigger (slice-03 decision 1). `nil` for
    /// ephemeral meetings (their store is already gone — check 7) and for a
    /// pipeline that never began one.
    @discardableResult
    func stop() async -> MeetingRecord.ID? {
        stopped = true
        for source in sources {
            await source.stop()
        }
        // Draining: each capture stream is now finished, so the fan-out
        // forwards its tail and finishes the bounded branches, each engine
        // finalizes and emits its remaining finals before ending the event
        // stream. Awaiting forwarding first, then the event tasks, guarantees
        // those finals reached the store (and, from there, the SegmentWriter's
        // finalsStream — see start()) — every final for this meeting has been
        // synchronously yielded by the time this loop returns.
        for task in forwardingTasks {
            _ = await task.value
        }
        forwardingTasks.removeAll()
        // dropCounters stays: like `recorder`, the count outlives stop() so
        // diagnostics can still show the ended meeting's number.
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
        let endedPersistentMeetingID = isEphemeral ? nil : meetingID
        segmentWriter = nil
        writerTask = nil
        meetingStore = nil
        meetingID = nil
        return endedPersistentMeetingID
    }

    /// Total chunks evicted across all sources' bounded branches this meeting
    /// (slice-4 decision 4) — the diagnostics "Dropped chunks" tile. 0 in a
    /// healthy meeting; anything else means a consumer stalled.
    var droppedChunks: Int {
        dropCounters.reduce(0) { $0 + $1.total }
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
