import Foundation

/// Request priority for one meeting. Only one task is admitted at a time.
public enum CopilotWorkPriority: Int, Sendable, Equatable {
    case background
    case proactive
    case userRequest
}

public struct CopilotWorkLease: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let priority: CopilotWorkPriority

    fileprivate init(id: UUID = UUID(), priority: CopilotWorkPriority) {
        self.id = id
        self.priority = priority
    }
}

public enum CopilotWorkAdmission: Sendable, Equatable {
    case started(CopilotWorkLease)
    case preempted(CopilotWorkLease, previousID: UUID)
    case dropped

    public var lease: CopilotWorkLease? {
        switch self {
        case .started(let lease), .preempted(let lease, _): lease
        case .dropped: nil
        }
    }
}

/// Per-meeting concurrency authority. Proactive/background work never queues;
/// an explicit request cancels and replaces whatever is running, and also
/// clears the proactive-card occupancy that presentation holds after a stream.
public actor CopilotWorkArbiter {
    private struct Active {
        var lease: CopilotWorkLease
        var task: Task<Void, Never>?
    }

    private var active: Active?
    private var retainedCard: CopilotWorkLease?

    public init() {}

    public func begin(_ priority: CopilotWorkPriority) -> CopilotWorkAdmission {
        switch priority {
        case .background:
            // A retained proactive card still owns the automatic presentation
            // window. A retained requested card does not prevent the separate
            // rolling-summary strip from refreshing in the background.
            guard active == nil, retainedCard?.priority != .proactive else {
                return .dropped
            }
            let lease = CopilotWorkLease(priority: priority)
            active = Active(lease: lease)
            return .started(lease)

        case .proactive:
            // A proactive moment outranks rolling-summary work, but never
            // displaces another proactive/requested card or explicit work.
            guard retainedCard == nil else { return .dropped }
            if let current = active {
                guard current.lease.priority == .background else { return .dropped }
                current.task?.cancel()
                let lease = CopilotWorkLease(priority: priority)
                active = Active(lease: lease)
                return .preempted(lease, previousID: current.lease.id)
            }
            let lease = CopilotWorkLease(priority: priority)
            active = Active(lease: lease)
            return .started(lease)

        case .userRequest:
            let previousID = active?.lease.id ?? retainedCard?.id
            active?.task?.cancel()
            active = nil
            retainedCard = nil
            let lease = CopilotWorkLease(priority: priority)
            active = Active(lease: lease)
            if let previousID { return .preempted(lease, previousID: previousID) }
            return .started(lease)
        }
    }

    /// Attach after admission. If a higher-priority request already preempted
    /// this lease during task construction, the stale task is cancelled now.
    public func attach(_ task: Task<Void, Never>, to lease: CopilotWorkLease) {
        guard active?.lease == lease else {
            task.cancel()
            return
        }
        active?.task = task
    }

    /// End the task. A completed proactive task may retain one card, which
    /// blocks later proactive work until AppShell's timer or dismissal clears it.
    public func finish(_ lease: CopilotWorkLease, retainProactiveCard: Bool = false) {
        guard active?.lease == lease else { return }
        active = nil
        if retainProactiveCard, lease.priority == .proactive {
            retainedCard = lease
        }
    }

    /// Retains a completed requested or proactive card as the presentation
    /// winner. Background work has no card and is never retained.
    public func finish(_ lease: CopilotWorkLease, retainCard: Bool) {
        guard active?.lease == lease else { return }
        active = nil
        if retainCard, lease.priority != .background {
            retainedCard = lease
        }
    }

    public func cancel(_ lease: CopilotWorkLease) {
        if active?.lease == lease {
            active?.task?.cancel()
            active = nil
        }
        if retainedCard == lease { retainedCard = nil }
    }

    public func dismissProactiveCard() {
        guard retainedCard?.priority == .proactive else { return }
        retainedCard = nil
    }

    /// Dismisses this lease whether it is still streaming or retained as the
    /// visible result. Passing a stale lease cannot disturb the current owner.
    public func dismiss(_ lease: CopilotWorkLease) {
        cancel(lease)
    }

    public func cancelAll() {
        active?.task?.cancel()
        active = nil
        retainedCard = nil
    }

    /// Use before applying every streamed event. A preempted task may finish
    /// concurrently, but its lease can never regain ownership.
    public func owns(_ lease: CopilotWorkLease) -> Bool { active?.lease == lease }

    /// True for either the currently streaming owner or its retained result.
    public func ownsPresentation(_ lease: CopilotWorkLease) -> Bool {
        active?.lease == lease || retainedCard == lease
    }

    public var activeLease: CopilotWorkLease? { active?.lease }
    public var retainedCardLease: CopilotWorkLease? { retainedCard }
    public var hasActiveWork: Bool { active != nil }
    public var hasActiveProactiveCard: Bool { retainedCard?.priority == .proactive }
}
