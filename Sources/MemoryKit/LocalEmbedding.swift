import Foundation
import NaturalLanguage

public struct EmbeddingVector: Codable, Equatable, Sendable {
    public let language: String
    public let modelRevision: Int
    public let dimension: Int
    public let values: [Double]
    public init(language: String, modelRevision: Int, values: [Double]) {
        self.language = language; self.modelRevision = modelRevision; self.dimension = values.count; self.values = values
    }
}

public enum LocalEmbeddingError: Error, Equatable, Sendable { case experimentDisabled, unavailable, invalidVector }

/// An explicit experiment only: retrieval remains lexical until its independent
/// frozen quality/latency gate proves a benefit. The actor serializes every
/// access to the optional platform model and never requests an asset download.
public actor PlatformSentenceEmbedder {
    private let language: String
    private let enabledForExperiment: Bool
    private var model: NLEmbedding?
    public init(language: String = "en", enabledForExperiment: Bool = false) {
        self.language = language; self.enabledForExperiment = enabledForExperiment
    }
    public func embed(_ text: String) throws -> EmbeddingVector {
        try Task.checkCancellation()
        guard enabledForExperiment else { throw LocalEmbeddingError.experimentDisabled }
        if model == nil { model = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: language)) }
        guard let model, let vector = model.vector(for: String(text.prefix(8_000))) else { throw LocalEmbeddingError.unavailable }
        guard vector.count == model.dimension, vector.allSatisfy(\.isFinite) else { throw LocalEmbeddingError.invalidVector }
        return .init(language: language, modelRevision: model.revision, values: vector)
    }
}

public enum ExactVectorSearch {
    /// Bounded, cancellation-aware cosine experiment; incompatible model or
    /// dimension metadata is excluded rather than silently mixed.
    public static func rank(query: EmbeddingVector, candidates: [(UUID, EmbeddingVector)], limit: Int = 8) throws -> [(UUID, Double)] {
        guard candidates.count <= 10_000 else { throw MemoryStoreError.capacityExceeded }
        guard query.values.count == query.dimension, query.values.allSatisfy(\.isFinite) else { throw LocalEmbeddingError.invalidVector }
        let qNorm = sqrt(query.values.reduce(0) { $0 + $1 * $1 })
        guard qNorm > 0, qNorm.isFinite else { throw LocalEmbeddingError.invalidVector }
        var ranked: [(UUID, Double)] = []
        for (id, vector) in candidates {
            try Task.checkCancellation()
            guard vector.dimension == query.dimension, vector.language == query.language,
                  vector.modelRevision == query.modelRevision, vector.values.count == query.dimension,
                  vector.values.allSatisfy(\.isFinite) else { continue }
            var dot = 0.0, norm = 0.0
            for index in query.values.indices { dot += query.values[index] * vector.values[index]; norm += vector.values[index] * vector.values[index] }
            guard norm > 0, norm.isFinite else { continue }
            ranked.append((id, dot / (qNorm * sqrt(norm))))
        }
        return Array(ranked.sorted { $0.1 == $1.1 ? $0.0.uuidString < $1.0.uuidString : $0.1 > $1.1 }.prefix(max(0, min(8, limit))))
    }
}
