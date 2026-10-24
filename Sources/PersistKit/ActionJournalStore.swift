import ActionKit
import Foundation
import GRDB

public enum ActionJournalStatus: String, Codable, Sendable, Equatable {
    case prepared, dispatching, created, failed, needsReconciliation
}

public struct ActionJournalRecord: Sendable, Equatable, Identifiable {
    public let action: ReviewedAction
    public let status: ActionJournalStatus
    public let externalIdentifier: String?
    public let failure: ActionFailure?
    public let preparedAt: Date
    public let dispatchedAt: Date?
    public let resolvedAt: Date?
    public var id: UUID { action.operationID }
    public var intentHash: String { action.intentHash }
}

public enum ActionJournalError: Error, Sendable, Equatable {
    case sourceNotFound
    case sourceNotActionItem
    case sourceRejected
    case ephemeralSource
    case revisionConflict
    case intentConflict
    case alreadyPreparedOrDispatched
    case notFound
    case invalidState
    case corruptRecord
}

/// SQLite admission and platform save are deliberately separate operations.
/// Persist prepared intent, atomically admit it once, then call the adapter and
/// settle. Failure between admission and settlement is an unknown outcome.
public actor ActionJournalStore {
    private let database: MacapyDatabase
    public init(database: MacapyDatabase) { self.database = database }

    @discardableResult
    public func prepare(_ action: ReviewedAction, at date: Date = Date()) throws -> ActionJournalRecord {
        let encoded = try action.encoded()
        return try database.dbWriter.write { db in
            try Self.checkSource(db, action: action)
            if let existing = try Self.fetch(db, operationID: action.operationID) {
                guard existing.intentHash == action.intentHash else { throw ActionJournalError.intentConflict }
                return existing
            }
            if try Row.fetchOne(db, sql: """
                SELECT operationID FROM action_journal
                WHERE artifactID = ? AND artifactRevision = ? AND kind = ? AND targetID = ? AND status != 'failed'
                """, arguments: [action.artifactID, action.artifactRevision, action.kind.rawValue, action.target.id]) != nil {
                throw ActionJournalError.alreadyPreparedOrDispatched
            }
            try db.execute(sql: """
                INSERT INTO action_journal(operationID,artifactID,artifactRevision,kind,targetID,intentHash,reviewJSON,status,preparedAt)
                VALUES(?,?,?,?,?,?,?,'prepared',?)
                """, arguments: [action.operationID, action.artifactID, action.artifactRevision, action.kind.rawValue,
                                    action.target.id, action.intentHash, encoded, date])
            return try Self.fetch(db, operationID: action.operationID)!
        }
    }

    /// Exactly one competing caller can transition prepared → dispatching.
    /// The returned value is the persisted review, never caller-provided fields.
    public func admit(operationID: UUID, expectedHash: String, at date: Date = Date()) throws -> ReviewedAction {
        try database.dbWriter.write { db in
            guard let record = try Self.fetch(db, operationID: operationID) else { throw ActionJournalError.notFound }
            guard record.intentHash == expectedHash else { throw ActionJournalError.intentConflict }
            guard record.status == .prepared else { throw ActionJournalError.alreadyPreparedOrDispatched }
            try Self.checkSource(db, action: record.action)
            try db.execute(sql: "UPDATE action_journal SET status = 'dispatching', dispatchedAt = ? WHERE operationID = ? AND status = 'prepared'",
                           arguments: [date, operationID])
            guard db.changesCount == 1 else { throw ActionJournalError.alreadyPreparedOrDispatched }
            return record.action
        }
    }

    /// Missing rows mean the user deleted the source while work was in flight.
    /// Never recreate that content or retain a result under a replacement row.
    @discardableResult
    public func finish(
        operationID: UUID, expectedHash: String, result: ActionDispatchResult, at date: Date = Date()
    ) throws -> ActionJournalRecord? {
        try database.dbWriter.write { db in
            guard let record = try Self.fetch(db, operationID: operationID) else { return nil }
            guard record.intentHash == expectedHash else { throw ActionJournalError.intentConflict }
            guard record.status == .dispatching else { throw ActionJournalError.invalidState }
            let status: ActionJournalStatus
            let identifier: String?
            let failure: ActionFailure?
            switch result {
            case .created(let value):
                guard !value.isEmpty else { throw ActionJournalError.corruptRecord }
                status = .created; identifier = value; failure = nil
            case .failed(let value): status = .failed; identifier = nil; failure = value
            case .unknown: status = .needsReconciliation; identifier = nil; failure = nil
            }
            try db.execute(sql: "UPDATE action_journal SET status=?, externalIdentifier=?, failureCode=?, resolvedAt=? WHERE operationID=?",
                           arguments: [status.rawValue, identifier, failure?.rawValue, date, operationID])
            return try Self.fetch(db, operationID: operationID)
        }
    }

    /// Invoke at process recovery, never while a live dispatcher is settling.
    public func recoverInterruptedDispatches() throws {
        try database.dbWriter.write { db in try ActionSchema.recoverInterruptedDispatches(in: db) }
    }

    @discardableResult
    public func recordReconciliation(
        operationID: UUID, expectedHash: String, result: ActionReconciliationResult, at date: Date = Date()
    ) throws -> ActionJournalRecord? {
        try database.dbWriter.write { db in
            guard let record = try Self.fetch(db, operationID: operationID) else { return nil }
            guard record.intentHash == expectedHash else { throw ActionJournalError.intentConflict }
            guard record.status == .needsReconciliation else { throw ActionJournalError.invalidState }
            if case .found(let identifier) = result {
                guard !identifier.isEmpty else { throw ActionJournalError.corruptRecord }
                try db.execute(sql: "UPDATE action_journal SET status='created', externalIdentifier=?, resolvedAt=? WHERE operationID=?",
                               arguments: [identifier, date, operationID])
            }
            // Not-found, unavailable, and ambiguity do not prove no save occurred.
            // Preserve needsReconciliation and never re-enable dispatch.
            return try Self.fetch(db, operationID: operationID)
        }
    }

    public func record(operationID: UUID) throws -> ActionJournalRecord? {
        try database.dbWriter.read { db in try Self.fetch(db, operationID: operationID) }
    }

    public func records(for artifactID: UUID) throws -> [ActionJournalRecord] {
        try database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM action_journal WHERE artifactID=? ORDER BY preparedAt,rowid",
                             arguments: [artifactID]).map(Self.decode)
        }
    }

    public func unresolvedRecords() throws -> [ActionJournalRecord] {
        try database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM action_journal WHERE status='needsReconciliation' ORDER BY preparedAt,rowid").map(Self.decode)
        }
    }

    public func deleteAll() throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in try ActionSchema.deleteAll(in: db) }
    }

    private static func checkSource(_ db: Database, action: ReviewedAction) throws {
        guard let artifact = try ArtifactRecord.fetchOne(db, id: action.artifactID) else { throw ActionJournalError.sourceNotFound }
        guard let meeting = try MeetingRecord.fetchOne(db, id: artifact.meetingID) else { throw ActionJournalError.sourceNotFound }
        guard !meeting.ephemeral else { throw ActionJournalError.ephemeralSource }
        guard artifact.artifactKind == .actionItem else { throw ActionJournalError.sourceNotActionItem }
        guard artifact.artifactStatus != .rejected else { throw ActionJournalError.sourceRejected }
        guard artifact.revision == action.artifactRevision else { throw ActionJournalError.revisionConflict }
    }

    private static func fetch(_ db: Database, operationID: UUID) throws -> ActionJournalRecord? {
        try Row.fetchOne(db, sql: "SELECT * FROM action_journal WHERE operationID=?", arguments: [operationID]).map(decode)
    }

    private static func decode(_ row: Row) throws -> ActionJournalRecord {
        let data: Data = row["reviewJSON"]
        let action = try ReviewedAction.decode(data)
        guard let status = ActionJournalStatus(rawValue: row["status"]),
              action.operationID == row["operationID"], action.artifactID == row["artifactID"],
              action.artifactRevision == row["artifactRevision"], action.kind.rawValue == row["kind"],
              action.target.id == row["targetID"], action.intentHash == row["intentHash"]
        else { throw ActionJournalError.corruptRecord }
        let failureCode: String? = row["failureCode"]
        return ActionJournalRecord(
            action: action, status: status, externalIdentifier: row["externalIdentifier"],
            failure: failureCode.flatMap(ActionFailure.init(rawValue:)),
            preparedAt: row["preparedAt"], dispatchedAt: row["dispatchedAt"], resolvedAt: row["resolvedAt"])
    }
}
