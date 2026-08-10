import Foundation

/// Per-meeting G2 instrumentation: automatic proactive admission to the first
/// token that actually wins the presentation race and becomes visible.
///
/// Only opaque lease ids and wall-clock instants are retained. Transcript,
/// classifier target, and model output are deliberately absent. The lock keeps
/// trigger/commit/cancellation synchronous and safe across task teardown; live
/// work never waits on diagnostics.
public final class SuggestionLatencyRecorder: @unchecked Sendable {
    public struct Report: Sendable, Equatable {
        /// Completed, physically possible samples used by the percentile.
        public let count: Int
        /// Nearest-rank p95 over `count` samples, or zero when none completed.
        public let p95Ms: Double
        /// Samples whose commit preceded their trigger. They remain visible in
        /// diagnostics and can never flatter the percentile.
        public let excludedNegativeCount: Int
        /// Triggered work cancelled or completed without visible output.
        public let cancelledCount: Int
        /// Triggered work which has not committed or been cancelled yet.
        public let pendingCount: Int

        public var completedCount: Int { count + excludedNegativeCount }
        public var totalTriggerCount: Int {
            completedCount + cancelledCount + pendingCount
        }
    }

    private let lock = NSLock()
    private var pending: [UUID: Date] = [:]
    private var latenciesMs: [Double] = []
    private var cancelledCount = 0

    public init() {}

    /// Registers one admitted proactive attempt. Re-registering the same
    /// lease replaces its timestamp but does not create a second trigger.
    public func trigger(_ id: UUID, at date: Date = Date()) {
        lock.withLock { pending[id] = date }
    }

    /// Records the first visible commit exactly once. Returns `true` only for
    /// the winning first commit; stale or duplicate commits are ignored.
    @discardableResult
    public func recordFirstVisible(_ id: UUID, at date: Date = Date()) -> Bool {
        lock.withLock {
            guard let trigger = pending.removeValue(forKey: id) else { return false }
            latenciesMs.append(date.timeIntervalSince(trigger) * 1_000)
            return true
        }
    }

    /// Ends an attempt which never produced visible output. Completed and
    /// already-cancelled ids are idempotent no-ops.
    public func cancel(_ id: UUID) {
        lock.withLock {
            if pending.removeValue(forKey: id) != nil { cancelledCount += 1 }
        }
    }

    /// Cancels every still-pending trigger while retaining the ended meeting's
    /// completed evidence for diagnostics.
    public func cancelPending() {
        lock.withLock {
            cancelledCount += pending.count
            pending.removeAll(keepingCapacity: false)
        }
    }

    /// Starts a new meeting. Nothing is persisted across this boundary.
    public func reset() {
        lock.withLock {
            pending.removeAll(keepingCapacity: false)
            latenciesMs.removeAll(keepingCapacity: false)
            cancelledCount = 0
        }
    }

    public func report() -> Report {
        lock.withLock {
            let sorted = latenciesMs.filter { $0 >= 0 }.sorted()
            let excluded = latenciesMs.count - sorted.count
            let p95: Double
            if sorted.isEmpty {
                p95 = 0
            } else {
                let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
                p95 = sorted[min(max(rank, 1), sorted.count) - 1]
            }
            return Report(
                count: sorted.count,
                p95Ms: p95,
                excludedNegativeCount: excluded,
                cancelledCount: cancelledCount,
                pendingCount: pending.count
            )
        }
    }
}
