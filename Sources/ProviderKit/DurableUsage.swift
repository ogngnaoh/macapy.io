import Foundation

public enum UsageScope: Sendable, Equatable {
    case meeting(UUID)
    case briefs
    public var meetingID: UUID? { if case .meeting(let id) = self { id } else { nil } }
}

public struct BackgroundUsageJob: Sendable, Equatable {
    public enum Trigger: String, Sendable { case automatic, userInitiated }
    /// Opaque source identity (event occurrence hash or meeting/job UUID).
    /// Never pass titles, transcript text, or other user content here.
    public let id: String
    public let revision: String
    /// Required for briefs: the current CalendarEventSnapshot.revision.
    public let sourceRevision: String?
    public let trigger: Trigger
    public init(id: String, revision: String, sourceRevision: String? = nil, trigger: Trigger = .automatic) {
        self.id = id; self.revision = revision; self.sourceRevision = sourceRevision; self.trigger = trigger
    }
}

public struct UsageAdmission: Sendable {
    public let id: UUID
    public let scope: UsageScope
    public let job: BackgroundUsageJob?
    public let model: String
    public let purpose: Purpose
    public let estimatedCostUSD: Double?
    public let meetingCapUSD: Double?
    public let at: Date
    public init(id: UUID = UUID(), scope: UsageScope, job: BackgroundUsageJob? = nil,
                model: String, purpose: Purpose, estimatedCostUSD: Double?, meetingCapUSD: Double?, at: Date = Date()) {
        self.id = id; self.scope = scope; self.job = job; self.model = model; self.purpose = purpose
        self.estimatedCostUSD = estimatedCostUSD; self.meetingCapUSD = meetingCapUSD; self.at = at
    }
}

public struct DurableUsageReservation: Sendable, Equatable {
    public let id: UUID
    public let scope: UsageScope
    public let estimatedCostUSD: Double?
    public let heldCostUSD: Double
    public init(id: UUID, scope: UsageScope, estimatedCostUSD: Double?, heldCostUSD: Double) {
        self.id = id; self.scope = scope; self.estimatedCostUSD = estimatedCostUSD; self.heldCostUSD = heldCostUSD
    }
}

public enum DurableUsageError: Error, Sendable, Equatable {
    case requiresDurableLedger, invalidAdmission, unpricedBackgroundModel, sourceUnavailable
    case duplicateJob, automaticLimitReached, debounceActive, clockMovedBackwards
    case invalidState, settlementConflict
}

public enum BriefUsagePolicy {
    public static let dailyCapUSD = 0.10
    public static let perGenerationCapUSD = 0.02
    public static let maximumAutomaticGenerations = 5
    public static let debounceSeconds: TimeInterval = 600
}

public struct BackgroundUsageSummary: Sendable, Equatable {
    public let dayStart: Date
    /// A fixed UTC boundary; presentation may format it in the user's zone.
    public let nextResetAt: Date
    public let knownCostUSD: Double
    /// Includes unresolved prior-day attempts, not only today's reservations.
    public let heldCostUSD: Double
    public let automaticCount: Int
    public var committedUSD: Double { knownCostUSD + heldCostUSD }
    public init(dayStart: Date, nextResetAt: Date, knownCostUSD: Double, heldCostUSD: Double, automaticCount: Int) {
        self.dayStart = dayStart; self.nextResetAt = nextResetAt; self.knownCostUSD = knownCostUSD
        self.heldCostUSD = heldCostUSD; self.automaticCount = automaticCount
    }
}

/// Optional production capability. Ordinary fake ledgers keep their existing
/// semantics; a background request refuses to run without durable admission.
public protocol DurableUsageLedger: SpendLedger {
    func admitUsage(_ admission: UsageAdmission) async throws -> DurableUsageReservation
    func markUsageDispatched(id: UUID) async throws
    func settleUsage(id: UUID, usage: TokenUsage?, costUSD: Double?, at: Date) async throws -> SpendEntry?
    /// Prepared means no dispatch occurred. Dispatched cancellation is unknown.
    func cancelUsage(id: UUID) async throws
    func usageCommitmentUSD(meetingID: UUID) async throws -> Double
    func usageUncertainUSD(meetingID: UUID) async throws -> Double
}
