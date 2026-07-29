import Foundation

/// A real HTTP/1.1 listener on loopback that impersonates an OpenAI-compatible
/// chat-completions endpoint (slice-02 doc decision 6).
///
/// Deliberately a *real socket* rather than a `URLProtocol` stub: the client
/// under test is URLSession SSE streaming, and the failure modes worth proving
/// (chunked framing, a body truncated mid-stream, a 429 followed by a success)
/// only exist below `URLSession`'s API surface. A stub would test our own mock.
///
/// POSIX sockets rather than `NWListener`: every `NWListener` configuration
/// tried here fails `EINVAL` at `start` on this machine (loopback-required,
/// interface-required, and plain `.tcp` alike), while `socket`/`bind`/`listen`
/// on 127.0.0.1 works — see slice-02 doc Notes. Sockets also give exact control
/// over the two things the failure tests need: chunk framing and closing a
/// connection mid-body.
///
/// Responses are scripted per request — one `Response` popped per incoming HTTP
/// request, so a `[.json(429…), .sse(…)]` script *is* the retry-recovery case.
/// Requests are recorded so quirks assertions (acceptance check 3) can inspect
/// exactly what the client put on the wire.
public final class FakeOpenAIServer: @unchecked Sendable {

    /// One scripted reply. `sse` writes `Transfer-Encoding: chunked` frames —
    /// which is what makes `truncateAfterFrames` a *protocol-level* truncation
    /// (URLSession reports a transport error) rather than a legitimate
    /// connection-close end-of-body that would look like clean completion.
    public enum Response: Sendable {
        /// 200 `text/event-stream`. Each element is written as one
        /// `data: <payload>\n\n` frame; pass `OpenAIFixtures.done` last.
        /// With `truncateAfterFrames: n`, the connection closes after `n`
        /// frames without the terminating zero-length chunk.
        case sse(frames: [String], truncateAfterFrames: Int? = nil)
        /// A complete non-streaming reply with an explicit status code.
        case json(status: Int, body: String)
    }

    /// What the client actually sent, captured before the reply is written.
    public struct RecordedRequest: Sendable {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let body: Data

        /// The body parsed as a JSON object, or `nil` if it isn't one.
        public var jsonBody: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    public enum StartError: Error, Equatable {
        case socketFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
    }

    /// Milliseconds between SSE frames. Small but non-zero: the point is that
    /// frames reach the client as separate reads, not one buffer.
    private static let frameIntervalMicroseconds: UInt32 = 5_000

    /// The loopback base URL to point a client at, e.g. `http://127.0.0.1:53422`.
    public let baseURL: URL

    private let listenFD: Int32
    private let lock = NSLock()
    private var scripted: [Response]
    private var recorded: [RecordedRequest] = []
    private var stopped = false

    private init(listenFD: Int32, port: UInt16, responses: [Response]) {
        self.listenFD = listenFD
        self.scripted = responses
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Binds an ephemeral loopback port and starts accepting. `responses` are
    /// consumed in order, one per request; a request past the end of the script
    /// gets a 500 whose body says so (a silent hang would be worse).
    public static func start(responses: [Response]) throws -> FakeOpenAIServer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socketFailed(errno: errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Without SO_NOSIGPIPE, writing to a connection the client already
        // closed raises SIGPIPE and takes the whole test process down.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // ephemeral
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw StartError.bindFailed(errno: code)
        }
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw StartError.listenFailed(errno: code)
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }

        let server = FakeOpenAIServer(
            listenFD: fd,
            port: UInt16(bigEndian: assigned.sin_port),
            responses: responses
        )
        server.startAcceptLoop()
        return server
    }

    /// Requests seen so far, in arrival order.
    public var recordedRequests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Stops accepting and closes the listening socket. Call from a test's
    /// `defer`; safe to call twice.
    public func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        // The accept loop polls `isStopped` on a 50ms timeout, so it exits on
        // its own; closing here would race it onto a reused descriptor.
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    // MARK: - Accept loop

    private func startAcceptLoop() {
        Thread.detachNewThread { [self] in
            while !isStopped {
                var descriptor = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else { continue }

                let connectionFD = accept(listenFD, nil, nil)
                guard connectionFD >= 0 else { continue }
                var yes: Int32 = 1
                setsockopt(connectionFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                // One thread per connection: URLSession may hold several open
                // at once, and a streaming reply occupies its thread for the
                // length of the script.
                Thread.detachNewThread { [self] in
                    handleConnection(connectionFD)
                    close(connectionFD)
                }
            }
            close(listenFD)
        }
    }

    private func handleConnection(_ fd: Int32) {
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 16 * 1024)

        while !isStopped {
            guard let request = Self.parseRequest(buffer) else {
                let count = read(fd, &scratch, scratch.count)
                guard count > 0 else { return }
                buffer.append(contentsOf: scratch[0..<count])
                continue
            }

            lock.lock()
            recorded.append(request)
            let response: Response? = scripted.isEmpty ? nil : scripted.removeFirst()
            lock.unlock()

            write(response, to: fd)
            return
        }
    }

    /// `nil` until the whole request (headers + declared body) is present.
    private static func parseRequest(_ buffer: Data) -> RecordedRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let expectedBodyLength = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= expectedBodyLength else { return nil }

        return RecordedRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(body.prefix(expectedBodyLength))
        )
    }

    // MARK: - Response writing

    private func write(_ response: Response?, to fd: Int32) {
        guard let response else {
            let body = OpenAIFixtures.errorBody(message: "fake server: no scripted response left")
            writeJSON(status: 500, body: body, to: fd)
            return
        }

        switch response {
        case .json(let status, let body):
            writeJSON(status: status, body: body, to: fd)

        case .sse(let frames, let truncateAfterFrames):
            let head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/event-stream\r\n"
                + "Cache-Control: no-cache\r\n"
                + "Transfer-Encoding: chunked\r\n"
                + "Connection: close\r\n\r\n"
            guard writeAll(head, to: fd) else { return }

            for (index, frame) in frames.enumerated() {
                usleep(Self.frameIntervalMicroseconds)
                guard writeAll(Self.chunked("data: \(frame)\n\n"), to: fd) else { return }
                if let truncateAfterFrames, index + 1 >= truncateAfterFrames {
                    // No terminating zero-length chunk: the body is cut off
                    // mid-stream, which the client must surface as a transport
                    // error rather than a clean end (acceptance check 4).
                    usleep(Self.frameIntervalMicroseconds)
                    return
                }
            }
            _ = writeAll("0\r\n\r\n", to: fd)
        }
    }

    private func writeJSON(status: Int, body: String, to fd: Int32) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        guard writeAll(head, to: fd) else { return }
        _ = writeAll(body, to: fd)
    }

    /// Writes every byte, tolerating short writes. `false` means the peer went
    /// away — the caller stops.
    @discardableResult
    private func writeAll(_ text: String, to fd: Int32) -> Bool {
        var bytes = [UInt8](text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                Foundation.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    private static func chunked(_ payload: String) -> String {
        String(payload.utf8.count, radix: 16) + "\r\n" + payload + "\r\n"
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
