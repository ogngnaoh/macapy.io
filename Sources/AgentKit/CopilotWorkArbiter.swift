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
    private var proactiveCardID: UUID?

    public init() {}

    public func begin(_ priority: CopilotWorkPriority) -> CopilotWorkAdmission {
        switch priority {
        case .background, .proactive:
            guard active == nil, proactiveCardID == nil else { return .dropped }
            let lease = CopilotWorkLease(priority: priority)
            active = Active(lease: lease)
            return .started(lease)

        case .userRequest:
            let previousID = active?.lease.id ?? proactiveCardID
            active?.task?.cancel()
            active = nil
            proactiveCardID = nil
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
            proactiveCardID = lease.id
        }
    }

    public func cancel(_ lease: CopilotWorkLease) {
        guard active?.lease == lease else { return }
        active?.task?.cancel()
        active = nil
    }

    public func dismissProactiveCard() {
        proactiveCardID = nil
    }

    public func cancelAll() {
        active?.task?.cancel()
        active = nil
        proactiveCardID = nil
    }

    public var hasActiveWork: Bool { active != nil }
    public var hasActiveProactiveCard: Bool { proactiveCardID != nil }
}
