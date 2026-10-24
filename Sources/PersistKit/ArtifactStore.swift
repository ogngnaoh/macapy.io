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
    /// Content revision used by editors and external-action review fences.
    public private(set) var revision: Int
    public private(set) var editedAt: Date?
    /// Local task state, independent of whether this artifact was reviewed.
    public private(set) var completedAt: Date?
    /// Derived per-kind searchable text (schema v5, slice-05 doc decision 2).
    /// Computed from kind + payload at construction — never set by callers —
    /// so the row and its FTS index entry can't disagree. `setStatus` uses
    /// raw SQL and never touches it (pinned by slice-5 check 12).
    public private(set) var searchText: String

    public init(
        id: UUID,
        meetingID: UUID,
        kind: String,
        payload: String,
        status: String,
        createdAt: Date,
        revision: Int = 0,
        editedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.payload = payload
        self.status = status
        self.createdAt = createdAt
        self.revision = revision
        self.editedAt = editedAt
        self.completedAt = completedAt
        self.searchText = ArtifactSearchText.derive(kind: kind, payload: payload)
    }

    private enum CodingKeys: String, CodingKey {
        case id, meetingID, kind, payload, status, createdAt, searchText
        case revision, editedAt, completedAt
    }

    /// Older row exports predate correction metadata. Missing values have the
    /// same defaults as the additive migration; payload shapes remain intact.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            meetingID: try values.decode(UUID.self, forKey: .meetingID),
            kind: try values.decode(String.self, forKey: .kind),
            payload: try values.decode(String.self, forKey: .payload),
            status: try values.decode(String.self, forKey: .status),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            revision: try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0,
            editedAt: try values.decodeIfPresent(Date.self, forKey: .editedAt),
            completedAt: try values.decodeIfPresent(Date.self, forKey: .completedAt))
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
    var isUserEdited: Bool { editedAt != nil }
    var isComplete: Bool { artifactKind == .actionItem && completedAt != nil }

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

public enum ArtifactStoreError: Error, Equatable, Sendable {
    case notFound
    case revisionConflict
    case kindMismatch
    case emptyContent
    case notAnActionItem
    case existingArtifacts
}

/// Typed editor values prevent accidental kind changes or malformed JSON.
public enum ArtifactEdit: Sendable, Equatable {
    case summary(String)
    case decision(String)
    case actionItem(title: String, owner: String?, deadline: String?)

    fileprivate func draft() throws -> DraftArtifact {
        func required(_ value: String) throws -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ArtifactStoreError.emptyContent }
            return trimmed
        }
        func optional(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        switch self {
        case .summary(let text):
            return try DraftArtifact(kind: .summary, encoding: SummaryPayload(text: required(text)))
        case .decision(let text):
            return try DraftArtifact(kind: .decision, encoding: DecisionPayload(text: required(text)))
        case .actionItem(let title, let owner, let deadline):
            return try DraftArtifact(kind: .actionItem, encoding: ActionItemPayload(
                title: required(title), owner: optional(owner), deadline: optional(deadline)))
        }
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
            // The pre-network existing-artifacts check is insufficient across
            // awaits. Refuse a second generation at the transaction boundary.
            guard try ArtifactRecord.filter(Column("meetingID") == meetingID).fetchCount(db) == 0 else {
                throw ArtifactStoreError.existingArtifacts
            }
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
    public func setStatus(
        _ status: ArtifactStatus,
        id: ArtifactRecord.ID,
        expectedRevision: Int? = nil
    ) throws {
        try database.purgeMigrationSnapshot()
        try database.dbWriter.write { db in
            if let expectedRevision {
                _ = try Self.checkedRecord(db, id: id, expectedRevision: expectedRevision)
            }
            try db.execute(
                sql: "UPDATE artifacts SET status = ? WHERE id = ?",
                arguments: [status.rawValue, id]
            )
        }
    }

    /// Changes the payload and its FTS text in the same transaction. A content
    /// correction needs fresh review but does not implicitly reopen a task.
    @discardableResult
    public func edit(
        id: ArtifactRecord.ID,
        expectedRevision: Int,
        content: ArtifactEdit,
        at date: Date = Date()
    ) throws -> ArtifactRecord {
        let draft = try content.draft()
        try database.purgeMigrationSnapshot()
        return try database.dbWriter.write { db in
            let record = try Self.checkedRecord(db, id: id, expectedRevision: expectedRevision)
            guard record.kind == draft.kind.rawValue else { throw ArtifactStoreError.kindMismatch }
            guard record.payload != draft.payload else { return record }
            try db.execute(sql: """
                UPDATE artifacts SET payload = ?, searchText = ?, revision = revision + 1,
                    editedAt = ?, status = ? WHERE id = ?
                """, arguments: [draft.payload,
                    ArtifactSearchText.derive(kind: record.kind, payload: draft.payload),
                    date, ArtifactStatus.draft.rawValue, id])
            return try ArtifactRecord.fetchOne(db, id: id)!
        }
    }

    @discardableResult
    public func setCompletion(
        _ complete: Bool,
        id: ArtifactRecord.ID,
        expectedRevision: Int,
        at date: Date = Date()
    ) throws -> ArtifactRecord {
        try database.purgeMigrationSnapshot()
        return try database.dbWriter.write { db in
            let record = try Self.checkedRecord(db, id: id, expectedRevision: expectedRevision)
            guard record.artifactKind == .actionItem else { throw ArtifactStoreError.notAnActionItem }
            guard record.isComplete != complete else { return record }
            try db.execute(sql: "UPDATE artifacts SET completedAt = ? WHERE id = ?",
                           arguments: [complete ? date : nil, id])
            return try ArtifactRecord.fetchOne(db, id: id)!
        }
    }

    private static func checkedRecord(
        _ db: Database, id: UUID, expectedRevision: Int
    ) throws -> ArtifactRecord {
        guard let record = try ArtifactRecord.fetchOne(db, id: id) else {
            throw ArtifactStoreError.notFound
        }
        guard record.revision == expectedRevision else { throw ArtifactStoreError.revisionConflict }
        return record
    }
}
