import Foundation
import TranscribeKit
import os

/// Batches `TranscriptStore.finalsStream()` output into `MeetingStore.append`
/// calls: flush on a debounce window (default ~1s, coalescing — each new
/// segment resets the timer) or a row-count threshold, whichever comes first,
/// plus an explicit final flush at meeting end (`flushAndStop`).
///
/// BINDING (slice-04 doc Notes, carried from the slice-2 critic):
/// `TranscriptStore.finalsStream()` has no replay, and `reset()` finishes all
/// its continuations. A `SegmentWriter` therefore MUST call `finalsStream()`
/// and start `run(consuming:)` **before** anything that could produce a final
/// for its meeting — i.e. before `MeetingPipeline` starts audio capture — and
/// a fresh writer/attach is required for every meeting (never reused across a
/// `reset()`). `MeetingPipeline.start(mode:)` is what enforces this ordering;
/// see its doc comment.
public actor SegmentWriter {
    private let store: MeetingStore
    private let meetingID: MeetingRecord.ID
    private let batchThreshold: Int
    private let debounceNanos: UInt64

    private var buffer: [Segment] = []
    private var debounceTask: Task<Void, Never>?
    private let log = Logger(subsystem: "io.macapy.app", category: "SegmentWriter")

    public init(
        store: MeetingStore,
        meetingID: MeetingRecord.ID,
        batchThreshold: Int = 25,
        debounceNanos: UInt64 = 1_000_000_000
    ) {
        self.store = store
        self.meetingID = meetingID
        self.batchThreshold = batchThreshold
        self.debounceNanos = debounceNanos
    }

    /// Consumes `finals` until the stream ends (i.e. the store is reset for
    /// the next meeting — see the BINDING note above for why this must be
    /// attached before capture starts). Buffers each segment; flushes at the
    /// row threshold immediately, otherwise (re)schedules the debounce flush.
    /// Flushes once more when the stream itself ends, so a tail that never
    /// hit the threshold or the debounce window still isn't lost.
    public func run(consuming finals: AsyncStream<Segment>) async {
        for await segment in finals {
            buffer.append(segment)
            if buffer.count >= batchThreshold {
                await flush()
            } else {
                scheduleDebounce()
            }
        }
        await flush()
    }

    /// Forces an immediate flush of whatever is currently buffered. Called by
    /// `MeetingPipeline.stop()` so a meeting's tail write doesn't wait for the
    /// debounce window (or, worse, however long until the *next* meeting's
    /// `reset()` ends this stream naturally).
    public func flushAndStop() async throws {
        try await flushOrThrow()
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        let nanos = debounceNanos
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        do {
            try await flushOrThrow()
        } catch {
            log.error("segment flush failed: \(error.localizedDescription)")
        }
    }

    private func flushOrThrow() async throws {
        debounceTask?.cancel()
        debounceTask = nil
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll()
        try await store.append(batch, to: meetingID)
    }
}
