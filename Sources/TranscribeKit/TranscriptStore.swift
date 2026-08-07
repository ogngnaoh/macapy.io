import CaptureKit
import Foundation
import Observation

/// The live transcript model the panel observes. `@MainActor @Observable`
/// (amended vs SPEC §6, which said actor): event rates are a few/sec, so
/// main-actor serialization costs nothing at M1 scale and removes an
/// observation-bridging layer.
///
/// Volatile model: **at most one volatile line per source** — SpeechTranscriber
/// volatiles are successive refinements of the current utterance, so a final
/// clears that source's volatile line and appends a `Segment`. Finals also flow
/// out `finalsStream()` for slice 4's persistence writer.
@MainActor
@Observable
public final class TranscriptStore {
    public struct VolatileLine: Equatable, Sendable {
        public let source: AudioSource
        public let text: String

        public init(source: AudioSource, text: String) {
            self.source = source
            self.text = text
        }
    }

    public private(set) var segments: [Segment] = []
    public private(set) var volatile: [AudioSource: VolatileLine] = [:]
    /// Live diarization labels by segment id (slice-4 decision 3): finals
    /// render unattributed and pick up their gutter label when attribution
    /// lands — observation redraws the line, G1 never waits. Volatile lines
    /// never consult this map (they have no stable id by design).
    public private(set) var speakerLabels: [Segment.ID: String] = [:]

    @ObservationIgnored private var finalsContinuations: [UUID: AsyncStream<Segment>.Continuation] = [:]

    public init() {}

    public func apply(_ event: TranscriptEvent, from source: AudioSource) {
        switch event {
        case let .volatile(text, _, _):
            volatile[source] = VolatileLine(source: source, text: text)
        case let .final(segment):
            volatile[source] = nil
            insertOrdered(segment)
            for continuation in finalsContinuations.values {
                continuation.yield(segment)
            }
        case .turnEnded:
            break
        }
    }

    /// Post-hoc speaker attribution for a final (slice 4). Idempotent;
    /// harmless for ids not (yet) in `segments` — the map is consulted by id
    /// at render time.
    public func setSpeakerLabel(_ label: String, for segmentID: Segment.ID) {
        speakerLabels[segmentID] = label
    }

    /// Clears the transcript and ends any open `finalsStream()` (a new meeting).
    public func reset() {
        segments.removeAll()
        volatile.removeAll()
        speakerLabels.removeAll()
        finishFinalsStreams()
    }

    /// Ends any open `finalsStream()` continuations **without** clearing
    /// `segments`/`volatile` — the panel keeps showing the transcript after a
    /// meeting stops (only starting the *next* meeting, via `reset()`, clears
    /// it). Added in slice 4 so `MeetingPipeline.stop()` can deterministically
    /// end a meeting's persistence: `AsyncStream` guarantees every value
    /// yielded before `finish()` is delivered to its consumer before the
    /// consumer observes the stream end, so a `SegmentWriter` attached to this
    /// stream is guaranteed to drain every already-yielded final and perform
    /// its trailing flush — no reliance on actor-executor scheduling order
    /// (see `SegmentWriter.flushAndStop()`'s doc comment for the hazard this
    /// replaced). Idempotent: a no-op if nothing is attached.
    public func finishFinalsStreams() {
        for continuation in finalsContinuations.values {
            continuation.finish()
        }
        finalsContinuations.removeAll()
    }

    /// A side-channel of finalized segments, in the order they were applied.
    /// Ends on `reset()` or `finishFinalsStreams()`. Consumed by slice 4's
    /// GRDB writer.
    public func finalsStream() -> AsyncStream<Segment> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Segment>.makeStream()
        finalsContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.finalsContinuations.removeValue(forKey: id) }
        }
        return stream
    }

    /// Insert keeping `segments` ordered by `tStart`. Finals usually arrive in
    /// order, so this scans from the tail (O(1) amortized in the common case).
    private func insertOrdered(_ segment: Segment) {
        var index = segments.count
        while index > 0, segments[index - 1].tStart > segment.tStart {
            index -= 1
        }
        segments.insert(segment, at: index)
    }
}
