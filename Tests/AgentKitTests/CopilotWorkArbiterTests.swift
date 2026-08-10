import Foundation
import Testing

@testable import AgentKit

struct CopilotWorkArbiterTests {
    private actor CancellationFlag {
        private(set) var wasCancelled = false
        func mark() { wasCancelled = true }
    }

    @Test func proactiveWorkDropsInsteadOfQueuingAndCardRetainsOccupancy() async throws {
        let arbiter = CopilotWorkArbiter()
        let first = try #require(await arbiter.begin(.proactive).lease)

        #expect(await arbiter.begin(.proactive) == .dropped)
        #expect(await arbiter.begin(.background) == .dropped)

        await arbiter.finish(first, retainProactiveCard: true)
        #expect(await arbiter.hasActiveProactiveCard)
        #expect(await arbiter.begin(.proactive) == .dropped)

        await arbiter.dismissProactiveCard()
        let hasCardAfterDismissal = await arbiter.hasActiveProactiveCard
        #expect(!hasCardAfterDismissal)
        #expect(await arbiter.begin(.proactive).lease != nil)
    }

    @Test func userRequestPreemptsAndCancelsProactiveTask() async throws {
        let arbiter = CopilotWorkArbiter()
        let flag = CancellationFlag()
        let proactive = try #require(await arbiter.begin(.proactive).lease)
        let task = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                await flag.mark()
            } catch {}
        }
        await arbiter.attach(task, to: proactive)

        let admission = await arbiter.begin(.userRequest)
        guard case .preempted(let userLease, let previousID) = admission else {
            Issue.record("expected preemption, got \(admission)")
            return
        }
        #expect(previousID == proactive.id)
        #expect(userLease.priority == .userRequest)
        await Task.yield()
        #expect(await flag.wasCancelled)
        #expect(await arbiter.hasActiveWork)
    }

    @Test func staleTaskAttachmentIsCancelledAfterPreemption() async throws {
        let arbiter = CopilotWorkArbiter()
        let flag = CancellationFlag()
        let proactive = try #require(await arbiter.begin(.proactive).lease)
        _ = await arbiter.begin(.userRequest)

        let staleTask = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                await flag.mark()
            } catch {}
        }
        await arbiter.attach(staleTask, to: proactive)
        await Task.yield()

        #expect(await flag.wasCancelled)
    }
}
