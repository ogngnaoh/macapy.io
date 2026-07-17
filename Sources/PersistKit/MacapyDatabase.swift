import Foundation
import GRDB

/// Wraps one GRDB database connection. Two factories: an on-disk `DatabasePool`
/// (WAL mode, production path `~/Library/Application Support/macapy/macapy.sqlite`)
/// and an in-memory `DatabaseQueue`. Ephemeral meetings and **every PersistKit
/// test** use `.inMemory()` — the identical write path as production, which is
/// what makes ephemeral mode nearly free and trustworthy: zero disk rows by
/// construction (slice-04 doc decision 2).
public struct MacapyDatabase: Sendable {
    public let dbWriter: any DatabaseWriter

    init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// WAL-mode on-disk database at `url`, migrated to schema v1. Creates the
    /// containing directory if it doesn't exist yet (SPEC §5: production path
    /// is `~/Library/Application Support/macapy/`).
    public static func onDisk(at url: URL) throws -> MacapyDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: url.path)
        try migrator.migrate(pool)
        return MacapyDatabase(dbWriter: pool)
    }

    /// A private in-memory database, migrated to schema v1. Used by ephemeral
    /// meetings (a fresh instance per meeting) and by this target's tests.
    public static func inMemory() throws -> MacapyDatabase {
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        return MacapyDatabase(dbWriter: queue)
    }

    /// Schema v1 (SPEC §6.2): `meetings`, `segments` (FK cascade to
    /// `meetings`), `settings`. Additive per milestone (SPEC §9); forward-only.
    /// Column names are camelCase to match the Swift record types 1:1 (a
    /// deviation from SPEC's snake_case sketch — see slice-04 doc Notes).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meetings") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("title", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("status", .text).notNull()
                t.column("ephemeral", .boolean).notNull()
            }
            try db.create(table: "segments") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("meetingID", .text).notNull()
                    .indexed()
                    .references("meetings", onDelete: .cascade)
                t.column("source", .text).notNull()
                t.column("text", .text).notNull()
                t.column("tStart", .double).notNull()
                t.column("tEnd", .double).notNull()
                t.column("isFinal", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "settings") { t in
                t.column("key", .text).notNull().primaryKey()
                t.column("value", .text)
            }
        }
        return migrator
    }
}
