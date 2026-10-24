import Foundation
import Testing

@testable import AppShell

@MainActor
struct ApplicationLifecycleTests {
    actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        var entered = false
        func wait() async {
            entered = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Lifecycle fake did not reach the expected state")
    }

    @Test func sleepRequestsExplicitStopWithoutSchedulingAutomaticWakeCapture() {
        var sleeps = 0
        var drains = 0
        let model = ApplicationLifecycleController(onSleep: { sleeps += 1 }, drainForTermination: { drains += 1 }, onTimeout: {})
        #expect(sleeps == 0 && drains == 0)
        model.receiveSleep()
        #expect(sleeps == 1 && drains == 0)
        #expect(model.phase == .idle)
    }

    @Test func quitWaitsForCaptureTailAndRepeatedRequestDoesNotDuplicateDrain() async {
        let gate = Gate()
        var drains = 0
        var replies: [Bool] = []
        let model = ApplicationLifecycleController(onSleep: {}, drainForTermination: { drains += 1; await gate.wait() }, onTimeout: {})
        model.requestTermination { replies.append($0) }
        model.requestTermination { _ in Issue.record("Duplicate request must not create a second reply owner") }
        await waitUntil { drains == 1 }
        #expect(replies.isEmpty)
        #expect(model.phase == .draining)
        await gate.release()
        await waitUntil { replies == [true] }
        #expect(model.phase == .idle)
        #expect(drains == 1)
    }

    @Test func timeoutCancelsQuitButLateDrainCannotQuitWithoutANewRequest() async {
        let gate = Gate()
        var replies: [Bool] = []
        var timeouts = 0
        var drains = 0
        let model = ApplicationLifecycleController(onSleep: {}, drainForTermination: { drains += 1; await gate.wait() },
                                                   onTimeout: { timeouts += 1 }, timeout: .milliseconds(20))
        model.requestTermination { replies.append($0) }
        await waitUntil { replies == [false] }
        #expect(model.phase == .waitingForDrain)
        #expect(timeouts == 1 && drains == 1)
        await gate.release()
        await waitUntil { model.phase == .idle }
        #expect(replies == [false])
        model.requestTermination { replies.append($0) }
        await waitUntil { replies == [false, true] }
        #expect(drains == 2)
    }

    @Test func retryWhileStillDrainingReusesOwnerAndRequiresExplicitNewQuit() async {
        let gate = Gate()
        var replies: [Bool] = []
        var drains = 0
        let model = ApplicationLifecycleController(onSleep: {}, drainForTermination: { drains += 1; await gate.wait() },
                                                   onTimeout: {}, timeout: .milliseconds(20))
        model.requestTermination { replies.append($0) }
        await waitUntil { replies == [false] }
        model.requestTermination { replies.append($0) }
        await gate.release()
        await waitUntil { replies == [false, true] }
        #expect(drains == 1)
    }
}
