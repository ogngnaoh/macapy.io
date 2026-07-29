import Foundation

/// A `URLProtocol` that records every request a session tries to make and then
/// fails it, without a byte leaving the machine.
///
/// This is what makes the zero-network guarantee (PRD G4, SPEC G6) testable at
/// the unit level: install it on a session, exercise the provider layer with
/// nothing configured, and assert `recordedRequests.isEmpty`. Unlike a
/// hand-rolled spy, it sits below the client's own API, so it catches a request
/// built anywhere in the stack.
public final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    /// A session that can only reach this protocol — any real network attempt
    /// is recorded and refused.
    public static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    public static var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    public static func reset() {
        lock.lock()
        requests = []
        lock.unlock()
    }

    public override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return true
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    public override func stopLoading() {}
}
