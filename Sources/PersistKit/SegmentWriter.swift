import Foundation
import TranscribeKit
import os

/// Batches `TranscriptStore.finalsStream()` output into `MeetingStore.append`
/// calls: flush on a debounce window (default ~1s, coalescing — each new
/// segment resets the timer) or a row-count threshold, whichever comes first,
/// plus a deterministic final flush at meeting end (`flushAndStop`).
///
/// BINDING (slice-04 doc Notes, carried from the slice-2 critic):
/// `TranscriptStore.finalsStream()` has no replay, and `reset()`/
/// `finishFinalsStreams()` finish all its continuations. A `SegmentWriter`
/// therefore MUST call `finalsStream()` and start `run(consuming:)` **before**
/// anything that could produce a final for its meeting — i.e. before
/// `MeetingPipeline` starts audio capture — and a fresh writer/attach is
/// required for every meeting (never reused across a `reset()`).
/// `MeetingPipeline.start(mode:)` is what enforces this ordering; see its doc
/// comment.
///
/// FIX (post-ship, verifier-caught race): an earlier version of
/// `flushAndStop()` read `buffer` directly and relied on the actor's job
/// queue having already run every pending `run(consuming:)` iteration first —
/// i.e. it assumed same-actor jobs execute in enqueue order. That is NOT a
/// language guarantee (priority escalation, among other things, can let a
/// later-enqueued job run first), so a `flushAndStop()` call could observe an
/// empty `buffer` and silently drop a meeting's still-in-flight tail finals.
/// The fix moves the finish signal to something Swift *does* guarantee:
/// `AsyncStream` delivers every value yielded before `finish()` to its
/// consumer before that consumer observes the stream end. `flushAndStop()`
/// now just waits for `run(consuming:)` to notice the stream ended (which
/// only happens once every already-yielded final has been drained through
/// it) and reports the outcome of the trailing flush `run` performs at that
/// point — no reliance on actor-executor scheduling anywhere in this path.
public actor SegmentWriter {
    private let store: MeetingStore
    private let meetingID: MeetingRecord.ID
    private let batchThreshold: Int
    private let debounceNanos: UInt64

    private var buffer: [Segment] = []
    private var debounceTask: Task<Void, Never>?
    private let log = Logger(subsystem: "io.macapy.app", category: "SegmentWriter")

    // Completion signaling for flushAndStop(): resolved once run(consuming:)
    // has observed the finals stream end and performed its trailing flush.
    // Setting `runFinished` and appending to `runFinishWaiters` never straddle
    // a suspension point in the same call, so there's no window between a
    // `flushAndStop()` check and a `run()` completion for them to race in.
    private var runFinished = false
    private var runFinishError: Error?
    private var runFinishWaiters: [CheckedContinuation<Void, Never>] = []

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

    /// Consumes `finals` until the stream ends (the store's `reset()` or
    /// `finishFinalsStreams()` — see the BINDING note above for why this must
    /// be attached before capture starts). Buffers each segment; flushes at
    /// the row threshold immediately, otherwise (re)schedules the debounce
    /// flush. Performs one trailing flush when the stream itself ends, so a
    /// tail that never hit the threshold or the debounce window still isn't
    /// lost — and that trailing flush's outcome is what `flushAndStop()`
    /// reports back to its caller.
    public func run(consuming finals: AsyncStream<Segment>) async {
        for await segment in finals {
            buffer.append(segment)
            if buffer.count >= batchThreshold {
                await flush()
            } else {
                scheduleDebounce()
            }
        }
        do {
            try await flushOrThrow()
        } catch {
            log.error("trailing segment flush failed: \(error.localizedDescription)")
            runFinishError = error
        }
        runFinished = true
        for waiter in runFinishWaiters {
            waiter.resume()
        }
        runFinishWaiters.removeAll()
    }

    /// Deterministically waits for `run(consuming:)` to observe the finals
    /// stream end and complete its trailing flush, then rethrows that flush's
    /// error if it failed. Callers (`MeetingPipeline.stop()`) must end the
    /// stream themselves first — via `TranscriptStore.finishFinalsStreams()`,
    /// after every final for the meeting has already been yielded — or this
    /// call hangs forever waiting for a stream that will never end.
    public func flushAndStop() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // No suspension point between this check and the append below, so
            // there's no window for `run()`'s completion to land in between —
            // either it already finished (resume immediately) or it hasn't
            // (register to be resumed when it does).
            if runFinished {
                continuation.resume()
            } else {
                runFinishWaiters.append(continuation)
            }
        }
        if let runFinishError {
            throw runFinishError
        }
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
