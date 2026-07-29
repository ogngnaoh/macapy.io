import Foundation

/// URL protocols that fail deterministically, for proving how the client
/// surfaces the failures URLSession *does* detect (unlike the graceful-close
/// truncation the fake server produces, which URLSession ends without error).
///
/// Each failure mode is its own class with immutable configuration — no shared
/// mutable statics, because swift-testing runs a suite's tests concurrently and
/// configurable statics are exactly the race `LiveCredentialsTests` shipped and
/// had to fix (slice-02 note 23).

/// Fails every load immediately with `URLError(.cannotConnectToHost)` — the
/// connect-refused / bad-host class.
public final class ConnectFailingURLProtocol: URLProtocol {
    public static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectFailingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override public func stopLoading() {}
}

/// Delivers a 200 SSE response and one content-delta frame, then fails with
/// `URLError(.networkConnectionLost)` — the mid-stream RST class.
public final class MidStreamFailingURLProtocol: URLProtocol {
    /// The token the delivered frame carries, so tests can assert it arrived.
    public static let deliveredToken = "par"

    public static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MidStreamFailingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let frame = "data: " + OpenAIFixtures.contentDelta(Self.deliveredToken) + "\n\n"
        client?.urlProtocol(self, didLoad: Data(frame.utf8))
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }

    override public func stopLoading() {}
}
