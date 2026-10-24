import Foundation
import GRDB
import MemoryKit

extension MemoryStore {
    /// Read-only source popover content. The current revision is rechecked;
    /// deleted or changed evidence never falls back to a cached excerpt.
    public func sourcePreview(_ source: SourceReference) throws -> String? {
        try database.dbWriter.read { db in
            guard try Self.sourceIsValid(source, in: db, requireAIConsent: false) else { return nil }
            let text: String
            let offset: Int
            switch source.kind {
            case .segment:
                text = try String.fetchOne(db, sql: "SELECT text FROM segments WHERE id=?", arguments: [source.sourceID]) ?? ""
                offset = 0
            case .artifact:
                text = try ArtifactRecord.fetchOne(db, id: source.sourceID)?.searchText ?? ""
                offset = 0
            case .documentChunk:
                guard let row = try Row.fetchOne(db, sql: "SELECT text,startCharacter FROM document_chunks WHERE id=?", arguments: [source.sourceID]) else { return nil }
                text = row["text"]; offset = row["startCharacter"]
            }
            let start = text.index(text.startIndex, offsetBy: source.startCharacter - offset)
            let end = text.index(text.startIndex, offsetBy: source.endCharacter - offset)
            return String(text[start..<end])
        }
    }

    public func retrieve(_ request: RetrievalRequest) throws -> ContextBundle {
        try Task.checkCancellation()
        guard request.maxExcerpts > 0, request.maxCharacters > 0,
              let pattern = FTS5Pattern(matchingAnyTokenIn: request.query) else { return .init(excerpts: []) }
        return try database.dbWriter.read { db in
            var values: [(any DatabaseValueConvertible)?] = [pattern.rawPattern]
            var factWhere = ["memory_facts_fts MATCH ?", "f.status='approved'",
                             "EXISTS(SELECT 1 FROM memory_meeting_optins o WHERE o.meetingID=f.meetingID)",
                             "NOT EXISTS(SELECT 1 FROM memory_fact_sources s JOIN document_chunks c ON c.id=s.chunkID JOIN documents d ON d.id=c.documentID WHERE s.factID=f.id AND d.allowedForAI=0)"]
            Self.filterSet(request.allowedMeetingIDs, column: "f.meetingID", clauses: &factWhere, values: &values)
            if let documents = request.allowedDocumentIDs {
                if documents.isEmpty {
                    factWhere.append("NOT EXISTS(SELECT 1 FROM memory_fact_sources s WHERE s.factID=f.id AND s.chunkID IS NOT NULL)")
                } else {
                    factWhere.append("NOT EXISTS(SELECT 1 FROM memory_fact_sources s JOIN document_chunks c ON c.id=s.chunkID WHERE s.factID=f.id AND c.documentID NOT IN (\(Self.placeholders(documents.count))))")
                    values += documents.sorted { $0.uuidString < $1.uuidString }.map { $0 }
                }
            }
            if let entityIDs = request.entityIDs {
                if entityIDs.isEmpty { factWhere.append("0") }
                else {
                    factWhere.append("EXISTS(SELECT 1 FROM memory_fact_entities e WHERE e.factID=f.id AND e.entityID IN (\(Self.placeholders(entityIDs.count))))")
                    values += entityIDs.sorted { $0.uuidString < $1.uuidString }.map { $0 }
                }
            }
            if let asOf = request.asOf { factWhere.append("f.statedAt <= ?"); values.append(asOf) }
            let facts = try Row.fetchAll(db, sql: """
                SELECT f.id,bm25(memory_facts_fts) AS rank,m.title FROM memory_facts_fts
                JOIN memory_facts f ON f.rowid=memory_facts_fts.rowid JOIN meetings m ON m.id=f.meetingID
                WHERE \(factWhere.joined(separator: " AND ")) ORDER BY rank,f.statedAt DESC,f.id LIMIT 8
                """, arguments: StatementArguments(values))
            var ranked: [(Double, RetrievedExcerpt)] = []
            for row in facts {
                try Task.checkCancellation()
                guard let fact = try Self.fact(db, id: row["id"]),
                      try Self.factAllowed(fact, request: request, in: db) else { continue }
                ranked.append((row["rank"], .init(citationID: "fact-\(fact.id.uuidString.lowercased())-r\(fact.revision)",
                    title: row["title"], text: fact.text, statedAt: fact.statedAt,
                    factID: fact.id, factRevision: fact.revision, sources: fact.sources)))
            }
            values = [pattern.rawPattern]
            var docWhere = ["document_chunks_fts MATCH ?", "d.allowedForAI=1"]
            Self.filterSet(request.allowedDocumentIDs, column: "d.id", clauses: &docWhere, values: &values)
            var links = ["l.documentID=d.id", "m.ephemeral=0", "m.endedAt IS NOT NULL", "m.status IN ('ended','interrupted')"]
            Self.filterSet(request.allowedMeetingIDs, column: "l.meetingID", clauses: &links, values: &values)
            if let entities = request.entityIDs {
                if entities.isEmpty { links.append("0") }
                else {
                    links.append("EXISTS(SELECT 1 FROM memory_meeting_entities e WHERE e.meetingID=l.meetingID AND e.entityID IN (\(Self.placeholders(entities.count))))")
                    values += entities.sorted { $0.uuidString < $1.uuidString }.map { $0 }
                }
            }
            docWhere.append("EXISTS(SELECT 1 FROM document_links l JOIN meetings m ON m.id=l.meetingID WHERE \(links.joined(separator: " AND ")))")
            if let asOf = request.asOf { docWhere.append("d.updatedAt <= ?"); values.append(asOf) }
            let chunks = try Row.fetchAll(db, sql: """
                SELECT c.*,d.name,d.updatedAt,bm25(document_chunks_fts) AS rank FROM document_chunks_fts
                JOIN document_chunks c ON c.rowid=document_chunks_fts.rowid JOIN documents d ON d.id=c.documentID
                WHERE \(docWhere.joined(separator: " AND ")) ORDER BY rank,d.updatedAt DESC,c.documentID,c.ordinal LIMIT 8
                """, arguments: StatementArguments(values))
            for row in chunks {
                let id: UUID = row["id"], documentID: UUID = row["documentID"], revision: Int = row["revision"]
                ranked.append((row["rank"], .init(citationID: "document-\(id.uuidString.lowercased())-r\(revision)", title: row["name"], text: row["text"], statedAt: row["updatedAt"],
                    sources: [.init(kind: .documentChunk, sourceID: id, revision: revision, documentID: documentID,
                                    pageNumber: row["pageNumber"], startCharacter: row["startCharacter"], endCharacter: row["endCharacter"]) ])))
            }
            ranked.sort { $0.0 == $1.0 ? $0.1.citationID < $1.1.citationID : $0.0 < $1.0 }
            var excerpts: [RetrievedExcerpt] = [], remaining = request.maxCharacters
            for (_, excerpt) in ranked.prefix(request.maxExcerpts) {
                try Task.checkCancellation()
                guard remaining > 0 else { break }
                let text = String(excerpt.text.prefix(remaining))
                remaining -= text.count
                let refs = excerpt.factID == nil ? excerpt.sources.map {
                    SourceReference(kind: $0.kind, sourceID: $0.sourceID, revision: $0.revision, meetingID: $0.meetingID,
                                    documentID: $0.documentID, pageNumber: $0.pageNumber,
                                    startCharacter: $0.startCharacter, endCharacter: min($0.endCharacter, $0.startCharacter + text.count))
                } : excerpt.sources
                excerpts.append(.init(citationID: excerpt.citationID, title: excerpt.title, text: text, statedAt: excerpt.statedAt,
                                      factID: excerpt.factID, factRevision: excerpt.factRevision, sources: refs))
            }
            return .init(excerpts: excerpts)
        }
    }

    public func validate(_ bundle: ContextBundle, for request: RetrievalRequest) throws -> Bool {
        try Task.checkCancellation()
        guard bundle.excerpts.count <= request.maxExcerpts,
              bundle.excerpts.reduce(0, { $0 + $1.text.count }) <= request.maxCharacters else { return false }
        return try database.dbWriter.read { db in
            for excerpt in bundle.excerpts {
                try Task.checkCancellation()
                guard !excerpt.sources.isEmpty else { return false }
                if let factID = excerpt.factID {
                    guard let fact = try Self.fact(db, id: factID), fact.revision == excerpt.factRevision,
                          fact.text.hasPrefix(excerpt.text), fact.sources == excerpt.sources,
                          excerpt.citationID == "fact-\(fact.id.uuidString.lowercased())-r\(fact.revision)",
                          try Self.factAllowed(fact, request: request, in: db) else { return false }
                } else {
                    guard excerpt.sources.count == 1, let ref = excerpt.sources.first, ref.kind == .documentChunk,
                          excerpt.citationID == "document-\(ref.sourceID.uuidString.lowercased())-r\(ref.revision)",
                          try Self.documentAllowed(ref.documentID, request: request, in: db),
                          let row = try Row.fetchOne(db, sql: "SELECT text,startCharacter FROM document_chunks WHERE id=?", arguments: [ref.sourceID]),
                          ref.startCharacter == row["startCharacter"], (row["text"] as String).hasPrefix(excerpt.text) else { return false }
                }
                guard try excerpt.sources.allSatisfy({ try Self.sourceIsValid($0, in: db, requireAIConsent: true) }) else { return false }
            }
            return true
        }
    }

    static func sourceIsValid(_ source: SourceReference, in db: Database, requireAIConsent: Bool) throws -> Bool {
        guard source.startCharacter >= 0, source.endCharacter > source.startCharacter else { return false }
        switch source.kind {
        case .segment:
            guard source.revision == 0, let meetingID = source.meetingID, source.documentID == nil, source.pageNumber == nil,
                  let row = try Row.fetchOne(db, sql: "SELECT text FROM segments WHERE id=? AND meetingID=?", arguments: [source.sourceID, meetingID]) else { return false }
            return source.endCharacter <= (row["text"] as String).count
        case .artifact:
            guard let record = try ArtifactRecord.fetchOne(db, id: source.sourceID), record.meetingID == source.meetingID,
                  record.revision == source.revision, record.artifactStatus != .rejected, source.documentID == nil, source.pageNumber == nil else { return false }
            return source.endCharacter <= record.searchText.count
        case .documentChunk:
            guard let row = try Row.fetchOne(db, sql: "SELECT c.*,d.allowedForAI FROM document_chunks c JOIN documents d ON d.id=c.documentID WHERE c.id=?", arguments: [source.sourceID]),
                  (row["documentID"] as UUID) == source.documentID, (row["revision"] as Int) == source.revision,
                  (row["pageNumber"] as Int?) == source.pageNumber,
                  source.startCharacter >= row["startCharacter"], source.endCharacter <= row["endCharacter"] else { return false }
            if requireAIConsent, !(row["allowedForAI"] as Bool) { return false }
            if let meetingID = source.meetingID {
                return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM document_links WHERE documentID=? AND meetingID=?)", arguments: [source.documentID, meetingID]) == true
            }
            return true
        }
    }

    private static func factAllowed(_ fact: MemoryFact, request: RetrievalRequest, in db: Database) throws -> Bool {
        guard fact.status == .approved, request.allowedMeetingIDs?.contains(fact.meetingID) != false,
              request.asOf.map({ fact.statedAt <= $0 }) != false,
              try fact.sources.allSatisfy({ try sourceIsValid($0, in: db, requireAIConsent: true) }) else { return false }
        if let entities = request.entityIDs, Set(fact.entityIDs).isDisjoint(with: entities) { return false }
        for source in fact.sources where source.kind == .documentChunk {
            guard try documentAllowed(source.documentID, request: request, in: db) else { return false }
        }
        return true
    }

    private static func documentAllowed(_ id: UUID?, request: RetrievalRequest, in db: Database) throws -> Bool {
        guard let id, request.allowedDocumentIDs?.contains(id) != false,
              let row = try Row.fetchOne(db, sql: "SELECT updatedAt,allowedForAI FROM documents WHERE id=?", arguments: [id]), row["allowedForAI"] as Bool else { return false }
        if let asOf = request.asOf, (row["updatedAt"] as Date) > asOf { return false }
        let meetings = try UUID.fetchAll(db, sql: "SELECT l.meetingID FROM document_links l JOIN meetings m ON m.id=l.meetingID WHERE l.documentID=? AND m.ephemeral=0 AND m.endedAt IS NOT NULL AND m.status IN ('ended','interrupted')", arguments: [id])
        for meeting in meetings where request.allowedMeetingIDs?.contains(meeting) != false {
            guard let entities = request.entityIDs else { return true }
            let linked = try UUID.fetchAll(db, sql: "SELECT entityID FROM memory_meeting_entities WHERE meetingID=?", arguments: [meeting])
            if !Set(linked).isDisjoint(with: entities) { return true }
        }
        return false
    }

    private static func filterSet(_ set: Set<UUID>?, column: String, clauses: inout [String], values: inout [(any DatabaseValueConvertible)?]) {
        guard let set else { return }
        guard !set.isEmpty else { clauses.append("0"); return }
        clauses.append("\(column) IN (\(placeholders(set.count)))")
        values += set.sorted { $0.uuidString < $1.uuidString }.map { $0 }
    }
    private static func placeholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ",") }
}
