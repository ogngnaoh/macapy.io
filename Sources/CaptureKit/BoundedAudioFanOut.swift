import Foundation

/// The memory-watch primitive (slice-4 decision 4): splits one capture stream
/// into N *bounded* branches so a stalled consumer can no longer grow memory
/// without bound — the capture sources' own `.unbounded` streams stay empty
/// because the forwarding task drains them eagerly, and backpressure lands
/// only in the bounded branches, which evict oldest-first with an exact,
/// surfaced drop count. Drop-oldest is the honest stall behavior: replaying a
/// stale backlog into STT after a stall would produce garbage timing anyway.
///
/// Branches share the same `AVAudioPCMBuffer` instances read-only (safe under
/// `AudioChunk`'s producer-never-touches-after-yield rule; a consumer that
/// mutated a buffer would break the other branches — none does, and new
/// consumers must not).
public enum BoundedAudioFanOut {
    /// ~10s of audio at the observed ~0.1s chunk cadence — an order of
    /// magnitude above any transient analyzer hiccup, while the retained
    /// ceiling stays memory-irrelevant (~320KB/branch at 16kHz Int16) even if
    /// chunk sizing varies 10× either way.
    public static let defaultBound = 100

    public struct Output: Sendable {
        /// One bounded stream per branch, in branch order.
        public let branches: [AsyncStream<AudioChunk>]
        public let drops: DropCounter
        /// Completes when the source stream finishes and every branch has been
        /// finished. Tests await it for determinism; production lets it run.
        public let forwarding: Task<Void, Never>
    }

    /// `onChunk` runs on the forwarding task for every chunk before it is
    /// yielded to any branch — the seam for cheap per-chunk side-effects (RMS,
    /// fed-clock). It must stay O(chunk) and must not retain the buffer.
    public static func split(
        _ source: AsyncStream<AudioChunk>,
        branchCount: Int,
        bound: Int = defaultBound,
        onChunk: (@Sendable (AudioChunk) -> Void)? = nil
    ) -> Output {
        precondition(branchCount >= 1 && bound >= 1)
        let drops = DropCounter(branchCount: branchCount)
        let made = (0..<branchCount).map { _ in
            AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(bound))
        }
        let continuations = made.map(\.continuation)

        let forwarding = Task {
            for await chunk in source {
                onChunk?(chunk)
                for (branch, continuation) in continuations.enumerated() {
                    if case .dropped = continuation.yield(chunk) {
                        drops.increment(branch: branch)
                    }
                }
            }
            for continuation in continuations { continuation.finish() }
        }
        return Output(branches: made.map(\.stream), drops: drops, forwarding: forwarding)
    }

    /// Per-branch eviction counts. Lock-protected class (not an actor) so the
    /// forwarding loop increments synchronously and diagnostics polls without
    /// suspension — the `LatencyRecorder` pattern.
    public final class DropCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int]

        init(branchCount: Int) {
            counts = Array(repeating: 0, count: branchCount)
        }

        func increment(branch: Int) {
            lock.withLock { counts[branch] += 1 }
        }

        public func count(forBranch branch: Int) -> Int {
            lock.withLock { counts[branch] }
        }

        public var total: Int {
            lock.withLock { counts.reduce(0, +) }
        }
    }
}
