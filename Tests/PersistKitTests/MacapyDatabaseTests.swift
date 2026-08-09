import Foundation
import GRDB
import Testing

@testable import PersistKit

/// Check 1: migration v1 round-trips on an in-memory database; all three
/// tables exist with the expected columns.
struct MacapyDatabaseTests {
    @Test func migrationCreatesAllThreeTables() throws {
        let database = try MacapyDatabase.inMemory()
        let exists = try database.dbWriter.read { db in
            (
                try db.tableExists("meetings"),
                try db.tableExists("segments"),
                try db.tableExists("settings")
            )
        }
        #expect(exists.0)
        #expect(exists.1)
        #expect(exists.2)
    }

    @Test func meetingsTableHasExpectedColumns() throws {
        let database = try MacapyDatabase.inMemory()
        let columnNames = try database.dbWriter.read { db in
            try db.columns(in: "meetings").map(\.name)
        }
        #expect(Set(columnNames) == ["id", "title", "startedAt", "endedAt", "status", "ephemeral"])
    }

    @Test func segmentsTableHasExpectedColumns() throws {
        // `speakerId` joined the exact set in v4 (slice 4) — the disclosed,
        // by-design extension of this pin.
        let database = try MacapyDatabase.inMemory()
        let columnNames = try database.dbWriter.read { db in
            try db.columns(in: "segments").map(\.name)
        }
        #expect(Set(columnNames) == ["id", "meetingID", "source", "text", "tStart", "tEnd", "isFinal", "speakerId"])
    }

    @Test func speakersTableHasExpectedColumns() throws {
        let database = try MacapyDatabase.inMemory()
        let columnNames = try database.dbWriter.read { db in
            try db.columns(in: "speakers").map(\.name)
        }
        #expect(Set(columnNames) == ["id", "meetingID", "label", "embedding"])
    }

    @Test func settingsTableHasExpectedColumns() throws {
        let database = try MacapyDatabase.inMemory()
        let columnNames = try database.dbWriter.read { db in
            try db.columns(in: "settings").map(\.name)
        }
        #expect(Set(columnNames) == ["key", "value"])
    }

    @Test func artifactsTableHasExpectedColumns() throws {
        // `searchText` joined the exact set in v5 (slice 5) — the disclosed,
        // by-design extension of this pin.
        let database = try MacapyDatabase.inMemory()
        let columnNames = try database.dbWriter.read { db in
            try db.columns(in: "artifacts").map(\.name)
        }
        #expect(Set(columnNames) == ["id", "meetingID", "kind", "payload", "status", "createdAt", "searchText"])
    }

    // MARK: - v5-search (slice 5, check 1)

    @Test func v5CreatesThreeFTSTablesAndStartedAtIndex() throws {
        let database = try MacapyDatabase.inMemory()
        let (fts, indexed) = try database.dbWriter.read { db in
            (
                (
                    try db.tableExists("meetings_fts"),
                    try db.tableExists("segments_fts"),
                    try db.tableExists("artifacts_fts")
                ),
                try db.indexes(on: "meetings").contains { $0.columns == ["startedAt"] }
            )
        }
        #expect(fts.0)
        #expect(fts.1)
        #expect(fts.2)
        #expect(indexed)
    }

    /// A v4 database with pre-existing rows — title, segments, and legacy
    /// artifacts of every kind (no `searchText` column yet) — migrates to v5
    /// with every pre-existing row searchable and `searchText` backfilled
    /// per kind by `ArtifactSearchText.derive`.
    @Test func v4DatabaseMigratesWithEveryPreExistingRowSearchable() throws {
        let queue = try DatabaseQueue()
        try MacapyDatabase.migrator.migrate(queue, upTo: "v4-speakers")
        let meetingID = UUID()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meetings (id, title, startedAt, endedAt, status, ephemeral)
                    VALUES (?, 'Quarterly roadmap sync', '2026-08-01 10:00:00', NULL, 'ended', 0)
                    """,
                arguments: [meetingID])
            try db.execute(
                sql: """
                    INSERT INTO segments (id, meetingID, source, text, tStart, tEnd, isFinal)
                    VALUES (?, ?, 'them', 'the flux capacitor shipped early', 0.0, 2.0, 1)
                    """,
                arguments: [UUID(), meetingID])
            for (kind, payload) in [
                ("summary", #"{"text":"we shipped the capacitor"}"#),
                ("decision", #"{"text":"freeze the API surface"}"#),
                ("action_item", #"{"title":"write the runbook","owner":"Dana","deadline":"Friday"}"#),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO artifacts (id, meetingID, kind, payload, status, createdAt)
                        VALUES (?, ?, ?, ?, 'draft', '2026-08-01 11:00:00')
                        """,
                    arguments: [UUID(), meetingID, kind, payload])
            }
        }

        try MacapyDatabase.migrator.migrate(queue)

        let (titleHits, segmentHits, artifactHits, searchTexts) = try queue.read { db in
            (
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM meetings_fts WHERE meetings_fts MATCH 'roadmap'") ?? 0,
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM segments_fts WHERE segments_fts MATCH 'capacitor'") ?? 0,
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT count(*) FROM artifacts_fts
                        WHERE artifacts_fts MATCH ?
                        """,
                    arguments: ["capacitor OR freeze OR runbook OR Dana OR Friday"]) ?? 0,
                try String.fetchAll(db, sql: "SELECT searchText FROM artifacts ORDER BY kind")
            )
        }
        #expect(titleHits == 1)
        #expect(segmentHits == 1)
        #expect(artifactHits == 3)
        #expect(searchTexts == [
            "write the runbook Dana Friday",
            "freeze the API surface",
            "we shipped the capacitor",
        ])
    }

    @Test func migratingTwiceIsANoOp() throws {
        // Applying the same migrator to an already-migrated database (as
        // `onDisk(at:)` would on every app launch) must not throw or duplicate.
        let database = try MacapyDatabase.inMemory()
        try MacapyDatabase.migrator.migrate(database.dbWriter)
        let exists = try database.dbWriter.read { db in
            try db.tableExists("meetings")
        }
        #expect(exists)
    }

    @Test func onDiskCreatesContainingDirectoryAndPersistsAcrossReopen() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("nested/macapy.sqlite")

        let database = try MacapyDatabase.onDisk(at: dbURL)
        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        try database.dbWriter.write { db in
            try MeetingStoreTestHelpers.insertProbeMeeting(db)
        }

        // Reopening the same file must see the same schema + row (proves the
        // migrator is idempotent against a pre-existing on-disk database).
        let reopened = try MacapyDatabase.onDisk(at: dbURL)
        let count = try reopened.dbWriter.read { db in
            try MeetingRecord.fetchCount(db)
        }
        #expect(count == 1)
    }
}

/// Shared helper so multiple test files can seed a minimal, valid `meetings`
/// row without duplicating `MeetingRecord` construction.
enum MeetingStoreTestHelpers {
    static func insertProbeMeeting(_ db: Database) throws {
        let record = MeetingRecord(
            id: UUID(), title: "Probe", startedAt: Date(), endedAt: nil,
            status: MeetingRecord.activeStatus, ephemeral: false
        )
        try record.insert(db)
    }
}
