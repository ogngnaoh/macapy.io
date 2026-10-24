import GRDB

/// Installed once by the composition-owned forward migration registry.
enum MemorySchema {
    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE memory_meeting_optins(meetingID BLOB PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE);
            CREATE TABLE memory_entities(id BLOB PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL);
            CREATE TABLE memory_aliases(id BLOB PRIMARY KEY, entityID BLOB NOT NULL REFERENCES memory_entities(id) ON DELETE CASCADE,
                kind TEXT NOT NULL, name TEXT NOT NULL, normalized TEXT NOT NULL, UNIQUE(kind, normalized));
            CREATE TABLE memory_meeting_entities(meetingID BLOB NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                entityID BLOB NOT NULL REFERENCES memory_entities(id) ON DELETE CASCADE, PRIMARY KEY(meetingID, entityID));
            CREATE TABLE memory_facts(id BLOB PRIMARY KEY, meetingID BLOB NOT NULL REFERENCES memory_meeting_optins(meetingID) ON DELETE CASCADE,
                kind TEXT NOT NULL, text TEXT NOT NULL, status TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
                statedAt DATETIME NOT NULL, createdAt DATETIME NOT NULL, editedAt DATETIME, completedAt DATETIME);
            CREATE INDEX memory_facts_meeting ON memory_facts(meetingID);
            CREATE TABLE memory_fact_entities(factID BLOB NOT NULL REFERENCES memory_facts(id) ON DELETE CASCADE,
                entityID BLOB NOT NULL REFERENCES memory_entities(id) ON DELETE CASCADE, PRIMARY KEY(factID,entityID));
            CREATE TABLE documents(id BLOB PRIMARY KEY, name TEXT NOT NULL, mediaType TEXT NOT NULL,
                snapshotText TEXT NOT NULL, textHash TEXT NOT NULL, revision INTEGER NOT NULL, chunkerVersion INTEGER NOT NULL,
                createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, allowedForAI BOOLEAN NOT NULL DEFAULT 0);
            CREATE TABLE document_links(documentID BLOB NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                meetingID BLOB NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, PRIMARY KEY(documentID,meetingID));
            CREATE TABLE document_chunks(id BLOB PRIMARY KEY, documentID BLOB NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL, ordinal INTEGER NOT NULL, pageNumber INTEGER,
                startCharacter INTEGER NOT NULL, endCharacter INTEGER NOT NULL, text TEXT NOT NULL,
                UNIQUE(documentID,ordinal));
            CREATE TABLE document_embeddings(chunkID BLOB PRIMARY KEY REFERENCES document_chunks(id) ON DELETE CASCADE,
                language TEXT NOT NULL, modelRevision INTEGER NOT NULL, dimension INTEGER NOT NULL,
                chunkerVersion INTEGER NOT NULL, sourceHash TEXT NOT NULL, vector BLOB NOT NULL);
            CREATE TABLE memory_fact_sources(id BLOB PRIMARY KEY, factID BLOB NOT NULL REFERENCES memory_facts(id) ON DELETE CASCADE,
                segmentID BLOB REFERENCES segments(id) ON DELETE CASCADE,
                artifactID BLOB REFERENCES artifacts(id) ON DELETE CASCADE,
                chunkID BLOB REFERENCES document_chunks(id) ON DELETE CASCADE,
                referenceJSON TEXT NOT NULL,
                CHECK ((segmentID IS NOT NULL) + (artifactID IS NOT NULL) + (chunkID IS NOT NULL) = 1));
            CREATE INDEX memory_sources_segment ON memory_fact_sources(segmentID);
            CREATE INDEX memory_sources_artifact ON memory_fact_sources(artifactID);
            CREATE INDEX memory_sources_chunk ON memory_fact_sources(chunkID);
            CREATE TRIGGER memory_artifact_changed AFTER UPDATE OF revision,status,completedAt ON artifacts
            WHEN OLD.revision != NEW.revision OR OLD.status != NEW.status OR OLD.completedAt IS NOT NEW.completedAt
            BEGIN DELETE FROM memory_facts WHERE id IN (SELECT factID FROM memory_fact_sources WHERE artifactID = NEW.id); END;
            CREATE TRIGGER memory_artifact_deleted BEFORE DELETE ON artifacts
            BEGIN DELETE FROM memory_facts WHERE id IN (SELECT factID FROM memory_fact_sources WHERE artifactID = OLD.id); END;
            CREATE TRIGGER memory_segment_deleted BEFORE DELETE ON segments
            BEGIN DELETE FROM memory_facts WHERE id IN (SELECT factID FROM memory_fact_sources WHERE segmentID = OLD.id); END;
            CREATE TRIGGER memory_segment_changed AFTER UPDATE OF text ON segments WHEN OLD.text != NEW.text
            BEGIN DELETE FROM memory_facts WHERE id IN (SELECT factID FROM memory_fact_sources WHERE segmentID = NEW.id); END;
            CREATE TRIGGER memory_chunk_deleted BEFORE DELETE ON document_chunks
            BEGIN DELETE FROM memory_facts WHERE id IN (SELECT factID FROM memory_fact_sources WHERE chunkID = OLD.id); END;
            CREATE TRIGGER document_last_detach AFTER DELETE ON document_links
            BEGIN DELETE FROM documents WHERE id = OLD.documentID AND NOT EXISTS
                (SELECT 1 FROM document_links WHERE documentID = OLD.documentID); END;
            """)
        try db.create(virtualTable: "memory_facts_fts", using: FTS5()) { t in
            t.synchronize(withTable: "memory_facts"); t.tokenizer = .unicode61(); t.column("text")
        }
        try db.create(virtualTable: "document_chunks_fts", using: FTS5()) { t in
            t.synchronize(withTable: "document_chunks"); t.tokenizer = .unicode61(); t.column("text")
        }
    }

    static func deleteAll(in db: Database) throws {
        try db.execute(sql: "DELETE FROM memory_meeting_optins; DELETE FROM memory_entities; DELETE FROM documents;")
        for table in ["memory_facts_fts", "document_chunks_fts"] {
            try db.execute(sql: "INSERT INTO \(table)(\(table)) VALUES('optimize')")
        }
    }
}
