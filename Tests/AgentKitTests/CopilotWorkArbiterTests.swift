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

    @Test func proactivePreemptsBackgroundAndCancelsItsTask() async throws {
        let arbiter = CopilotWorkArbiter()
        let flag = CancellationFlag()
        let background = try #require(await arbiter.begin(.background).lease)
        let task = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                await flag.mark()
            } catch {}
        }
        await arbiter.attach(task, to: background)

        let admission = await arbiter.begin(.proactive)

        guard case .preempted(let proactive, let previousID) = admission else {
            Issue.record("expected proactive preemption, got \(admission)")
            return
        }
        #expect(previousID == background.id)
        #expect(proactive.priority == .proactive)
        await Task.yield()
        #expect(await flag.wasCancelled)
        #expect(!(await arbiter.owns(background)))
        #expect(await arbiter.owns(proactive))
        await arbiter.cancelAll()
    }

    @Test func lowerAndEqualPriorityWorkDropsForEveryActiveOwner() async throws {
        let backgroundArbiter = CopilotWorkArbiter()
        _ = try #require(await backgroundArbiter.begin(.background).lease)
        #expect(await backgroundArbiter.begin(.background) == .dropped)
        await backgroundArbiter.cancelAll()

        let proactiveArbiter = CopilotWorkArbiter()
        _ = try #require(await proactiveArbiter.begin(.proactive).lease)
        #expect(await proactiveArbiter.begin(.background) == .dropped)
        #expect(await proactiveArbiter.begin(.proactive) == .dropped)
        await proactiveArbiter.cancelAll()

        let userArbiter = CopilotWorkArbiter()
        _ = try #require(await userArbiter.begin(.userRequest).lease)
        #expect(await userArbiter.begin(.background) == .dropped)
        #expect(await userArbiter.begin(.proactive) == .dropped)
        await userArbiter.cancelAll()
    }

    @Test func explicitRequestReplacesAnotherExplicitRequestAndRejectsStaleResult() async throws {
        let arbiter = CopilotWorkArbiter()
        let first = try #require(await arbiter.begin(.userRequest).lease)

        let admission = await arbiter.begin(.userRequest)

        guard case .preempted(let replacement, let previousID) = admission else {
            Issue.record("expected explicit replacement, got \(admission)")
            return
        }
        #expect(previousID == first.id)
        #expect(!(await arbiter.owns(first)))
        #expect(!(await arbiter.ownsPresentation(first)))
        #expect(await arbiter.owns(replacement))
        await arbiter.finish(first, retainCard: true)
        #expect(await arbiter.owns(replacement), "a stale completion cannot clear the winner")
        #expect(!(await arbiter.ownsPresentation(first)))
        await arbiter.finish(replacement, retainCard: true)
        #expect(await arbiter.ownsPresentation(replacement))
        #expect(!(await arbiter.owns(replacement)))
    }

    @Test func retainedRequestedCardBlocksProactiveButAllowsSummaryRefresh() async throws {
        let arbiter = CopilotWorkArbiter()
        let request = try #require(await arbiter.begin(.userRequest).lease)
        await arbiter.finish(request, retainCard: true)

        #expect(await arbiter.retainedCardLease == request)
        #expect(await arbiter.begin(.proactive) == .dropped)
        let background = try #require(await arbiter.begin(.background).lease)
        #expect(await arbiter.owns(background))

        let next = await arbiter.begin(.userRequest)
        guard case .preempted(let replacement, let previousID) = next else {
            Issue.record("expected request to preempt summary, got \(next)")
            return
        }
        #expect(previousID == background.id)
        #expect(!(await arbiter.ownsPresentation(request)))
        #expect(await arbiter.owns(replacement))
    }

    @Test func retainedProactiveCardBlocksAutomaticWorkUntilDismissed() async throws {
        let arbiter = CopilotWorkArbiter()
        let proactive = try #require(await arbiter.begin(.proactive).lease)
        await arbiter.finish(proactive, retainCard: true)

        #expect(await arbiter.hasActiveProactiveCard)
        #expect(await arbiter.begin(.background) == .dropped)
        #expect(await arbiter.begin(.proactive) == .dropped)

        await arbiter.dismiss(proactive)
        #expect(!(await arbiter.hasActiveProactiveCard))
        #expect(await arbiter.begin(.background).lease != nil)
        await arbiter.cancelAll()
    }

    @Test func staleDismissAndCancelCannotDisturbTheCurrentWinner() async throws {
        let arbiter = CopilotWorkArbiter()
        let stale = try #require(await arbiter.begin(.proactive).lease)
        let current = try #require(await arbiter.begin(.userRequest).lease)

        await arbiter.dismiss(stale)
        await arbiter.cancel(stale)

        #expect(await arbiter.activeLease == current)
        #expect(await arbiter.owns(current))
    }

    @Test func cancelAllCancelsTaskAndInvalidatesEveryLease() async throws {
        let arbiter = CopilotWorkArbiter()
        let flag = CancellationFlag()
        let lease = try #require(await arbiter.begin(.userRequest).lease)
        let task = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                await flag.mark()
            } catch {}
        }
        await arbiter.attach(task, to: lease)

        await arbiter.cancelAll()
        await Task.yield()

        #expect(await flag.wasCancelled)
        #expect(!(await arbiter.owns(lease)))
        #expect(!(await arbiter.ownsPresentation(lease)))
        #expect(!(await arbiter.hasActiveWork))
    }
}
