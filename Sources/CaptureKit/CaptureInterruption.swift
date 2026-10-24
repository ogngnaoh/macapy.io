import Foundation

/// An allowlisted runtime failure. Native errors, device identifiers, and
/// captured content never cross this presentation boundary.
public struct CaptureInterruption: Error, Sendable, Equatable {
    public enum Reason: String, Sendable {
        case routeChanged, conversionFailed, pauseFailed, resumeFailed, sourceUnavailable
    }
    public let source: AudioSource
    public let reason: Reason
    public init(source: AudioSource, reason: Reason) { self.source = source; self.reason = reason }
}

/// Callback-safe, one failure per capture generation. The reporter carries its
/// generation, so a queued native callback cannot fail a reused source.
public final class CaptureInterruptionChannel: @unchecked Sendable {
    public struct Reporter: Sendable {
        private let report: @Sendable (CaptureInterruption.Reason) -> Void
        fileprivate init(_ report: @escaping @Sendable (CaptureInterruption.Reason) -> Void) { self.report = report }
        public func callAsFunction(_ reason: CaptureInterruption.Reason) { report(reason) }
    }
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var reported = false
    private var continuations: [UUID: AsyncStream<CaptureInterruption>.Continuation] = [:]

    public init() {}
    deinit { end() }

    public func stream() -> AsyncStream<CaptureInterruption> {
        let id = UUID()
        let made = AsyncStream<CaptureInterruption>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock { continuations[id] = made.continuation }
        made.continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
        }
        return made.stream
    }

    public func begin(source: AudioSource) -> Reporter {
        let token = lock.withLock { generation &+= 1; reported = false; return generation }
        return Reporter { [weak self] reason in self?.publish(.init(source: source, reason: reason), token: token) }
    }

    private func publish(_ event: CaptureInterruption, token: UInt64) {
        let streams = lock.withLock { () -> [AsyncStream<CaptureInterruption>.Continuation] in
            guard generation == token, !reported else { return [] }
            reported = true
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for stream in streams { stream.yield(event); stream.finish() }
    }

    public func end() {
        let streams = lock.withLock {
            generation &+= 1
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for stream in streams { stream.finish() }
    }
}
