import GRDB

enum BriefSchema {
    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE brief_preferences(id INTEGER PRIMARY KEY CHECK(id=1), enabled BOOLEAN NOT NULL DEFAULT 0,
                selectedCalendars BLOB NOT NULL);
            CREATE TABLE brief_events(id TEXT PRIMARY KEY, calendarID TEXT NOT NULL, revision TEXT NOT NULL,
                snapshot BLOB NOT NULL, startsAt DATETIME NOT NULL, expiresAt DATETIME NOT NULL, mappingRevision INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE brief_entity_links(eventID TEXT NOT NULL REFERENCES brief_events(id) ON DELETE CASCADE,
                entityID BLOB NOT NULL REFERENCES memory_entities(id) ON DELETE CASCADE, PRIMARY KEY(eventID,entityID));
            CREATE TABLE brief_snapshots(eventID TEXT PRIMARY KEY REFERENCES brief_events(id) ON DELETE CASCADE,
                eventRevision TEXT NOT NULL, mappingRevision INTEGER NOT NULL, snapshot BLOB NOT NULL);
            CREATE TRIGGER brief_mapping_removed AFTER DELETE ON brief_entity_links
            BEGIN UPDATE brief_events SET mappingRevision=mappingRevision+1 WHERE id=OLD.eventID;
                DELETE FROM brief_snapshots WHERE eventID=OLD.eventID; END;
            CREATE TRIGGER brief_mapping_added AFTER INSERT ON brief_entity_links
            BEGIN UPDATE brief_events SET mappingRevision=mappingRevision+1 WHERE id=NEW.eventID;
                DELETE FROM brief_snapshots WHERE eventID=NEW.eventID; END;
            """)
        // Small optional caches are invalidated conservatively. This avoids
        // retaining text after any underlying source/consent/review changes,
        // including edits through other store instances or SQL migrations.
        for table in ["memory_facts", "memory_fact_sources", "memory_fact_entities", "memory_meeting_optins",
                      "documents", "document_chunks", "document_links", "segments", "artifacts", "memory_entities"] {
            for operation in ["UPDATE", "DELETE"] {
                try db.execute(sql: """
                    CREATE TRIGGER brief_invalidate_\(table)_\(operation.lowercased()) AFTER \(operation) ON \(table)
                    BEGIN DELETE FROM brief_snapshots; END;
                    """)
            }
        }
    }

    static func deleteAll(in db: Database) throws {
        try db.execute(sql: "DELETE FROM brief_events; DELETE FROM brief_preferences;")
    }
}
