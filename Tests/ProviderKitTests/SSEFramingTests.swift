import Foundation
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// SSE framing must follow the SSE spec — lines end at LF/CRLF/CR, events end
/// at a blank line, multiple `data:` lines join with a newline — and must NOT
/// use Foundation's `AsyncLineSequence`, which also splits on U+2028/U+2029/NEL.
/// Those characters are legal *unescaped inside JSON strings* (Node's
/// `JSON.stringify` emits them raw), so a delta token containing one would tear
/// the payload mid-JSON and kill a healthy stream (slice-2 critic pass,
/// confirmed empirically against `AsyncLineSequence`).
struct SSEFramingTests {

    private func events(from server: FakeOpenAIServer) async throws -> [LLMEvent] {
        let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
        var events: [LLMEvent] = []
        for try await event in client.stream(.hello) { events.append(event) }
        return events
    }

    private static func rawFrame(_ payload: String) -> Data {
        Data(("data: " + payload + "\n\n").utf8)
    }

    @Test(arguments: ["\u{2028}", "\u{2029}", "\u{0085}"])
    func unicodeLineSeparatorsInsideATokenSurviveIntact(separator: String) async throws {
        // Built by hand so the wire bytes are guaranteed raw (E2 80 A8 etc.),
        // not entity-escaped by a JSON encoder.
        let payload = #"{"choices":[{"delta":{"content":"foo\#(separator)bar"},"finish_reason":null}]}"#
        let server = try FakeOpenAIServer.start(responses: [
            .sseRaw(chunks: [
                Self.rawFrame(payload),
                Self.rawFrame(OpenAIFixtures.finish()),
                Self.rawFrame("[DONE]"),
            ])
        ])
        defer { server.stop() }

        let events = try await events(from: server)

        #expect(events.contains(.token("foo\(separator)bar")))
    }

    @Test func anEventSplitAcrossDeliveriesMidJSONAndMidCodePointIsReassembled() async throws {
        let frame = [UInt8](Self.rawFrame(OpenAIFixtures.contentDelta("héllo")))
        // One cut inside the `data:` prefix, one inside é's two UTF-8 bytes.
        let midCodePoint = try #require(frame.firstIndex(of: 0xC3)) + 1
        let chunks = [
            Data(frame[0..<5]),
            Data(frame[5..<midCodePoint]),
            Data(frame[midCodePoint...]),
            Self.rawFrame(OpenAIFixtures.finish()),
            Self.rawFrame("[DONE]"),
        ]
        let server = try FakeOpenAIServer.start(responses: [.sseRaw(chunks: chunks)])
        defer { server.stop() }

        let events = try await events(from: server)

        #expect(events.contains(.token("héllo")))
    }

    @Test func multipleDataLinesOfOneEventJoinBeforeDecoding() async throws {
        // The SSE spec joins consecutive `data:` lines with "\n" — which is
        // exactly how a proxy that pretty-prints its JSON chunks arrives.
        let event = "data: {\"choices\": [{\"delta\":\ndata: {\"content\": \"hi\"}}]}\n\n"
        let server = try FakeOpenAIServer.start(responses: [
            .sseRaw(chunks: [
                Data(event.utf8),
                Self.rawFrame(OpenAIFixtures.finish()),
                Self.rawFrame("[DONE]"),
            ])
        ])
        defer { server.stop() }

        let events = try await events(from: server)

        #expect(events.contains(.token("hi")))
    }

    @Test func commentKeepAlivesAndEmptyDataLinesAreIgnored() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sseRaw(chunks: [
                Data(": keep-alive\n\n".utf8),
                Data("data:\n\n".utf8),
                Self.rawFrame(OpenAIFixtures.contentDelta("hi")),
                Data(": ping\n\n".utf8),
                Self.rawFrame(OpenAIFixtures.finish()),
                Self.rawFrame("[DONE]"),
            ])
        ])
        defer { server.stop() }

        let events = try await events(from: server)

        #expect(events.contains(.token("hi")))
        #expect(events.contains { if case .completed = $0 { true } else { false } })
    }

    /// The SSE spec strips one leading U+FEFF; without that, the first line
    /// reads "\u{FEFF}data: …", fails the field match, and the opening event
    /// is silently dropped (fix-review D4).
    @Test func aLeadingUTF8BOMDoesNotSwallowTheFirstEvent() async throws {
        var firstChunk = Data([0xEF, 0xBB, 0xBF])
        firstChunk.append(Self.rawFrame(OpenAIFixtures.contentDelta("hi")))
        let server = try FakeOpenAIServer.start(responses: [
            .sseRaw(chunks: [
                firstChunk,
                Self.rawFrame(OpenAIFixtures.finish()),
                Self.rawFrame("[DONE]"),
            ])
        ])
        defer { server.stop() }

        let events = try await events(from: server)

        #expect(events.contains(.token("hi")))
    }

    /// An event left unterminated at a *graceful* close (proper chunked
    /// terminator, no blank line after the last event) is discarded per spec,
    /// and the completion guard reports the truncation — the suite previously
    /// only proved the ungraceful variant (fix-reviewer's independent probe).
    @Test func anUnterminatedEventAtGracefulEOFSurfacesAsTruncation() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sseRaw(chunks: [
                Self.rawFrame(OpenAIFixtures.contentDelta("half")),
                Data(#"data: {"choices":[{"delta":{"content":"cut"#.utf8),
            ])
        ])
        defer { server.stop() }

        var events: [LLMEvent] = []
        var thrown: Error?
        do {
            let client = OpenAICompatibleClient(profile: .fake(baseURL: server.baseURL), apiKey: "sk-test")
            for try await event in client.stream(.hello) { events.append(event) }
        } catch {
            thrown = error
        }

        #expect(events.contains(.token("half")))
        guard case .transport = thrown as? ProviderError else {
            Issue.record("expected ProviderError.transport, got \(String(describing: thrown))")
            return
        }
    }

    @Test func crlfLineEndingsParseIdenticallyToLF() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sseRaw(chunks: [
                Data(("data: " + OpenAIFixtures.contentDelta("hi") + "\r\n\r\n").utf8),
                Data(("data: " + OpenAIFixtures.finish() + "\r\n\r\n").utf8),
                Data("data: [DONE]\r\n\r\n".utf8),
            ])
        ])
        defer { server.stop() }

        let events = try await events(from: server)

        #expect(events.contains(.token("hi")))
    }
}
