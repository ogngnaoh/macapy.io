import GRDB

/// v9. Budget aggregates contain no model, event, meeting, or job identifiers.
enum BackgroundUsageSchema {
    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE usage_attempts (
                id BLOB PRIMARY KEY NOT NULL, scope TEXT NOT NULL CHECK(scope IN ('meeting','brief')),
                meetingID BLOB REFERENCES meetings(id) ON DELETE CASCADE,
                jobID TEXT, jobRevision TEXT, sourceRevision TEXT, automatic BOOLEAN NOT NULL,
                model TEXT NOT NULL, purpose TEXT NOT NULL, estimateUSD REAL, heldUSD REAL NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('prepared','dispatching','settled','unknown','cancelled')),
                bucketDay INTEGER NOT NULL, createdAt DATETIME NOT NULL, dispatchedAt DATETIME, settledAt DATETIME,
                costUSD REAL
            );
            CREATE INDEX usage_attempt_meeting ON usage_attempts(meetingID);
            CREATE INDEX usage_attempt_job ON usage_attempts(scope,jobID,jobRevision);
            CREATE INDEX usage_attempt_window ON usage_attempts(scope,bucketDay,state);
            CREATE TABLE usage_budget_aggregates (
                scope TEXT NOT NULL, bucketDay INTEGER NOT NULL, knownUSD REAL NOT NULL DEFAULT 0,
                unknownUSD REAL NOT NULL DEFAULT 0, automaticCount INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(scope,bucketDay)
            );
            CREATE TABLE usage_budget_clock(id INTEGER PRIMARY KEY CHECK(id=1), latestDay INTEGER NOT NULL);
            CREATE TRIGGER usage_meeting_deleted BEFORE DELETE ON meetings BEGIN
                \(anonymizeSQL(condition: "meetingID=OLD.id"))
            END;
            """)
    }

    /// Install after v10 creates brief_events. Every path deleting an event,
    /// including TTL/permission/source changes, preserves its budget charge.
    static func installBriefDeletionTrigger(in db: Database) throws {
        try db.execute(sql: """
            CREATE TRIGGER usage_brief_deleted BEFORE DELETE ON brief_events BEGIN
                \(anonymizeSQL(condition: "scope='brief' AND jobID=OLD.id"))
            END;
            """)
    }

    static func recoverInterrupted(in db: Database) throws {
        try db.execute(sql: """
            UPDATE usage_attempts SET state='cancelled' WHERE state='prepared';
            UPDATE usage_attempts SET state='unknown' WHERE state='dispatching';
            """)
    }

    /// Caller purges migration snapshots first. This is content deletion, not
    /// the separately disclosed full budget reset.
    static func deleteAll(in db: Database) throws { try db.execute(sql: anonymizeSQL(condition: "1")) }

    static func anonymizeSQL(condition: String) -> String {
        """
        INSERT INTO usage_budget_aggregates(scope,bucketDay,knownUSD,unknownUSD,automaticCount)
        SELECT scope,bucketDay,
            SUM(CASE WHEN state='settled' THEN COALESCE(costUSD,0) ELSE 0 END),
            SUM(CASE WHEN state IN ('dispatching','unknown') THEN heldUSD ELSE 0 END),
            SUM(automatic)
        FROM usage_attempts WHERE \(condition) GROUP BY scope,bucketDay
        ON CONFLICT(scope,bucketDay) DO UPDATE SET
            knownUSD=knownUSD+excluded.knownUSD, unknownUSD=unknownUSD+excluded.unknownUSD,
            automaticCount=automaticCount+excluded.automaticCount;
        DELETE FROM spend_ledger WHERE id IN (SELECT id FROM usage_attempts WHERE \(condition));
        DELETE FROM usage_attempts WHERE \(condition);
        """
    }
}
