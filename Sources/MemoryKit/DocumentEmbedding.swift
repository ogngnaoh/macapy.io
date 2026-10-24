import Foundation

public struct DocumentEmbeddingInput: Sendable, Equatable {
    public let source: SourceReference
    public let text: String
    public let sourceHash: String
    public let chunkerVersion: Int
    public init(source: SourceReference, text: String, sourceHash: String, chunkerVersion: Int) {
        self.source = source; self.text = text; self.sourceHash = sourceHash; self.chunkerVersion = chunkerVersion
    }
}

public struct StoredDocumentEmbedding: Sendable, Equatable {
    public let source: SourceReference
    public let vector: EmbeddingVector
    public init(source: SourceReference, vector: EmbeddingVector) { self.source = source; self.vector = vector }
}
