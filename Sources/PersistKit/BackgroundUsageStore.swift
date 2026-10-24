import Foundation
import GRDB
import ProviderKit

/// Durable admission shares one SQLite transaction with the existing meeting
/// ledger. It stores identifiers and accounting only, never provider text.
public actor BackgroundUsageStore {
    private let database: MacapyDatabase
    public init(database: MacapyDatabase) { self.database = database }

    public func admit(_ admission: UsageAdmission) throws -> DurableUsageReservation {
        try Self.validate(admission)
        return try database.dbWriter.write { db in
            // GRDB persists dates to milliseconds. Use the same precision for
            // admission and elapsed-time comparisons, including exact debounce
            // boundaries after another store instance reads the receipt.
            let admissionMilliseconds = Self.milliseconds(admission.at)
            let admittedAt = Date(timeIntervalSince1970: Double(admissionMilliseconds) / 1_000)
            let day = Self.day(admittedAt)
            try Self.advanceClock(db, day: day)
            guard try Row.fetchOne(db, sql: "SELECT id FROM usage_attempts WHERE id=?", arguments: [admission.id]) == nil else {
                throw DurableUsageError.duplicateJob
            }
            let scope: String
            let held: Double
            switch admission.scope {
            case .meeting(let meetingID):
                scope = "meeting"
                guard let meeting = try MeetingRecord.fetchOne(db, id: meetingID) else { throw DurableUsageError.sourceUnavailable }
                if admission.job != nil {
                    guard !meeting.ephemeral,
                          try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_meeting_optins WHERE meetingID=?)", arguments: [meetingID]) == true
                    else { throw DurableUsageError.sourceUnavailable }
                }
                let spent = try Self.meetingCommitment(db, meetingID: meetingID)
                held = admission.estimatedCostUSD ?? admission.meetingCapUSD.map { max(0, $0 - spent) } ?? 0
                if let cap = admission.meetingCapUSD {
                    guard (admission.estimatedCostUSD != nil || spent < cap), spent + held <= cap + 0.000000001 else {
                        throw ProviderError.capReached(spentUSD: spent, capUSD: cap)
                    }
                }
            case .briefs:
                scope = "brief"
                guard let job = admission.job, try db.tableExists("brief_events"),
                      try String.fetchOne(db, sql: "SELECT revision FROM brief_events WHERE id=?", arguments: [job.id]) == job.sourceRevision,
                      try Bool.fetchOne(db, sql: "SELECT enabled FROM brief_preferences WHERE id=1") == true
                else { throw DurableUsageError.sourceUnavailable }
                if job.trigger == .automatic {
                    guard try Bool.fetchOne(db, sql: "SELECT automaticAIEnabled FROM brief_preferences WHERE id=1") == true
                    else { throw DurableUsageError.sourceUnavailable }
                }
                held = admission.estimatedCostUSD!
                let budget = try Self.summary(db, day: day)
                guard held <= BriefUsagePolicy.perGenerationCapUSD + 0.000000001,
                      budget.committedUSD + held <= BriefUsagePolicy.dailyCapUSD + 0.000000001 else {
                    throw ProviderError.capReached(spentUSD: budget.committedUSD, capUSD: BriefUsagePolicy.dailyCapUSD)
                }
                if job.trigger == .automatic && budget.automaticCount >= BriefUsagePolicy.maximumAutomaticGenerations {
                    throw DurableUsageError.automaticLimitReached
                }
                if let previous = try Date.fetchOne(db, sql: "SELECT MAX(createdAt) FROM usage_attempts WHERE scope='brief' AND jobID=?", arguments: [job.id]) {
                    let elapsedMilliseconds = admissionMilliseconds - Self.milliseconds(previous)
                    guard elapsedMilliseconds >= 0 else { throw DurableUsageError.clockMovedBackwards }
                    guard elapsedMilliseconds >= Int64(BriefUsagePolicy.debounceSeconds * 1_000) else { throw DurableUsageError.debounceActive }
                }
            }
            if let job = admission.job {
                let onlyAutomatic = scope == "meeting" && job.trigger == .automatic
                if scope == "brief" || onlyAutomatic {
                    let clause = onlyAutomatic ? " AND automatic=1" : ""
                    if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM usage_attempts WHERE scope=? AND jobID=? AND jobRevision=?\(clause))",
                                         arguments: [scope,job.id,job.revision]) == true { throw DurableUsageError.duplicateJob }
                }
            }
            try db.execute(sql: """
                INSERT INTO usage_attempts(id,scope,meetingID,jobID,jobRevision,sourceRevision,automatic,model,purpose,estimateUSD,heldUSD,state,bucketDay,createdAt)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,'prepared',?,?)
                """, arguments: [admission.id,scope,admission.scope.meetingID,admission.job?.id,admission.job?.revision,admission.job?.sourceRevision,
                                    admission.job?.trigger == .automatic,admission.model,admission.purpose.rawValue,
                                    admission.estimatedCostUSD,held,day,admittedAt])
            return DurableUsageReservation(id: admission.id, scope: admission.scope,
                                           estimatedCostUSD: admission.estimatedCostUSD, heldCostUSD: held)
        }
    }

    public func markDispatched(id: UUID, at: Date = Date()) throws {
        guard at.timeIntervalSince1970.isFinite,
              (-62_135_596_800...253_402_300_799).contains(at.timeIntervalSince1970) else { throw DurableUsageError.invalidAdmission }
        try database.dbWriter.write { db in
            try Self.advanceClock(db, day: Self.day(at))
            guard let row = try Row.fetchOne(db, sql: "SELECT scope,meetingID,jobID,sourceRevision,automatic FROM usage_attempts WHERE id=? AND state='prepared'", arguments: [id]) else {
                throw DurableUsageError.invalidState
            }
            if let jobID = row["jobID"] as String? {
                if row["scope"] as String == "brief" {
                    let expectedRevision: String? = row["sourceRevision"]
                    guard try String.fetchOne(db, sql: "SELECT revision FROM brief_events WHERE id=?", arguments: [jobID]) == expectedRevision,
                          expectedRevision != nil,
                          try Bool.fetchOne(db, sql: "SELECT enabled FROM brief_preferences WHERE id=1") == true
                    else { throw DurableUsageError.sourceUnavailable }
                    if row["automatic"] as Bool {
                        guard try Bool.fetchOne(db, sql: "SELECT automaticAIEnabled FROM brief_preferences WHERE id=1") == true
                        else { throw DurableUsageError.sourceUnavailable }
                    }
                } else {
                    let meetingID: UUID = row["meetingID"]
                    guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_meeting_optins WHERE meetingID=?)", arguments: [meetingID]) == true
                    else { throw DurableUsageError.sourceUnavailable }
                }
            }
            try db.execute(sql: "UPDATE usage_attempts SET state='dispatching',dispatchedAt=? WHERE id=? AND state='prepared'", arguments: [at,id])
            guard db.changesCount == 1 else { throw DurableUsageError.invalidState }
        }
    }

    @discardableResult
    public func settle(id: UUID, usage: TokenUsage?, costUSD: Double?, at: Date = Date()) throws -> SpendEntry? {
        if let usage {
            guard usage.promptTokens >= 0, usage.cachedTokens >= 0, usage.completionTokens >= 0,
                  usage.cachedTokens <= usage.promptTokens else { throw DurableUsageError.invalidAdmission }
        }
        guard costUSD.map({ $0.isFinite && $0 >= 0 }) != false else { throw DurableUsageError.invalidAdmission }
        return try database.dbWriter.write { db -> SpendEntry? in
            // Source deletion intentionally removes the receipt linkage. Never
            // resurrect it; its anonymized conservative charge remains held.
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM usage_attempts WHERE id=?", arguments: [id]) else { return nil }
            let state: String = row["state"]
            if state == "settled" {
                guard let existing = try SpendLedgerRecord.fetchOne(db, key: id)?.asEntry,
                      existing.usage == usage, existing.estCostUSD == costUSD else { throw DurableUsageError.settlementConflict }
                return existing
            }
            guard state == "dispatching" || state == "unknown" else { throw DurableUsageError.invalidState }
            guard let usage else {
                try db.execute(sql: "UPDATE usage_attempts SET state='unknown',settledAt=? WHERE id=?", arguments: [at,id])
                return nil
            }
            guard let purpose = Purpose(rawValue: row["purpose"]) else { throw DurableUsageError.invalidState }
            let entry = SpendEntry(id: id, meetingID: row["meetingID"], model: row["model"], usage: usage,
                                   estCostUSD: costUSD, purpose: purpose, at: at)
            if let existing = try SpendLedgerRecord.fetchOne(db, key: id)?.asEntry {
                guard existing.usage == usage, existing.estCostUSD == costUSD else { throw DurableUsageError.settlementConflict }
            } else { try SpendLedgerRecord(entry: entry).insert(db) }
            try db.execute(sql: "UPDATE usage_attempts SET state=?,costUSD=?,settledAt=? WHERE id=?",
                           arguments: [costUSD == nil ? "unknown" : "settled",costUSD,at,id])
            // Return the durable representation on the first settlement too,
            // so an idempotent repeat has exactly the same timestamp and data.
            return try SpendLedgerRecord.fetchOne(db, key: id)?.asEntry
        }
    }

    public func cancel(id: UUID) throws {
        try database.dbWriter.write { db in
            try db.execute(sql: """
                UPDATE usage_attempts SET state=CASE WHEN state='prepared' THEN 'cancelled' ELSE 'unknown' END
                WHERE id=? AND state IN ('prepared','dispatching','unknown')
                """, arguments: [id])
        }
    }

    public func recoverInterrupted() throws {
        try database.dbWriter.write { db in try BackgroundUsageSchema.recoverInterrupted(in: db) }
    }

    public func summary(now: Date = Date()) throws -> BackgroundUsageSummary {
        guard now.timeIntervalSince1970.isFinite,
              (-62_135_596_800...253_402_300_799).contains(now.timeIntervalSince1970) else { throw DurableUsageError.invalidAdmission }
        return try database.dbWriter.write { db in
            let requestedDay = Self.day(now)
            let latest = try Int.fetchOne(db, sql: "SELECT latestDay FROM usage_budget_clock WHERE id=1") ?? requestedDay
            let effectiveDay = max(requestedDay, latest)
            try Self.advanceClock(db, day: effectiveDay)
            return try Self.summary(db, day: effectiveDay)
        }
    }

    public func commitmentUSD(meetingID: UUID) throws -> Double {
        try database.dbWriter.read { db in try Self.meetingCommitment(db, meetingID: meetingID) }
    }

    public func uncertainUSD(meetingID: UUID) throws -> Double {
        try database.dbWriter.read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(heldUSD),0) FROM usage_attempts WHERE meetingID=? AND state='unknown'", arguments: [meetingID]) ?? 0
        }
    }

    public func deleteContent() throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            // Removing meeting budget linkage while its source still exists
            // would reset that meeting's cap. The composition-owned delete-all
            // transaction uses the schema helper and deletes those meetings in
            // the same transaction instead.
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM usage_attempts WHERE meetingID IS NOT NULL)") == false
            else { throw DurableUsageError.invalidState }
            try BackgroundUsageSchema.deleteAll(in: db)
        }
    }

    /// Only the separately confirmed full-reset flow may call this. It does
    /// not erase ordinary ledger history or claim past provider calls were free.
    public func resetBudgets() throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM usage_attempts; DELETE FROM usage_budget_aggregates; DELETE FROM usage_budget_clock;")
        }
    }

    private static func validate(_ admission: UsageAdmission) throws {
        guard !admission.model.isEmpty, admission.model.utf8.count <= 512,
              admission.at.timeIntervalSince1970.isFinite,
              (-62_135_596_800...253_402_300_799).contains(admission.at.timeIntervalSince1970),
              admission.estimatedCostUSD.map({ $0.isFinite && $0 >= 0 }) != false,
              admission.meetingCapUSD.map({ $0.isFinite && $0 >= 0 }) != false else { throw DurableUsageError.invalidAdmission }
        if let job = admission.job {
            guard (1...128).contains(job.id.utf8.count),
                  job.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  job.revision.utf8.count == 64, job.revision.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
            else { throw DurableUsageError.invalidAdmission }
            guard admission.estimatedCostUSD != nil else { throw DurableUsageError.unpricedBackgroundModel }
        }
        switch admission.scope {
        case .briefs:
            guard let revision = admission.job?.sourceRevision, admission.purpose == .brief,
                  revision.utf8.count == 64,
                  revision.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
            else { throw DurableUsageError.invalidAdmission }
        case .meeting:
            guard admission.purpose != .brief, admission.job == nil || admission.purpose == .memory else { throw DurableUsageError.invalidAdmission }
        }
    }

    private static func day(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 86_400)) }
    private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }

    private static func advanceClock(_ db: Database, day: Int) throws {
        if let previous = try Int.fetchOne(db, sql: "SELECT latestDay FROM usage_budget_clock WHERE id=1"), day < previous {
            throw DurableUsageError.clockMovedBackwards
        }
        try db.execute(sql: "INSERT INTO usage_budget_clock(id,latestDay) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET latestDay=excluded.latestDay", arguments: [day])
        // Settled expired aggregates have no continuing budget purpose. Keep
        // unresolved debits across rollover, stripped of old daily counts.
        try db.execute(sql: "DELETE FROM usage_budget_aggregates WHERE bucketDay < ? AND unknownUSD=0", arguments: [day])
        try db.execute(sql: "UPDATE usage_budget_aggregates SET knownUSD=0,automaticCount=0 WHERE bucketDay < ?", arguments: [day])
    }

    private static func meetingCommitment(_ db: Database, meetingID: UUID) throws -> Double {
        let booked = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(estCostUSD),0) FROM spend_ledger WHERE meetingID=?", arguments: [meetingID]) ?? 0
        let held = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(heldUSD),0) FROM usage_attempts WHERE meetingID=? AND state IN ('prepared','dispatching','unknown')", arguments: [meetingID]) ?? 0
        return booked + held
    }

    private static func summary(_ db: Database, day: Int) throws -> BackgroundUsageSummary {
        let known = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(costUSD),0) FROM usage_attempts WHERE scope='brief' AND bucketDay=? AND state='settled'", arguments: [day]) ?? 0
        let knownAggregate = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(knownUSD),0) FROM usage_budget_aggregates WHERE scope='brief' AND bucketDay=?", arguments: [day]) ?? 0
        let held = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(heldUSD),0) FROM usage_attempts WHERE scope='brief' AND state IN ('prepared','dispatching','unknown')") ?? 0
        let heldAggregate = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(unknownUSD),0) FROM usage_budget_aggregates WHERE scope='brief'") ?? 0
        let count = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(automatic),0) FROM usage_attempts WHERE scope='brief' AND bucketDay=?", arguments: [day]) ?? 0
        let countAggregate = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(automaticCount),0) FROM usage_budget_aggregates WHERE scope='brief' AND bucketDay=?", arguments: [day]) ?? 0
        return BackgroundUsageSummary(dayStart: Date(timeIntervalSince1970: Double(day) * 86_400),
                                      nextResetAt: Date(timeIntervalSince1970: Double(day + 1) * 86_400),
                                      knownCostUSD: known + knownAggregate, heldCostUSD: held + heldAggregate,
                                      automaticCount: count + countAggregate)
    }
}

extension SpendLedgerStore: DurableUsageLedger {
    public func admitUsage(_ admission: UsageAdmission) async throws -> DurableUsageReservation {
        try await BackgroundUsageStore(database: database).admit(admission)
    }
    public func markUsageDispatched(id: UUID) async throws { try await BackgroundUsageStore(database: database).markDispatched(id: id) }
    public func settleUsage(id: UUID, usage: TokenUsage?, costUSD: Double?, at: Date) async throws -> SpendEntry? {
        try await BackgroundUsageStore(database: database).settle(id: id, usage: usage, costUSD: costUSD, at: at)
    }
    public func cancelUsage(id: UUID) async throws { try await BackgroundUsageStore(database: database).cancel(id: id) }
    public func usageCommitmentUSD(meetingID: UUID) async throws -> Double { try await BackgroundUsageStore(database: database).commitmentUSD(meetingID: meetingID) }
    public func usageUncertainUSD(meetingID: UUID) async throws -> Double { try await BackgroundUsageStore(database: database).uncertainUSD(meetingID: meetingID) }
}
