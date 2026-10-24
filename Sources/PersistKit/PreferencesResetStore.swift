import GRDB

public enum PreferencesResetError: Error, Equatable, Sendable {
    case contentRemains
}

/// The explicit second privacy action. Ordinary content deletion deliberately
/// retains these settings and conservative anonymous spending counters.
public actor PreferencesResetStore {
    private let database: MacapyDatabase
    public init(database: MacapyDatabase) { self.database = database }

    public func requireNoContent() throws {
        try database.dbWriter.read { try Self.requireNoContent(in: $0) }
    }

    public func reset() throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            // Recheck inside the clearing transaction: a prior UI check cannot
            // authorize erasing counters after another writer adds content.
            try Self.requireNoContent(in: db)
            try db.execute(sql: """
                DELETE FROM settings;
                DELETE FROM brief_preferences;
                DELETE FROM spend_ledger;
                DELETE FROM usage_attempts;
                DELETE FROM usage_budget_aggregates;
                DELETE FROM usage_budget_clock;
                """)
            // Preserve the user's explicit removal of personal identity even
            // across reset/relaunch; setup may ask for a name again.
            try SettingsStore.clearPersonalName(in: db)
        }
        try database.dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            try db.checkpoint(.truncate)
        }
    }

    private static func requireNoContent(in db: Database) throws {
        for table in ["meetings", "memory_entities", "documents", "brief_events", "action_journal"] {
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table))") == false
            else { throw PreferencesResetError.contentRemains }
        }
    }
}
