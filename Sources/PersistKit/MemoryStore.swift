import Foundation
import GRDB
import MemoryKit

public actor MemoryStore: ContextRetrieving {
    let database: MacapyDatabase
    public init(database: MacapyDatabase) { self.database = database }

    public func setOptIn(_ enabled: Bool, meetingID: UUID) throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            try Self.requireEligibleMeeting(db, id: meetingID)
            if enabled {
                try db.execute(sql: "INSERT OR IGNORE INTO memory_meeting_optins(meetingID) VALUES(?)", arguments: [meetingID])
            } else {
                try db.execute(sql: "DELETE FROM memory_meeting_optins WHERE meetingID = ?", arguments: [meetingID])
            }
        }
    }

    public func isOptedIn(meetingID: UUID) throws -> Bool {
        try database.dbWriter.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_meeting_optins WHERE meetingID = ?)", arguments: [meetingID]) ?? false
        }
    }

    @discardableResult
    public func insertCandidates(_ candidates: [MemoryCandidate], meetingID: UUID) throws -> [MemoryFact] {
        try Task.checkCancellation()
        guard candidates.count <= 100 else { throw MemoryStoreError.capacityExceeded }
        return try database.dbWriter.write { db in
            try Self.requireEligibleMeeting(db, id: meetingID)
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_meeting_optins WHERE meetingID=?)", arguments: [meetingID]) == true else {
                throw MemoryStoreError.notOptedIn
            }
            var ids: [UUID] = []
            let meeting = try MeetingRecord.fetchOne(db, id: meetingID)!
            for candidate in candidates {
                try Task.checkCancellation()
                let text = try Self.cleanText(candidate.text)
                guard candidate.statedAt >= meeting.startedAt,
                      candidate.statedAt <= meeting.endedAt! else { throw MemoryStoreError.invalidContent }
                guard !candidate.sources.isEmpty, candidate.sources.count <= 8, candidate.entityIDs.count <= 32 else { throw MemoryStoreError.invalidSource }
                for source in candidate.sources {
                    guard source.meetingID == meetingID,
                          try Self.sourceIsValid(source, in: db, requireAIConsent: false) else { throw MemoryStoreError.invalidSource }
                }
                let id = UUID(); ids.append(id)
                try db.execute(sql: "INSERT INTO memory_facts(id,meetingID,kind,text,status,statedAt,createdAt) VALUES(?,?,?,?,?,?,?)",
                               arguments: [id, meetingID, candidate.kind.rawValue, text, "pending", candidate.statedAt, Date()])
                for source in candidate.sources {
                    try db.execute(sql: "INSERT INTO memory_fact_sources(id,factID,segmentID,artifactID,chunkID,referenceJSON) VALUES(?,?,?,?,?,?)",
                                   arguments: [UUID(), id, source.kind == .segment ? source.sourceID : nil,
                                               source.kind == .artifact ? source.sourceID : nil,
                                               source.kind == .documentChunk ? source.sourceID : nil,
                                               String(decoding: try JSONEncoder().encode(source), as: UTF8.self)])
                }
                for entityID in Set(candidate.entityIDs) {
                    guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_meeting_entities WHERE meetingID=? AND entityID=?)", arguments: [meetingID, entityID]) == true else {
                        throw MemoryStoreError.invalidSource
                    }
                    try db.execute(sql: "INSERT INTO memory_fact_entities(factID,entityID) VALUES(?,?)", arguments: [id, entityID])
                }
            }
            return try ids.compactMap { try Self.fact(db, id: $0) }
        }
    }

    public func facts(meetingID: UUID? = nil) throws -> [MemoryFact] {
        try database.dbWriter.read { db in
            let ids = try UUID.fetchAll(db, sql: "SELECT id FROM memory_facts" + (meetingID == nil ? "" : " WHERE meetingID=?") + " ORDER BY statedAt DESC,rowid",
                                       arguments: StatementArguments(meetingID.map { [$0] } ?? []))
            return try ids.compactMap { try Self.fact(db, id: $0) }
        }
    }

    public func review(id: UUID, expectedRevision: Int, status: MemoryReviewStatus) throws {
        guard status == .approved || status == .rejected else { throw MemoryStoreError.invalidContent }
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            let fact = try Self.checkedFact(db, id: id, revision: expectedRevision)
            guard fact.status != .superseded else { throw MemoryStoreError.invalidContent }
            guard try fact.sources.allSatisfy({ try Self.sourceIsValid($0, in: db, requireAIConsent: false) }) else { throw MemoryStoreError.invalidSource }
            try db.execute(sql: "UPDATE memory_facts SET status=? WHERE id=?", arguments: [status.rawValue, id])
        }
    }

    @discardableResult
    public func edit(id: UUID, expectedRevision: Int, text: String) throws -> MemoryFact {
        let text = try Self.cleanText(text)
        try database.purgeMigrationSnapshot()
        return try database.dbWriter.write { db in
            let fact = try Self.checkedFact(db, id: id, revision: expectedRevision)
            guard fact.status != .superseded else { throw MemoryStoreError.invalidContent }
            try db.execute(sql: "UPDATE memory_facts SET text=?,status='pending',revision=revision+1,editedAt=? WHERE id=?", arguments: [text, Date(), id])
            return try Self.fact(db, id: id)!
        }
    }

    public func supersede(id: UUID, expectedRevision: Int) throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            _ = try Self.checkedFact(db, id: id, revision: expectedRevision)
            try db.execute(sql: "UPDATE memory_facts SET status='superseded',revision=revision+1 WHERE id=?", arguments: [id])
        }
    }

    public func deleteFact(id: UUID) throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { try $0.execute(sql: "DELETE FROM memory_facts WHERE id=?", arguments: [id]) }
    }

    public func setCompletion(_ complete: Bool, id: UUID, expectedRevision: Int) throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            let fact = try Self.checkedFact(db, id: id, revision: expectedRevision)
            guard fact.kind == .commitment else { throw MemoryStoreError.invalidContent }
            try db.execute(sql: "UPDATE memory_facts SET completedAt=?,revision=revision+1 WHERE id=?", arguments: [complete ? Date() : nil, id])
        }
    }

    static func requireEligibleMeeting(_ db: Database, id: UUID) throws {
        guard let meeting = try MeetingRecord.fetchOne(db, id: id), meeting.hasEnded,
              meeting.endedAt != nil, !meeting.ephemeral else { throw MemoryStoreError.ineligibleMeeting }
    }

    static func cleanText(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 8_000 else { throw MemoryStoreError.invalidContent }
        return text
    }

    static func checkedFact(_ db: Database, id: UUID, revision: Int) throws -> MemoryFact {
        guard let fact = try fact(db, id: id) else { throw MemoryStoreError.notFound }
        guard fact.revision == revision else { throw MemoryStoreError.revisionConflict }
        return fact
    }

    static func fact(_ db: Database, id: UUID) throws -> MemoryFact? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_facts WHERE id=?", arguments: [id]),
              let kind = MemoryFactKind(rawValue: row["kind"]), let status = MemoryReviewStatus(rawValue: row["status"]) else { return nil }
        let sources = try String.fetchAll(db, sql: "SELECT referenceJSON FROM memory_fact_sources WHERE factID=? ORDER BY rowid", arguments: [id])
            .map { try JSONDecoder().decode(SourceReference.self, from: Data($0.utf8)) }
        let entities = try UUID.fetchAll(db, sql: "SELECT entityID FROM memory_fact_entities WHERE factID=? ORDER BY entityID", arguments: [id])
        let meetingID: UUID = row["meetingID"], text: String = row["text"], revision: Int = row["revision"]
        let statedAt: Date = row["statedAt"], editedAt: Date? = row["editedAt"], completedAt: Date? = row["completedAt"]
        return .init(id: id, meetingID: meetingID, kind: kind, text: text, status: status,
                     revision: revision, statedAt: statedAt, editedAt: editedAt, completedAt: completedAt,
                     sources: sources, entityIDs: entities)
    }
}
