import Foundation
import GRDB
import ProviderKit

/// The `spend_ledger` row (schema v2). Internal: callers work with
/// `ProviderKit.SpendEntry`, which this converts to and from at the row
/// boundary — the same pattern `SegmentRecord` uses for `Segment`.
struct SpendLedgerRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "spend_ledger"

    var id: UUID
    var meetingID: UUID?
    var model: String
    var promptTokens: Int
    var cachedTokens: Int
    var completionTokens: Int
    var estCostUSD: Double?
    var purpose: String
    var at: Date

    init(entry: SpendEntry) {
        id = entry.id
        meetingID = entry.meetingID
        model = entry.model
        promptTokens = entry.usage.promptTokens
        cachedTokens = entry.usage.cachedTokens
        completionTokens = entry.usage.completionTokens
        estCostUSD = entry.estCostUSD
        purpose = entry.purpose.rawValue
        at = entry.at
    }

    /// `nil` when `purpose` holds a value this build doesn't know — forward
    /// compatibility for a ledger written by a newer version.
    var asEntry: SpendEntry? {
        guard let purpose = Purpose(rawValue: purpose) else { return nil }
        return SpendEntry(
            id: id,
            meetingID: meetingID,
            model: model,
            usage: TokenUsage(
                promptTokens: promptTokens,
                cachedTokens: cachedTokens,
                completionTokens: completionTokens
            ),
            estCostUSD: estCostUSD,
            purpose: purpose,
            at: at
        )
    }
}

/// The GRDB-backed `SpendLedger` (PRD FR-015). Actor-isolated for the same
/// reason as `MeetingStore`: the metered provider books from whichever task
/// made the call, while the Spend tab reads totals concurrently.
public actor SpendLedgerStore: SpendLedger {
    private let database: MacapyDatabase

    public init(database: MacapyDatabase) {
        self.database = database
    }

    public func record(_ entry: SpendEntry) async throws {
        try await database.dbWriter.write { db in
            try SpendLedgerRecord(entry: entry).insert(db)
        }
    }

    /// Rows with unknown cost contribute nothing — SQL `SUM` skips NULLs, which
    /// is exactly the intended semantics: an unpriced call can't be counted, and
    /// pretending it cost zero is the same number with a false claim attached.
    public func totalCostUSD(meetingID: UUID) async throws -> Double {
        try await database.dbWriter.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(estCostUSD), 0) FROM spend_ledger WHERE meetingID = ?",
                arguments: [meetingID]
            ) ?? 0
        }
    }

    /// One meeting's calls, oldest first (the Spend tab reads chronologically).
    public func entries(meetingID: UUID) async throws -> [SpendEntry] {
        try await database.dbWriter.read { db in
            try SpendLedgerRecord
                .filter(Column("meetingID") == meetingID)
                .order(Column("at"))
                .fetchAll(db)
                .compactMap(\.asEntry)
        }
    }

    /// Every call ever made, oldest first — including the ones outside a
    /// meeting (settings "test connection").
    public func allEntries() async throws -> [SpendEntry] {
        try await database.dbWriter.read { db in
            try SpendLedgerRecord
                .order(Column("at"))
                .fetchAll(db)
                .compactMap(\.asEntry)
        }
    }
}
