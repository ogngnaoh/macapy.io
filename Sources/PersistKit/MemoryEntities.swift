import Foundation
import GRDB
import MemoryKit

extension MemoryStore {
    public func createEntity(kind: MemoryEntityKind, name: String) throws -> MemoryEntity {
        let name = try Self.cleanName(name)
        return try database.dbWriter.write { db in
            guard try Self.entityID(db, name: name, kind: kind) == nil else { throw MemoryStoreError.aliasCollision }
            let id = UUID()
            try db.execute(sql: "INSERT INTO memory_entities(id,kind,name) VALUES(?,?,?)", arguments: [id, kind.rawValue, name])
            try Self.insertAlias(db, name: name, kind: kind, entityID: id)
            return .init(id: id, kind: kind, name: name, aliases: [name])
        }
    }

    public func addAlias(_ name: String, to id: UUID) throws {
        let name = try Self.cleanName(name)
        try database.dbWriter.write { db in
            guard let entity = try Self.entity(db, id: id) else { throw MemoryStoreError.notFound }
            if let existing = try Self.entityID(db, name: name, kind: entity.kind) {
                guard existing == id else { throw MemoryStoreError.aliasCollision }; return
            }
            try Self.insertAlias(db, name: name, kind: entity.kind, entityID: id)
        }
    }

    public func removeAlias(_ name: String, from id: UUID) throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            guard let entity = try Self.entity(db, id: id) else { throw MemoryStoreError.notFound }
            // The canonical name remains a resolvable alias. Rename is a
            // separate explicit operation, never inferred from source text.
            guard Self.normalized(name) != Self.normalized(entity.name) else { throw MemoryStoreError.invalidContent }
            try db.execute(sql: "DELETE FROM memory_aliases WHERE entityID=? AND normalized=?", arguments: [id, Self.normalized(name)])
        }
    }

    public func resolveEntity(_ name: String, kind: MemoryEntityKind) throws -> MemoryEntity? {
        try database.dbWriter.read { db in
            guard let id = try Self.entityID(db, name: name, kind: kind) else { return nil }
            return try Self.entity(db, id: id)
        }
    }

    public func entities(meetingID: UUID? = nil) throws -> [MemoryEntity] {
        try database.dbWriter.read { db in
            let sql = meetingID == nil ? "SELECT id FROM memory_entities ORDER BY name,id"
                : "SELECT e.id FROM memory_entities e JOIN memory_meeting_entities m ON m.entityID=e.id WHERE m.meetingID=? ORDER BY e.name,e.id"
            let ids = try UUID.fetchAll(db, sql: sql, arguments: StatementArguments(meetingID.map { [$0] } ?? []))
            return try ids.compactMap { try Self.entity(db, id: $0) }
        }
    }

    public func linkEntity(_ entityID: UUID, to meetingID: UUID) throws {
        try database.dbWriter.write { db in
            try Self.requireEligibleMeeting(db, id: meetingID)
            guard try Self.entity(db, id: entityID) != nil else { throw MemoryStoreError.notFound }
            try db.execute(sql: "INSERT OR IGNORE INTO memory_meeting_entities(meetingID,entityID) VALUES(?,?)", arguments: [meetingID, entityID])
        }
    }

    public func unlinkEntity(_ entityID: UUID, from meetingID: UUID) throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM memory_fact_entities WHERE entityID=? AND factID IN (SELECT id FROM memory_facts WHERE meetingID=?)", arguments: [entityID, meetingID])
            try db.execute(sql: "DELETE FROM memory_meeting_entities WHERE meetingID=? AND entityID=?", arguments: [meetingID, entityID])
        }
    }

    /// Only a direct user selection may merge identity. Aliases are transferred
    /// transactionally; source facts retain their original provenance.
    public func mergeEntity(_ sourceID: UUID, into targetID: UUID) throws {
        guard sourceID != targetID else { return }
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            guard let source = try Self.entity(db, id: sourceID), let target = try Self.entity(db, id: targetID) else { throw MemoryStoreError.notFound }
            guard source.kind == target.kind else { throw MemoryStoreError.incompatibleEntity }
            try db.execute(sql: "UPDATE memory_aliases SET entityID=? WHERE entityID=?", arguments: [targetID, sourceID])
            try db.execute(sql: "INSERT OR IGNORE INTO memory_meeting_entities(meetingID,entityID) SELECT meetingID,? FROM memory_meeting_entities WHERE entityID=?", arguments: [targetID, sourceID])
            try db.execute(sql: "INSERT OR IGNORE INTO memory_fact_entities(factID,entityID) SELECT factID,? FROM memory_fact_entities WHERE entityID=?", arguments: [targetID, sourceID])
            try db.execute(sql: "DELETE FROM memory_entities WHERE id=?", arguments: [sourceID])
        }
    }

    public func deleteEntity(id: UUID) throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { try $0.execute(sql: "DELETE FROM memory_entities WHERE id=?", arguments: [id]) }
    }

    private static func cleanName(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { throw MemoryStoreError.invalidContent }
        return value
    }
    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func entityID(_ db: Database, name: String, kind: MemoryEntityKind) throws -> UUID? {
        try UUID.fetchOne(db, sql: "SELECT entityID FROM memory_aliases WHERE kind=? AND normalized=?", arguments: [kind.rawValue, normalized(name)])
    }
    private static func insertAlias(_ db: Database, name: String, kind: MemoryEntityKind, entityID: UUID) throws {
        try db.execute(sql: "INSERT INTO memory_aliases(id,entityID,kind,name,normalized) VALUES(?,?,?,?,?)", arguments: [UUID(), entityID, kind.rawValue, name, normalized(name)])
    }
    private static func entity(_ db: Database, id: UUID) throws -> MemoryEntity? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_entities WHERE id=?", arguments: [id]), let kind = MemoryEntityKind(rawValue: row["kind"]) else { return nil }
        return try .init(id: id, kind: kind, name: row["name"], aliases: String.fetchAll(db, sql: "SELECT name FROM memory_aliases WHERE entityID=? ORDER BY name", arguments: [id]))
    }
}
