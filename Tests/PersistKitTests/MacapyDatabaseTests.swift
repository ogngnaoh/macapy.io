import GRDB
import Testing

@testable import PersistKit

/// Check 1: migration v1 round-trips on an in-memory database; all three
/// tables exist with the expected columns.
struct MacapyDatabaseTests {
    @Test func migrationCreatesAllThreeTables() throws {
        let database = try MacapyDatabase.inMemory()
        try database.dbWriter.read { db in
            #expect(try db.tableExists("meetings"))
            #expect(try db.tableExists("segments"))
            #expect(try db.tableExists("settings"))
        }
    }

    @Test func meetingsTableHasExpectedColumns() throws {
        let database = try MacapyDatabase.inMemory()
        let columnNames = try database.dbWriter.read { db in
            try db.columns(in: "meetings").map(\.name)
        }
        #expect(Set(columnNames) == ["id", "title", "startedAt", "endedAt", "status", "ephemeral"])
    }

    @Test func segmentsTableHasExpectedColumns() throws {
        let database = try MacapyDatabase.inMemory()
        let columnNames = try database.dbWriter.read { db in
            try db.columns(in: "segments").map(\.name)
        }
        #expect(Set(columnNames) == ["id", "meetingID", "source", "text", "tStart", "tEnd", "isFinal"])
    }

    @Test func settingsTableHasExpectedColumns() throws {
        let database = try MacapyDatabase.inMemory()
        let columnNames = try database.dbWriter.read { db in
            try db.columns(in: "settings").map(\.name)
        }
        #expect(Set(columnNames) == ["key", "value"])
    }

    @Test func migratingTwiceIsANoOp() throws {
        // Applying the same migrator to an already-migrated database (as
        // `onDisk(at:)` would on every app launch) must not throw or duplicate.
        let database = try MacapyDatabase.inMemory()
        try MacapyDatabase.migrator.migrate(database.dbWriter)
        try database.dbWriter.read { db in
            #expect(try db.tableExists("meetings"))
        }
    }

    @Test func onDiskCreatesContainingDirectoryAndPersistsAcrossReopen() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("nested/macapy.sqlite")

        let database = try MacapyDatabase.onDisk(at: dbURL)
        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        _ = try database.dbWriter.write { db in
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
