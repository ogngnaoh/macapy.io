import Foundation
import GRDB

@testable import PersistKit

/// Whole-database row dump for row-diff oracles (promoted from
/// ArtifactStoreTests in slice 5 — the deletion checks needed it too).
/// Excludes the FTS5 virtual tables and their shadow tables (`*_fts*`):
/// their internals are index bytes, not user data — FTS state is asserted
/// through search results and targeted `_docsize` counts instead.
enum DatabaseDump {
    /// Every row of every user table, as `table → primary key → column →
    /// value`. Blobs (GRDB stores `UUID` as 16 raw bytes) render as hex so
    /// keys are unique and the row-diff assertion reads as data.
    static func dump(_ database: MacapyDatabase) throws -> [String: [String: [String: String]]] {
        try database.dbWriter.read { db in
            let tables = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                    """
            ).filter { !$0.contains("_fts") }
            var dump: [String: [String: [String: String]]] = [:]
            for table in tables {
                var rows: [String: [String: String]] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT * FROM \(table)") {
                    var columns: [String: String] = [:]
                    for (column, value) in row {
                        columns[column] = describe(value.databaseValue)
                    }
                    let key = columns["id"] ?? columns["key"] ?? String(describing: row)
                    rows[key] = columns
                }
                dump[table] = rows
            }
            return dump
        }
    }

    /// The dump key for a row GRDB wrote with this UUID id.
    static func key(for id: UUID) -> String {
        describe(id.databaseValue)
    }

    static func describe(_ value: DatabaseValue) -> String {
        if case .blob(let data) = value.storage {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        return String(describing: value)
    }
}
