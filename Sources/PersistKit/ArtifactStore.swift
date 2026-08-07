import Foundation
import GRDB

/// The `artifacts` row (schema v3, SPEC §6.2). Public like `MeetingRecord`:
/// the review UI works with rows directly, and `kind`/`status` stay plain
/// `String` at the row boundary so a future value (M4's `brief`) never needs
/// a migration — typed accessors below are the app-facing surface.
public struct ArtifactRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let meetingID: UUID
    public var kind: String
    /// JSON, shaped per kind — see `SummaryPayload` / `DecisionPayload` /
    /// `ActionItemPayload`.
    public var payload: String
    public var status: String
    public var createdAt: Date

    public init(
        id: UUID,
        meetingID: UUID,
        kind: String,
        payload: String,
        status: String,
        createdAt: Date
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.payload = payload
        self.status = status
        self.createdAt = createdAt
    }
}

extension ArtifactRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "artifacts"
}

/// The artifact kinds this build knows (SPEC §6.2; `brief` arrives in M4).
public enum ArtifactKind: String, Sendable, CaseIterable {
    case summary
    case decision
    case actionItem = "action_item"
}

/// Review states (PRD FR-009: in M2 a flip is the *only* effect).
public enum ArtifactStatus: String, Sendable {
    case draft
    case approved
    case rejected
}

public extension ArtifactRecord {
    var artifactKind: ArtifactKind? { ArtifactKind(rawValue: kind) }
    var artifactStatus: ArtifactStatus? { ArtifactStatus(rawValue: status) }

    /// Decodes the payload as `T`, or `nil` when it doesn't fit — defensive
    /// for rows written by a newer build; every row this build writes
    /// round-trips cleanly.
    func payload<T: Decodable>(as type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(payload.utf8))
    }
}

/// Payload shapes, one per kind. Owner and deadline are optional *as stated in
/// the meeting* (PRD Story 4: "owner and deadline where stated") — absent
/// means the transcript never named one, and inventing it is the extractor's
/// cardinal sin.
public struct SummaryPayload: Codable, Sendable, Equatable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct DecisionPayload: Codable, Sendable, Equatable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct ActionItemPayload: Codable, Sendable, Equatable {
    public var title: String
    public var owner: String?
    public var deadline: String?

    public init(title: String, owner: String?, deadline: String?) {
        self.title = title
        self.owner = owner
        self.deadline = deadline
    }
}

/// A draft artifact before it has a row — what the post-meeting agent hands
/// over for insertion. The store assigns ids and stamps `draft`/`createdAt`
/// so the "everything lands as a reviewable draft" invariant (FR-008/FR-009)
/// is enforced where rows are made, not promised by each caller.
public struct DraftArtifact: Sendable, Equatable {
    public var kind: ArtifactKind
    public var payload: String

    public init(kind: ArtifactKind, payload: String) {
        self.kind = kind
        self.payload = payload
    }

    public init<T: Encodable>(kind: ArtifactKind, encoding value: T) throws {
        // Sorted keys: two extractions of the same content must produce
        // byte-identical payloads (deterministic rows are what make the
        // retroactive-equals-automatic check assertable at all).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        self.init(kind: kind, payload: String(decoding: data, as: UTF8.self))
    }
}

/// Owns `artifacts` reads and writes — actor-isolated like `MeetingStore`,
/// over the same database.
public actor ArtifactStore {
    private let database: MacapyDatabase

    public init(database: MacapyDatabase) {
        self.database = database
    }

    /// Inserts one extraction's drafts in a single transaction: either every
    /// row lands or none do (acceptance check 2's "zero partial artifact
    /// rows" is this transaction, not caller discipline).
    @discardableResult
    public func insertDrafts(
        _ drafts: [DraftArtifact],
        meetingID: UUID,
        createdAt: Date = Date()
    ) throws -> [ArtifactRecord] {
        let records = drafts.map { draft in
            ArtifactRecord(
                id: UUID(),
                meetingID: meetingID,
                kind: draft.kind.rawValue,
                payload: draft.payload,
                status: ArtifactStatus.draft.rawValue,
                createdAt: createdAt
            )
        }
        // Returns the rows *as stored* (read back in the same transaction):
        // SQLite's datetime storage rounds `createdAt` to milliseconds, and
        // handing back the un-rounded in-memory copies would make "what
        // insert returned" and "what a later fetch returns" unequal.
        return try database.dbWriter.write { db in
            for record in records {
                try record.insert(db)
            }
            return try records.compactMap { try ArtifactRecord.fetchOne(db, id: $0.id) }
        }
    }

    /// A meeting's artifacts in insertion order (stable within one
    /// `createdAt` batch via rowid).
    public func artifacts(for meetingID: UUID) throws -> [ArtifactRecord] {
        try database.dbWriter.read { db in
            try ArtifactRecord
                .filter(Column("meetingID") == meetingID)
                .order(Column("createdAt"), Column.rowID)
                .fetchAll(db)
        }
    }

    /// Flips one artifact's status and touches nothing else — the whole of
    /// approve/reject in M2 (FR-009: no external effect; EventKit is M4).
    /// A no-op if the id matches no row.
    public func setStatus(_ status: ArtifactStatus, id: ArtifactRecord.ID) throws {
        try database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE artifacts SET status = ? WHERE id = ?",
                arguments: [status.rawValue, id]
            )
        }
    }
}
