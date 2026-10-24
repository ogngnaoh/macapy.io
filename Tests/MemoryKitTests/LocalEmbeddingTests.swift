import Foundation
import Testing
@testable import MemoryKit

struct LocalEmbeddingTests {
    @Test func platformExperimentRequiresExplicitEnablement() async {
        await #expect(throws: LocalEmbeddingError.experimentDisabled) { try await PlatformSentenceEmbedder().embed("Do not load models implicitly") }
    }
    @Test func exactRankingRejectsIncompatibleVersionsAndDimensions() throws {
        let same = UUID(), opposite = UUID()
        let query = EmbeddingVector(language: "en", modelRevision: 1, values: [1, 0])
        let result = try ExactVectorSearch.rank(query: query, candidates: [
            (opposite, .init(language: "en", modelRevision: 1, values: [-1, 0])),
            (UUID(), .init(language: "en", modelRevision: 2, values: [1, 0])),
            (UUID(), .init(language: "fr", modelRevision: 1, values: [1, 0])),
            (UUID(), .init(language: "en", modelRevision: 1, values: [1, 0, 0])),
            (same, query),
        ])
        #expect(result.map { $0.0 } == [same, opposite])
        #expect(result.map { $0.1 } == [1, -1])
        #expect(throws: LocalEmbeddingError.invalidVector) {
            try ExactVectorSearch.rank(query: .init(language: "en", modelRevision: 1, values: [0, 0]), candidates: [])
        }
    }
}
