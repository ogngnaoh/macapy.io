import Foundation

public enum RequestSourceClass: String, Sendable, CaseIterable {
    case transcript = "Meeting transcript"
    case reviewedMemory = "Reviewed memory"
    case selectedDocuments = "Selected document excerpts"
    case selectedCalendarFields = "Selected calendar fields"
    case connectionTest = "Connection test"
}

public struct InspectedRequest: Sendable, Identifiable {
    public let id = UUID()
    public let at = Date()
    public let destination: String
    public let model: String
    public let purpose: Purpose
    public let sources: [RequestSourceClass]
    public let body: Data
    public var bodyText: String { String(decoding: body, as: UTF8.self) }
}

/// Memory-only, bounded inspection of the exact encoded body. It never
/// receives request headers, credentials, responses, or a persistence handle.
/// The lock protects all mutable storage and the dispatch-generation fence.
public final class RequestInspector: @unchecked Sendable {
    public static let maximumRequestBytes = 256 * 1024
    public static let maximumRetainedBytes = 512 * 1024
    public static let didChange = Notification.Name("io.macapy.requestInspectionChanged")
    private let lock = NSLock()
    private var requests: [InspectedRequest] = []
    private var epoch: UInt64 = 0
    private var evictions = 0

    public init() {}
    public var generation: UInt64 { lock.withLock { epoch } }
    public var snapshots: [InspectedRequest] { lock.withLock { requests } }
    public var evictedCount: Int { lock.withLock { evictions } }
    public var retainedBytes: Int { lock.withLock { requests.reduce(0) { $0 + $1.body.count } } }

    @discardableResult
    func record(destination: URL, request: CompletionRequest, body: Data, generation: UInt64) -> Bool {
        let accepted = lock.withLock {
            guard generation == epoch, body.count <= Self.maximumRequestBytes else { return false }
            var components = URLComponents(url: destination, resolvingAgainstBaseURL: false)
            components?.user = nil; components?.password = nil; components?.query = nil; components?.fragment = nil
            requests.insert(InspectedRequest(destination: components?.string ?? "Configured endpoint", model: request.model, purpose: request.purpose, sources: request.contextSources, body: body), at: 0)
            while requests.count > 3 || requests.reduce(0, { $0 + $1.body.count }) > Self.maximumRetainedBytes {
                requests.removeLast()
                evictions += 1
            }
            return true
        }
        if accepted { NotificationCenter.default.post(name: Self.didChange, object: self) }
        return accepted
    }

    public func clear() {
        lock.withLock {
            epoch &+= 1
            requests.removeAll(keepingCapacity: false)
            evictions = 0
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
