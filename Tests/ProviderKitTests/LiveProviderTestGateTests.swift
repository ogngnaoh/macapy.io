import Testing

@testable import ProviderTestSupport

private actor AsyncLatch {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor GateProbe {
    private var active = 0
    private var maximumActive = 0
    private var entries: [Int] = []

    func enter(_ value: Int) {
        active += 1
        maximumActive = max(maximumActive, active)
        entries.append(value)
    }

    func leave() {
        active -= 1
    }

    func snapshot() -> (maximumActive: Int, entries: [Int]) {
        (maximumActive, entries)
    }
}

private enum GateProbeError: Error {
    case expected
}

struct LiveProviderTestGateTests {
    @Test func concurrentOperationsNeverOverlap() async throws {
        let gate = LiveProviderTestGate()
        let probe = GateProbe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0..<16 {
                group.addTask {
                    try await gate.withExclusiveAccess {
                        await probe.enter(value)
                        await Task.yield()
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }

        let snapshot = await probe.snapshot()
        #expect(snapshot.maximumActive == 1)
        #expect(snapshot.entries.count == 16)
        #expect(Set(snapshot.entries) == Set(0..<16))
    }

    @Test func queuedOperationsEnterInFIFOOrder() async throws {
        let gate = LiveProviderTestGate()
        let firstEntered = AsyncLatch()
        let releaseFirst = AsyncLatch()
        let probe = GateProbe()

        let first = Task {
            try await gate.withExclusiveAccess {
                await probe.enter(1)
                await firstEntered.open()
                await releaseFirst.wait()
                await probe.leave()
            }
        }
        await firstEntered.wait()

        let second = Task {
            try await gate.withExclusiveAccess {
                await probe.enter(2)
                await probe.leave()
            }
        }
        await waitForQueueDepth(1, gate: gate)

        let third = Task {
            try await gate.withExclusiveAccess {
                await probe.enter(3)
                await probe.leave()
            }
        }
        await waitForQueueDepth(2, gate: gate)

        await releaseFirst.open()
        try await first.value
        try await second.value
        try await third.value

        let snapshot = await probe.snapshot()
        #expect(snapshot.maximumActive == 1)
        #expect(snapshot.entries == [1, 2, 3])
    }

    @Test func throwingOperationReleasesTheNextCaller() async throws {
        let gate = LiveProviderTestGate()
        var threwExpectedError = false

        do {
            try await gate.withExclusiveAccess {
                throw GateProbeError.expected
            }
        } catch GateProbeError.expected {
            threwExpectedError = true
        }

        #expect(threwExpectedError)
        let value = try await gate.withExclusiveAccess { 42 }
        #expect(value == 42)
    }

    @Test func cancellingAQueuedCallerDoesNotStrandFollowers() async throws {
        let gate = LiveProviderTestGate()
        let firstEntered = AsyncLatch()
        let releaseFirst = AsyncLatch()

        let first = Task {
            try await gate.withExclusiveAccess {
                await firstEntered.open()
                await releaseFirst.wait()
            }
        }
        await firstEntered.wait()

        let cancelled = Task {
            try await gate.withExclusiveAccess { 2 }
        }
        await waitForQueueDepth(1, gate: gate)
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            Issue.record("cancelled gate waiter unexpectedly entered")
        } catch is CancellationError {
            // Expected: the queued continuation is removed and resumed.
        }

        let follower = Task {
            try await gate.withExclusiveAccess { 3 }
        }
        await waitForQueueDepth(1, gate: gate)
        await releaseFirst.open()

        try await first.value
        #expect(try await follower.value == 3)
    }

    private func waitForQueueDepth(
        _ expected: Int,
        gate: LiveProviderTestGate
    ) async {
        for _ in 0..<10_000 {
            if await gate.queuedWaiterCount == expected { return }
            await Task.yield()
        }
        Issue.record("gate did not reach expected queue depth \(expected)")
    }
}
