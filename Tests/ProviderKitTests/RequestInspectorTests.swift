import Foundation
import Testing
@testable import ProviderKit

struct RequestInspectorTests {
    @Test func inspectorCapturesExactEncodedBodyWithoutHeaders() throws {
        let inspector = RequestInspector()
        let client = OpenAICompatibleClient(profile: .deepSeek, apiKey: "synthetic-auth-canary", inspector: inspector)
        let request = CompletionRequest(model: "scripted", messages: [.user("A synthetic Unicode note: café.")], purpose: .artifact, temperature: 0.3, maxTokens: 200)
        let encoded = try client.makeURLRequest(request, streaming: false)
        let snapshot = try #require(inspector.snapshots.first)
        #expect(snapshot.body == encoded.httpBody)
        #expect(!snapshot.bodyText.contains("synthetic-auth-canary"))
        #expect(snapshot.model == request.model)
        #expect(snapshot.sources == [.transcript])
    }

    @Test func evictionAndClearBoundMemoryAndRejectStaleDispatch() {
        let inspector = RequestInspector()
        let token = inspector.generation
        for _ in 0..<4 {
            _ = inspector.record(destination: URL(string: "https://example.invalid/v1")!, request: CompletionRequest(model: "sample", messages: [], purpose: .generation), body: Data(repeating: 32, count: 200_000), generation: token)
        }
        #expect(inspector.snapshots.count == 2)
        #expect(inspector.retainedBytes <= RequestInspector.maximumRetainedBytes)
        #expect(inspector.evictedCount == 2)
        inspector.clear()
        #expect(inspector.snapshots.isEmpty)
        #expect(!inspector.record(destination: URL(string: "https://example.invalid")!, request: CompletionRequest(model: "sample", messages: [], purpose: .generation), body: Data(), generation: token))
    }
}
