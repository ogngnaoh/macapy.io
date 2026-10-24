import Foundation
import GRDB
import MemoryKit

public struct DocumentRecord: Codable, FetchableRecord, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let mediaType: String
    public let textHash: String
    public let revision: Int
    public let chunkerVersion: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let allowedForAI: Bool
}

/// Serial import/index ownership. Parsing finishes in MemoryKit first; a short
/// transaction publishes every chunk or rolls back to the old generation.
public actor DocumentStore {
    let database: MacapyDatabase
    private let limits: DocumentLimits
    var indexingPaused = false
    public init(database: MacapyDatabase, limits: DocumentLimits = .init()) { self.database = database; self.limits = limits }
    public func setIndexingPaused(_ paused: Bool) { indexingPaused = paused }

    @discardableResult
    public func importDocument(_ document: ParsedDocument, meetingID: UUID, at date: Date = Date()) throws -> DocumentRecord {
        try Task.checkCancellation()
        guard !indexingPaused else { throw MemoryStoreError.indexingPaused }
        let chunks = try checkedChunks(document)
        return try database.dbWriter.write { db in
            try MemoryStore.requireEligibleMeeting(db, id: meetingID)
            // Repeating the same explicit import attaches the existing content
            // snapshot instead of multiplying identical index entries.
            if let existing = try DocumentRecord.fetchOne(db, sql: "SELECT * FROM documents WHERE textHash=? AND mediaType=? ORDER BY createdAt,id LIMIT 1", arguments: [document.textHash, document.mediaType]) {
                try db.execute(sql: "INSERT OR IGNORE INTO document_links(documentID,meetingID) VALUES(?,?)", arguments: [existing.id, meetingID])
                return existing
            }
            try checkCapacity(db, adding: chunks.count)
            let id = UUID()
            try db.execute(sql: "INSERT INTO documents(id,name,mediaType,snapshotText,textHash,revision,chunkerVersion,createdAt,updatedAt,allowedForAI) VALUES(?,?,?,?,?,1,?,?,?,0)",
                           arguments: [id, document.name, document.mediaType, document.text, document.textHash, DocumentChunker.version, date, date])
            try db.execute(sql: "INSERT INTO document_links(documentID,meetingID) VALUES(?,?)", arguments: [id, meetingID])
            try Self.insertChunks(chunks, documentID: id, revision: 1, in: db)
            return try Self.document(db, id: id)
        }
    }

    @discardableResult
    public func reimport(_ document: ParsedDocument, id: UUID, expectedRevision: Int) throws -> DocumentRecord {
        try Task.checkCancellation()
        guard !indexingPaused else { throw MemoryStoreError.indexingPaused }
        let chunks = try checkedChunks(document)
        try database.purgeMigrationSnapshot()
        return try database.dbWriter.write { db in
            let previous = try Self.document(db, id: id)
            guard previous.revision == expectedRevision else { throw MemoryStoreError.revisionConflict }
            if previous.textHash == document.textHash, previous.mediaType == document.mediaType { return previous }
            let oldCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM document_chunks WHERE documentID=?", arguments: [id]) ?? 0
            try checkCapacity(db, adding: chunks.count - oldCount)
            try db.execute(sql: "DELETE FROM document_chunks WHERE documentID=?", arguments: [id])
            try Task.checkCancellation()
            let revision = previous.revision + 1
            try db.execute(sql: "UPDATE documents SET name=?,mediaType=?,snapshotText=?,textHash=?,revision=?,chunkerVersion=?,updatedAt=? WHERE id=?",
                           arguments: [document.name, document.mediaType, document.text, document.textHash, revision, DocumentChunker.version, Date(), id])
            try Self.insertChunks(chunks, documentID: id, revision: revision, in: db)
            return try Self.document(db, id: id)
        }
    }

    public func documents(meetingID: UUID? = nil) throws -> [DocumentRecord] {
        try database.dbWriter.read { db in
            try DocumentRecord.fetchAll(db, sql: "SELECT d.* FROM documents d" + (meetingID == nil ? "" : " JOIN document_links l ON l.documentID=d.id WHERE l.meetingID=?") + " ORDER BY d.name,d.id",
                                        arguments: StatementArguments(meetingID.map { [$0] } ?? []))
        }
    }

    public func snapshotText(id: UUID) throws -> String {
        try database.dbWriter.read { db in
            guard let text = try String.fetchOne(db, sql: "SELECT snapshotText FROM documents WHERE id=?", arguments: [id]) else { throw MemoryStoreError.notFound }
            return text
        }
    }

    public func attach(id: UUID, to meetingID: UUID) throws {
        try database.dbWriter.write { db in
            try MemoryStore.requireEligibleMeeting(db, id: meetingID)
            _ = try Self.document(db, id: id)
            try db.execute(sql: "INSERT OR IGNORE INTO document_links(documentID,meetingID) VALUES(?,?)", arguments: [id, meetingID])
        }
    }

    public func detach(id: UUID, from meetingID: UUID) throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            // A fact derived from this meeting's attachment loses permission
            // even when another meeting keeps the shared snapshot alive.
            try db.execute(sql: "DELETE FROM memory_facts WHERE meetingID=? AND id IN (SELECT s.factID FROM memory_fact_sources s JOIN document_chunks c ON c.id=s.chunkID WHERE c.documentID=?)", arguments: [meetingID, id])
            try db.execute(sql: "DELETE FROM document_links WHERE documentID=? AND meetingID=?", arguments: [id, meetingID])
        }
    }

    public func remove(id: UUID) throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { try $0.execute(sql: "DELETE FROM documents WHERE id=?", arguments: [id]) }
    }

    public func setAllowedForAI(_ allowed: Bool, id: UUID) throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            _ = try Self.document(db, id: id)
            try db.execute(sql: "UPDATE documents SET allowedForAI=? WHERE id=?", arguments: [allowed, id])
        }
    }

    private func checkedChunks(_ document: ParsedDocument) throws -> [DocumentChunk] {
        guard ["text/plain", "text/markdown", "application/pdf"].contains(document.mediaType),
              !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              document.name.count <= 255 else { throw MemoryStoreError.invalidContent }
        guard document.pages.count <= limits.maximumPages, document.text.count <= limits.maximumCharacters else { throw MemoryStoreError.capacityExceeded }
        let chunks = try DocumentChunker.chunks(document, maximumChunks: limits.maximumChunks)
        guard !chunks.isEmpty else { throw MemoryStoreError.invalidContent }
        return chunks
    }
    private func checkCapacity(_ db: Database, adding count: Int) throws {
        let existing = try Int.fetchOne(db, sql: "SELECT count(*) FROM document_chunks") ?? 0
        guard existing + count <= limits.maximumChunks else { throw MemoryStoreError.capacityExceeded }
    }
    private static func insertChunks(_ chunks: [DocumentChunk], documentID: UUID, revision: Int, in db: Database) throws {
        for chunk in chunks {
            try Task.checkCancellation()
            try db.execute(sql: "INSERT INTO document_chunks(id,documentID,revision,ordinal,pageNumber,startCharacter,endCharacter,text) VALUES(?,?,?,?,?,?,?,?)",
                           arguments: [UUID(), documentID, revision, chunk.ordinal, chunk.pageNumber, chunk.startCharacter, chunk.endCharacter, chunk.text])
        }
    }
    private static func document(_ db: Database, id: UUID) throws -> DocumentRecord {
        guard let row = try DocumentRecord.fetchOne(db, sql: "SELECT * FROM documents WHERE id=?", arguments: [id]) else { throw MemoryStoreError.notFound }
        return row
    }
}
