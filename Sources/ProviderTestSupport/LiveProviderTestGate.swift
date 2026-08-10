import Foundation

/// A process-wide, asynchronous admission gate for expensive live-provider
/// evidence tests.
///
/// Swift Testing may execute suites from different test targets concurrently
/// inside the same test process. That is normally desirable, but concurrent
/// provider traffic makes latency evidence describe local contention instead
/// of the service under test. M3 live evidence enters through `shared`; local
/// instances are useful for deterministic, network-free tests of the gate.
///
/// The gate is deliberately part of `ProviderTestSupport`, which is absent
/// from every production product and target dependency graph.
public actor LiveProviderTestGate {
    public static let shared = LiveProviderTestGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var owner: UUID?
    private var waiters: [Waiter] = []

    public init() {}

    /// Runs `operation` after all earlier callers have finished.
    ///
    /// Admission is FIFO, waiting never blocks a thread, and every exit path
    /// releases ownership. A task cancelled while queued is removed and
    /// resumed with `CancellationError`; a cancellation racing with admission
    /// is noticed before the operation begins and ownership advances normally.
    public func withExclusiveAccess<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let id = try await acquire()

        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(id)
            return result
        } catch {
            release(id)
            throw error
        }
    }

    /// Test-only observation seam. It is internal so live evidence cannot
    /// depend on queue depth, but `@testable` gate tests can enqueue callers
    /// deterministically without sleeps or scheduler assumptions.
    var queuedWaiterCount: Int { waiters.count }

    private func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()

        guard owner != nil else {
            owner = id
            return id
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }

        return id
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ id: UUID) {
        guard owner == id else { return }

        guard !waiters.isEmpty else {
            owner = nil
            return
        }

        let next = waiters.removeFirst()
        owner = next.id
        next.continuation.resume()
    }
}
