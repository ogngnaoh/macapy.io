import ActionKit
import CryptoKit
import Foundation
import GRDB
import MemoryKit

public struct BriefPreferences: Sendable, Equatable {
    public let enabled: Bool
    public let selectedCalendarIDs: Set<String>
    public let automaticAIEnabled: Bool
    public init(enabled: Bool = false, selectedCalendarIDs: Set<String> = [], automaticAIEnabled: Bool = false) {
        self.enabled = enabled; self.selectedCalendarIDs = selectedCalendarIDs
        self.automaticAIEnabled = enabled && automaticAIEnabled
    }
}

public struct BriefEvent: Sendable, Identifiable, Equatable {
    public let event: CalendarEventSnapshot
    public let entityIDs: Set<UUID>
    public let mappingRevision: Int
    public var id: String { event.id }
}

public struct BriefSnapshot: Sendable, Codable, Equatable, Identifiable {
    public enum Mode: String, Sendable, Codable { case local, ai }
    public let event: CalendarEventSnapshot
    public let mappingRevision: Int
    public let context: ContextBundle
    public let text: String
    public let citationIDs: [String]
    public let mode: Mode
    public let generatedAt: Date
    public var id: String { event.id }
    public var expiresAt: Date { event.endDate.addingTimeInterval(86_400) }
    /// Used as a job revision, never as a provider-created identity.
    public var generationRevision: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(context)) ?? Data()
        return SHA256.hash(data: Data("\(event.revision):\(mappingRevision):".utf8) + data)
            .map { String(format: "%02x", $0) }.joined()
    }
    public init(event: CalendarEventSnapshot, mappingRevision: Int, context: ContextBundle, text: String,
                citationIDs: [String], mode: Mode, generatedAt: Date = Date()) {
        self.event = event; self.mappingRevision = mappingRevision; self.context = context
        self.text = text; self.citationIDs = citationIDs; self.mode = mode; self.generatedAt = generatedAt
    }
}

public enum BriefStoreError: Error, Sendable, Equatable { case disabled, staleEvent, staleSources, invalidContent }

/// Event-owned storage. No synthetic meetings and no calendar read side effect.
public actor BriefStore {
    private let database: MacapyDatabase
    public init(database: MacapyDatabase) { self.database = database }

    public func preferences() throws -> BriefPreferences {
        try database.dbWriter.read { db in try Self.preferences(in: db) }
    }

    public func configure(_ preferences: BriefPreferences) throws {
        guard preferences.selectedCalendarIDs.count <= 100,
              preferences.selectedCalendarIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096 }) else { throw BriefStoreError.invalidContent }
        try database.purgeMigrationSnapshot()
        let selected = try JSONEncoder().encode(preferences.selectedCalendarIDs.sorted())
        try database.dbWriter.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO brief_preferences(id,enabled,selectedCalendars,automaticAIEnabled) VALUES(1,?,?,?)",
                           arguments: [preferences.enabled, selected, preferences.automaticAIEnabled])
            if !preferences.enabled { try db.execute(sql: "DELETE FROM brief_events") }
            else {
                let rows = try Row.fetchAll(db, sql: "SELECT id,calendarID FROM brief_events")
                for row in rows where !preferences.selectedCalendarIDs.contains(row["calendarID"] as String) {
                    try db.execute(sql: "DELETE FROM brief_events WHERE id=?", arguments: [row["id"] as String])
                }
            }
        }
    }

    /// Permission revocation clears calendar-derived content and mappings.
    /// Preferences stay opt-in so the UI can explain the revoked permission.
    public func clearCalendarContent() throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in try db.execute(sql: "DELETE FROM brief_events") }
    }

    public func synchronize(_ read: UpcomingCalendarEvents, now: Date = Date()) throws {
        if read.state == .readAccessRequired { try clearCalendarContent(); return }
        guard read.state == .ready else { return }
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            let preferences = try Self.preferences(in: db)
            guard preferences.enabled else { throw BriefStoreError.disabled }
            try db.execute(sql: "DELETE FROM brief_events WHERE expiresAt <= ?", arguments: [now])
            for id in read.unavailableCalendarIDs {
                try db.execute(sql: "DELETE FROM brief_events WHERE calendarID=?", arguments: [id])
            }
            let incoming = read.events.filter { preferences.selectedCalendarIDs.contains($0.calendarID) }
            for event in incoming {
                guard event.endDate > read.windowStart, event.startDate < read.windowEnd else { continue }
                let snapshot = try JSONEncoder().encode(event)
                let old = try String.fetchOne(db, sql: "SELECT revision FROM brief_events WHERE id=?", arguments: [event.id])
                if old != nil && old != event.revision {
                    try db.execute(sql: "DELETE FROM brief_snapshots WHERE eventID=?", arguments: [event.id])
                }
                try db.execute(sql: """
                    INSERT INTO brief_events(id,calendarID,revision,snapshot,startsAt,expiresAt) VALUES(?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET calendarID=excluded.calendarID,revision=excluded.revision,
                        snapshot=excluded.snapshot,startsAt=excluded.startsAt,expiresAt=excluded.expiresAt
                    """, arguments: [event.id,event.calendarID,event.revision,snapshot,event.startDate,event.endDate.addingTimeInterval(86_400)])
            }
            if read.isAuthoritative {
                let ids = Set(incoming.map(\.id))
                let previous = try String.fetchAll(db, sql: "SELECT id FROM brief_events WHERE startsAt >= ? AND startsAt < ?",
                                                   arguments: [read.windowStart,read.windowEnd])
                for id in previous where !ids.contains(id) {
                    try db.execute(sql: "DELETE FROM brief_events WHERE id=?", arguments: [id])
                }
            }
        }
    }

    public func events(now: Date = Date()) throws -> [BriefEvent] {
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM brief_events WHERE expiresAt <= ?", arguments: [now])
            return try Row.fetchAll(db, sql: "SELECT * FROM brief_events ORDER BY startsAt,id").map { try Self.event($0, in: db) }
        }
    }

    public func setMapping(eventID: String, expectedEventRevision: String, entityIDs: Set<UUID>) throws {
        guard entityIDs.count <= 32 else { throw BriefStoreError.invalidContent }
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            guard try String.fetchOne(db, sql: "SELECT revision FROM brief_events WHERE id=?", arguments: [eventID]) == expectedEventRevision else {
                throw BriefStoreError.staleEvent
            }
            for id in entityIDs {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_entities WHERE id=?)", arguments: [id]) == true else {
                    throw BriefStoreError.staleSources
                }
            }
            let previous = Set(try UUID.fetchAll(db, sql: "SELECT entityID FROM brief_entity_links WHERE eventID=?", arguments: [eventID]))
            guard previous != entityIDs else { return }
            try db.execute(sql: "DELETE FROM brief_entity_links WHERE eventID=?", arguments: [eventID])
            for id in entityIDs {
                try db.execute(sql: "INSERT INTO brief_entity_links(eventID,entityID) VALUES(?,?)", arguments: [eventID,id])
            }
        }
    }

    public func save(_ snapshot: BriefSnapshot, now: Date = Date()) throws {
        guard snapshot.text.count <= 8_000, snapshot.context.excerpts.count <= 8,
              snapshot.context.excerpts.reduce(0, { $0 + $1.text.count }) <= 8_000,
              snapshot.context.containsOnlyValidCitations(snapshot.citationIDs),
              snapshot.mode == .local || (!snapshot.text.isEmpty && !snapshot.citationIDs.isEmpty),
              snapshot.generatedAt <= now.addingTimeInterval(60), snapshot.expiresAt > now else { throw BriefStoreError.invalidContent }
        let data = try JSONEncoder().encode(snapshot)
        try database.dbWriter.write { db in
            guard try Self.preferences(in: db).enabled,
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM brief_events WHERE id=?", arguments: [snapshot.id]),
                  (row["revision"] as String) == snapshot.event.revision,
                  (row["mappingRevision"] as Int) == snapshot.mappingRevision else { throw BriefStoreError.staleEvent }
            let event = try Self.event(row, in: db)
            for excerpt in snapshot.context.excerpts {
                guard !excerpt.sources.isEmpty,
                      try excerpt.sources.allSatisfy({ try MemoryStore.sourceIsValid($0, in: db, requireAIConsent: true) }) else {
                    throw BriefStoreError.staleSources
                }
                if let factID = excerpt.factID {
                    guard let fact = try MemoryStore.fact(db, id: factID), fact.status == .approved,
                          fact.revision == excerpt.factRevision, fact.text.hasPrefix(excerpt.text), fact.sources == excerpt.sources,
                          excerpt.citationID == "fact-\(fact.id.uuidString.lowercased())-r\(fact.revision)",
                          !Set(fact.entityIDs).isDisjoint(with: event.entityIDs) else { throw BriefStoreError.staleSources }
                } else {
                    guard excerpt.sources.count == 1, let ref = excerpt.sources.first, ref.kind == .documentChunk,
                          excerpt.citationID == "document-\(ref.sourceID.uuidString.lowercased())-r\(ref.revision)",
                          let text = try String.fetchOne(db, sql: "SELECT text FROM document_chunks WHERE id=?", arguments: [ref.sourceID]),
                          text.hasPrefix(excerpt.text) else { throw BriefStoreError.staleSources }
                    let linked = try UUID.fetchAll(db, sql: """
                        SELECT e.entityID FROM memory_meeting_entities e JOIN document_links l ON l.meetingID=e.meetingID
                        WHERE l.documentID=?
                        """, arguments: [ref.documentID])
                    guard !Set(linked).isDisjoint(with: event.entityIDs) else { throw BriefStoreError.staleSources }
                }
            }
            try db.execute(sql: "INSERT OR REPLACE INTO brief_snapshots(eventID,eventRevision,mappingRevision,snapshot) VALUES(?,?,?,?)",
                           arguments: [snapshot.id,snapshot.event.revision,snapshot.mappingRevision,data])
        }
    }

    public func snapshot(eventID: String, now: Date = Date()) throws -> BriefSnapshot? {
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM brief_events WHERE expiresAt <= ?", arguments: [now])
            guard let data = try Data.fetchOne(db, sql: "SELECT snapshot FROM brief_snapshots WHERE eventID=?", arguments: [eventID]) else { return nil }
            return try JSONDecoder().decode(BriefSnapshot.self, from: data)
        }
    }

    public func isCurrent(eventID: String, eventRevision: String, mappingRevision: Int) throws -> Bool {
        try database.dbWriter.read { db in
            guard try Self.preferences(in: db).enabled,
                  let row = try Row.fetchOne(db, sql: "SELECT revision,mappingRevision FROM brief_events WHERE id=?", arguments: [eventID]) else { return false }
            return (row["revision"] as String) == eventRevision && (row["mappingRevision"] as Int) == mappingRevision
        }
    }

    private static func preferences(in db: Database) throws -> BriefPreferences {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM brief_preferences WHERE id=1") else { return .init() }
        return .init(enabled: row["enabled"], selectedCalendarIDs: Set(try JSONDecoder().decode([String].self, from: row["selectedCalendars"])),
                     automaticAIEnabled: row["automaticAIEnabled"])
    }

    private static func event(_ row: Row, in db: Database) throws -> BriefEvent {
        let event = try JSONDecoder().decode(CalendarEventSnapshot.self, from: row["snapshot"])
        let entities = try UUID.fetchAll(db, sql: "SELECT entityID FROM brief_entity_links WHERE eventID=?", arguments: [event.id])
        return .init(event: event, entityIDs: Set(entities), mappingRevision: row["mappingRevision"])
    }
}
