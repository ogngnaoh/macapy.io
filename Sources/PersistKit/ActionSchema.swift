import GRDB

/// Composition-owned v8 migration. The journal is content and cascades with
/// its source artifact/meeting; it never removes items already in EventKit.
enum ActionSchema {
    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE action_journal (
                operationID BLOB PRIMARY KEY NOT NULL,
                artifactID BLOB NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
                artifactRevision INTEGER NOT NULL,
                kind TEXT NOT NULL,
                targetID TEXT NOT NULL,
                intentHash TEXT NOT NULL,
                reviewJSON BLOB NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('prepared','dispatching','created','failed','needsReconciliation')),
                externalIdentifier TEXT,
                failureCode TEXT,
                preparedAt DATETIME NOT NULL,
                dispatchedAt DATETIME,
                resolvedAt DATETIME
            );
            CREATE INDEX action_journal_artifact ON action_journal(artifactID);
            CREATE UNIQUE INDEX action_journal_active_intent ON action_journal(artifactID,artifactRevision,kind,targetID)
                WHERE status != 'failed';
            """)
    }

    static func recoverInterruptedDispatches(in db: Database) throws {
        try db.execute(sql: "UPDATE action_journal SET status = 'needsReconciliation' WHERE status = 'dispatching'")
    }

    /// Caller must purge app-managed migration snapshots before content deletion.
    static func deleteAll(in db: Database) throws {
        try db.execute(sql: "DELETE FROM action_journal")
    }
}
