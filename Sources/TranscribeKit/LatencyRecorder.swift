import Foundation

/// One instrument feeding three consumers (slice-05 doc decision 1): the
/// authoritative `LatencyHarness` executable, the debug-config
/// `G1BudgetTests` regression tripwire, and the in-app diagnostics section.
/// `@unchecked Sendable` + a lock: `MeetingPipeline` records from one task
/// per capture source concurrently, so `record(kind:audioTEnd:arrivalWall:)`
/// must be safe to call from multiple isolation domains at once.
public final class LatencyRecorder: @unchecked Sendable {
    public enum Kind: Sendable, Equatable {
        case volatile
        case final
    }

    public struct Sample: Sendable, Equatable {
        public let kind: Kind
        public let audioTEnd: TimeInterval
        public let arrivalWall: Date

        public init(kind: Kind, audioTEnd: TimeInterval, arrivalWall: Date) {
            self.kind = kind
            self.audioTEnd = audioTEnd
            self.arrivalWall = arrivalWall
        }
    }

    private let lock = NSLock()
    private let sessionStart: Date
    private var samples: [Sample] = []

    public init(sessionStart: Date) {
        self.sessionStart = sessionStart
    }

    /// Records one event's arrival. `audioTEnd` is the session-relative end
    /// time of the speech the event covers (a volatile/final's own `tEnd`);
    /// `arrivalWall` is the wall-clock moment the event reached its
    /// consumer. Latency is derived lazily, in `report()`.
    public func record(kind: Kind, audioTEnd: TimeInterval, arrivalWall: Date) {
        lock.lock()
        samples.append(Sample(kind: kind, audioTEnd: audioTEnd, arrivalWall: arrivalWall))
        lock.unlock()
    }

    /// Snapshots the current samples and computes p50/p95/max per kind
    /// (slice-05 doc decision 3's documented approximation of G1):
    /// `arrivalWall − (sessionStart + audioTEnd)`, in milliseconds.
    public func report() -> LatencyReport {
        lock.lock()
        let snapshot = samples
        lock.unlock()

        let volatileMs = snapshot.filter { $0.kind == .volatile }.map(latencyMs)
        let finalMs = snapshot.filter { $0.kind == .final }.map(latencyMs)
        return LatencyReport(
            volatile: LatencyReport.Stats(latenciesMs: volatileMs),
            final: LatencyReport.Stats(latenciesMs: finalMs)
        )
    }

    private func latencyMs(_ sample: Sample) -> Double {
        (sample.arrivalWall.timeIntervalSince(sessionStart) - sample.audioTEnd) * 1_000
    }
}

/// p50/p95/max + event count, one set per `LatencyRecorder.Kind`.
public struct LatencyReport: Sendable, Equatable {
    /// Percentiles use the nearest-rank method: sort latencies ascending,
    /// `rank = ceil(p * n)` (1-based, clamped to `[1, n]`), value =
    /// `sorted[rank - 1]`. Deterministic and simple to pin exactly against
    /// synthetic samples (acceptance check 1) — no interpolation ambiguity.
    public struct Stats: Sendable, Equatable {
        public let count: Int
        public let p50Ms: Double
        public let p95Ms: Double
        public let maxMs: Double

        init(latenciesMs: [Double]) {
            let sorted = latenciesMs.sorted()
            count = sorted.count
            p50Ms = Stats.percentile(0.50, of: sorted)
            p95Ms = Stats.percentile(0.95, of: sorted)
            maxMs = sorted.last ?? 0
        }

        private static func percentile(_ p: Double, of sorted: [Double]) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let rank = Int((p * Double(sorted.count)).rounded(.up))
            let clamped = Swift.min(Swift.max(rank, 1), sorted.count)
            return sorted[clamped - 1]
        }
    }

    public let volatile: Stats
    public let final: Stats
}
