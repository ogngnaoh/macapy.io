import Foundation
import ProviderKit

/// Text-free synchronous diagnostics mirror for recovery polling. The
/// per-meeting orchestrator is its only writer; presentation uses typed events.
public final class CopilotRecoveryDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    public init() {}
    public var transientFailureCount: Int { lock.withLock { count } }

    func setTransientFailureCount(_ value: Int) {
        lock.withLock { count = value }
    }
}

/// Deterministic recovery timing for live, automatic copilot work. The first
/// four failures use exponential backoff; every later failure remains capped
/// at five minutes.
public struct CopilotRecoveryPolicy: Sendable, Equatable {
    public static let `default` = CopilotRecoveryPolicy()

    public let delays: [TimeInterval]

    public init(delays: [TimeInterval] = [30, 60, 120, 240, 300]) {
        precondition(!delays.isEmpty)
        precondition(delays.allSatisfy { $0 >= 0 && $0 <= 300 })
        self.delays = delays
    }

    public func delay(afterTransientFailure failureCount: Int) -> TimeInterval {
        delays[min(max(failureCount, 1) - 1, delays.count - 1)]
    }

    public func disposition(for error: any Error) -> CopilotFailureDisposition {
        guard let providerError = error as? ProviderError else { return .transient }
        switch providerError {
        case .capReached:
            return .cap
        case .missingCredentials:
            return .authenticationOrConfiguration
        case .http(let status, _)
            where status != 408 && status != 429 && (400..<500).contains(status):
            return .authenticationOrConfiguration
        case .transport, .rateLimited, .server, .inStreamError,
             .malformedResponse, .decodingFailed, .truncated, .http:
            return .transient
        }
    }
}

public enum CopilotFailureDisposition: Sendable, Equatable {
    case transient
    case authenticationOrConfiguration
    case cap
}

/// A generation-stamped delay. Stamps make a scheduler wake harmless after a
/// success, cancellation, provider replacement, AI-off, or meeting teardown.
public struct CopilotRecoveryTicket: Sendable, Equatable {
    public let generation: UInt64
    public let failureCount: Int
    public let delay: TimeInterval
}

/// Small value controller intentionally separated from sleeping. AppShell
/// owns the monotonic scheduler (`Task.sleep(for:)` in production, injected in
/// tests), while this type owns attempt progression and stale-wake rejection.
public struct CopilotRecoveryController: Sendable, Equatable {
    public private(set) var transientFailureCount = 0
    private var generation: UInt64 = 0
    public let policy: CopilotRecoveryPolicy

    public init(policy: CopilotRecoveryPolicy = .default) {
        self.policy = policy
    }

    public mutating func recordTransientFailure() -> CopilotRecoveryTicket {
        transientFailureCount += 1
        generation &+= 1
        return CopilotRecoveryTicket(
            generation: generation,
            failureCount: transientFailureCount,
            delay: policy.delay(afterTransientFailure: transientFailureCount)
        )
    }

    public func owns(_ ticket: CopilotRecoveryTicket) -> Bool {
        ticket.generation == generation
            && ticket.failureCount == transientFailureCount
            && transientFailureCount > 0
    }

    /// A successful provider operation starts the next failure sequence over.
    public mutating func recordSuccess() {
        transientFailureCount = 0
        generation &+= 1
    }

    /// Invalidates any scheduled wake without implying provider success.
    public mutating func invalidate() {
        transientFailureCount = 0
        generation &+= 1
    }
}
