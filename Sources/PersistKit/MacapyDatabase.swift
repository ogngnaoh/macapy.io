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
        // v2 (M2 slice 2): the spend ledger — one row per billed LLM call
        // (PRD FR-015, SPEC §6.2). `meetingID` is nullable because the
        // Providers screen's "test connection" spends money before any meeting
        // exists; `estCostUSD` is nullable because a model with no known price
        // must read as "—", not as free.
        migrator.registerMigration("v2-spend-ledger") { db in
            try db.create(table: "spend_ledger") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("meetingID", .text)
                    .indexed()
                    .references("meetings", onDelete: .cascade)
                t.column("model", .text).notNull()
                t.column("promptTokens", .integer).notNull()
                t.column("cachedTokens", .integer).notNull()
                t.column("completionTokens", .integer).notNull()
                t.column("estCostUSD", .double)
                t.column("purpose", .text).notNull()
                t.column("at", .datetime).notNull()
            }
        }
        // v3 (M2 slice 3): draft artifacts from the post-meeting agent
        // (SPEC §6.2). `kind`/`status` are TEXT, not CHECK-constrained, so a
        // future kind (`brief`, M4) is a code change, not a migration.
        // Deleting a meeting cascades here like `segments` (specced invariant).
        migrator.registerMigration("v3-artifacts") { db in
            try db.create(table: "artifacts") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("meetingID", .text).notNull()
                    .indexed()
                    .references("meetings", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("status", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        // v4 (M2 slice 4): within-meeting speakers from diarization
        // (SPEC §6.2). `segments.speakerId` is nullable — mic segments and
        // them-segments diarization couldn't attribute stay NULL — and its FK
        // is `.setNull`, never cascade: deleting a speaker row must never
        // delete transcript rows. Deleting a meeting cascades its speakers.
        migrator.registerMigration("v4-speakers") { db in
            try db.create(table: "speakers") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("meetingID", .text).notNull()
                    .indexed()
                    .references("meetings", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("embedding", .blob)
            }
            try db.alter(table: "segments") { t in
                t.add(column: "speakerId", .text)
                    .references("speakers", onDelete: .setNull)
            }
        }
        // v5 (M2 slice 5): full-text search over titles, transcripts, and
        // artifacts (PRD FR-010; slice-05 doc decision 1). Three *synchronized
        // external-content* FTS5 tables: GRDB installs `__<fts>_ai/_ad/_au`
        // SQL triggers on the content tables and backfills pre-existing rows
        // via FTS5 `rebuild`. Because the triggers are SQL-level, FK-cascade
        // deletes (delete a meeting → its segments/artifacts go) scrub the
        // index with zero application code. Tokenizer: default unicode61, no
        // stemming — literal-token semantics are predictable and assertable.
        // `content_rowid` is the implicit rowid (our UUID PKs are BLOBs);
        // queries join back through rowid to recover UUIDs.
        migrator.registerMigration("v5-search") { db in
            // Derived search text (decision 2): per-kind payload text, never
            // raw JSON. Backfilled here for pre-v5 rows *before* the FTS
            // table's rebuild indexes them; new rows are maintained by
            // `ArtifactStore.insertDrafts`.
            try db.alter(table: "artifacts") { t in
                t.add(column: "searchText", .text).notNull().defaults(to: "")
            }
            let legacyRows = try Row.fetchAll(db, sql: "SELECT id, kind, payload FROM artifacts")
            for row in legacyRows {
                let id: UUID = row["id"]
                try db.execute(
                    sql: "UPDATE artifacts SET searchText = ? WHERE id = ?",
                    arguments: [ArtifactSearchText.derive(kind: row["kind"], payload: row["payload"]), id]
                )
            }

            try db.create(virtualTable: "meetings_fts", using: FTS5()) { t in
                t.synchronize(withTable: "meetings")
                t.tokenizer = .unicode61()
                t.column("title")
            }
            try db.create(virtualTable: "segments_fts", using: FTS5()) { t in
                t.synchronize(withTable: "segments")
                t.tokenizer = .unicode61()
                t.column("text")
            }
            try db.create(virtualTable: "artifacts_fts", using: FTS5()) { t in
                t.synchronize(withTable: "artifacts")
                t.tokenizer = .unicode61()
                t.column("searchText")
            }

            // History list + summaries order by `startedAt`; at the seeded
            // 10⁵-row scale the scan was already cheap, but the index makes
            // the ordering cost independent of history size (check 1 pins it).
            try db.create(indexOn: "meetings", columns: ["startedAt"])
        }
        return migrator
    }
}
