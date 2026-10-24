import Foundation
import GRDB
import MemoryKit

extension DocumentStore {
    /// Optional experiment inputs. The caller must explicitly choose to run
    /// the local embedder; production retrieval does not read these vectors.
    public func embeddingInputs(id: UUID) throws -> [DocumentEmbeddingInput] {
        try Task.checkCancellation()
        return try database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT c.*,d.textHash,d.chunkerVersion FROM document_chunks c JOIN documents d ON d.id=c.documentID WHERE d.id=? ORDER BY c.ordinal", arguments: [id]).map { row in
                .init(source: Self.embeddingSource(row), text: row["text"], sourceHash: row["textHash"], chunkerVersion: row["chunkerVersion"])
            }
        }
    }

    public func storeEmbedding(_ vector: EmbeddingVector, for input: DocumentEmbeddingInput) throws {
        try Task.checkCancellation()
        guard !indexingPaused else { throw MemoryStoreError.indexingPaused }
        guard vector.dimension > 0, vector.dimension <= 4_096, vector.values.count == vector.dimension,
              vector.values.allSatisfy(\.isFinite), !vector.language.isEmpty else { throw LocalEmbeddingError.invalidVector }
        try database.dbWriter.write { db in
            guard try MemoryStore.sourceIsValid(input.source, in: db, requireAIConsent: false),
                  let row = try Row.fetchOne(db, sql: "SELECT c.text,d.textHash,d.chunkerVersion FROM document_chunks c JOIN documents d ON d.id=c.documentID WHERE c.id=?", arguments: [input.source.sourceID]),
                  input.chunkerVersion == row["chunkerVersion"], input.sourceHash == row["textHash"], input.text == row["text"] else { throw MemoryStoreError.revisionConflict }
            try db.execute(sql: """
                INSERT INTO document_embeddings(chunkID,language,modelRevision,dimension,chunkerVersion,sourceHash,vector)
                VALUES(?,?,?,?,?,?,?) ON CONFLICT(chunkID) DO UPDATE SET language=excluded.language,
                    modelRevision=excluded.modelRevision,dimension=excluded.dimension,chunkerVersion=excluded.chunkerVersion,
                    sourceHash=excluded.sourceHash,vector=excluded.vector
                """, arguments: [input.source.sourceID, vector.language, vector.modelRevision, vector.dimension,
                                  input.chunkerVersion, input.sourceHash, try JSONEncoder().encode(vector.values)])
        }
    }

    /// Version mismatch has an empty result, requiring a deliberate rebuild.
    /// Never reinterpret incompatible vectors as if they shared a model.
    public func embeddings(id: UUID, language: String, modelRevision: Int, dimension: Int) throws -> [StoredDocumentEmbedding] {
        try Task.checkCancellation()
        return try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.*,e.vector FROM document_embeddings e JOIN document_chunks c ON c.id=e.chunkID
                JOIN documents d ON d.id=c.documentID WHERE d.id=? AND e.language=? AND e.modelRevision=?
                    AND e.dimension=? AND e.chunkerVersion=d.chunkerVersion AND e.sourceHash=d.textHash
                ORDER BY c.ordinal LIMIT 10000
                """, arguments: [id, language, modelRevision, dimension])
            return try rows.compactMap { row in
                let values = try JSONDecoder().decode([Double].self, from: row["vector"] as Data)
                guard values.count == dimension, values.allSatisfy(\.isFinite) else { return nil }
                return .init(source: Self.embeddingSource(row), vector: .init(language: language, modelRevision: modelRevision, values: values))
            }
        }
    }

    private static func embeddingSource(_ row: Row) -> SourceReference {
        .init(kind: .documentChunk, sourceID: row["id"], revision: row["revision"], documentID: row["documentID"],
              pageNumber: row["pageNumber"], startCharacter: row["startCharacter"], endCharacter: row["endCharacter"])
    }
}
