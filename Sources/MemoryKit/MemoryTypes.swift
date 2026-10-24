import Foundation

public enum SourceKind: String, Codable, Sendable { case segment, artifact, documentChunk }

/// Local identities and character bounds, never model-authored URLs. Bounds
/// address the source's text in Swift Characters, with an exclusive end.
public struct SourceReference: Codable, Hashable, Sendable {
    public let kind: SourceKind
    public let sourceID: UUID
    public let revision: Int
    public let meetingID: UUID?
    public let documentID: UUID?
    public let pageNumber: Int?
    public let startCharacter: Int
    public let endCharacter: Int

    public init(kind: SourceKind, sourceID: UUID, revision: Int, meetingID: UUID? = nil,
                documentID: UUID? = nil, pageNumber: Int? = nil, startCharacter: Int, endCharacter: Int) {
        self.kind = kind; self.sourceID = sourceID; self.revision = revision
        self.meetingID = meetingID; self.documentID = documentID; self.pageNumber = pageNumber
        self.startCharacter = startCharacter; self.endCharacter = endCharacter
    }
}

public enum MemoryEntityKind: String, Codable, Sendable { case person, project }
public struct MemoryEntity: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: MemoryEntityKind
    public let name: String
    public let aliases: [String]
    public init(id: UUID, kind: MemoryEntityKind, name: String, aliases: [String]) {
        self.id = id; self.kind = kind; self.name = name; self.aliases = aliases
    }
}

public enum MemoryFactKind: String, Codable, Sendable { case person, project, decision, commitment }
public enum MemoryReviewStatus: String, Codable, Sendable { case pending, approved, rejected, superseded }
public struct MemoryCandidate: Sendable {
    public let kind: MemoryFactKind
    public let text: String
    public let statedAt: Date
    public let sources: [SourceReference]
    public let entityIDs: [UUID]
    public init(kind: MemoryFactKind, text: String, statedAt: Date, sources: [SourceReference], entityIDs: [UUID] = []) {
        self.kind = kind; self.text = text; self.statedAt = statedAt; self.sources = sources; self.entityIDs = entityIDs
    }
}

public struct MemoryFact: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let kind: MemoryFactKind
    public let text: String
    public let status: MemoryReviewStatus
    public let revision: Int
    public let statedAt: Date
    public let editedAt: Date?
    public let completedAt: Date?
    public let sources: [SourceReference]
    public let entityIDs: [UUID]
    public init(id: UUID, meetingID: UUID, kind: MemoryFactKind, text: String, status: MemoryReviewStatus,
                revision: Int, statedAt: Date, editedAt: Date?, completedAt: Date?,
                sources: [SourceReference], entityIDs: [UUID]) {
        self.id = id; self.meetingID = meetingID; self.kind = kind; self.text = text; self.status = status
        self.revision = revision; self.statedAt = statedAt; self.editedAt = editedAt; self.completedAt = completedAt
        self.sources = sources; self.entityIDs = entityIDs
    }
}

public struct RetrievalRequest: Sendable {
    public let query: String
    /// nil means all eligible sources; an empty set means no sources.
    public let allowedMeetingIDs: Set<UUID>?
    public let allowedDocumentIDs: Set<UUID>?
    public let entityIDs: Set<UUID>?
    public let asOf: Date?
    public let maxExcerpts: Int
    public let maxCharacters: Int
    public init(query: String, allowedMeetingIDs: Set<UUID>? = nil, allowedDocumentIDs: Set<UUID>? = nil,
                entityIDs: Set<UUID>? = nil, asOf: Date? = nil, maxExcerpts: Int = 8, maxCharacters: Int = 8_000) {
        self.query = String(query.prefix(2_000)); self.allowedMeetingIDs = allowedMeetingIDs
        self.allowedDocumentIDs = allowedDocumentIDs; self.entityIDs = entityIDs; self.asOf = asOf
        self.maxExcerpts = max(0, min(8, maxExcerpts)); self.maxCharacters = max(0, min(8_000, maxCharacters))
    }
}

public struct RetrievedExcerpt: Codable, Equatable, Sendable, Identifiable {
    public var id: String { citationID }
    public let citationID: String
    public let title: String
    public let text: String
    public let statedAt: Date
    public let factID: UUID?
    public let factRevision: Int?
    public let sources: [SourceReference]
    public init(citationID: String, title: String, text: String, statedAt: Date,
                factID: UUID? = nil, factRevision: Int? = nil, sources: [SourceReference]) {
        self.citationID = citationID; self.title = title; self.text = text; self.statedAt = statedAt
        self.factID = factID; self.factRevision = factRevision; self.sources = sources
    }
}

public struct ContextBundle: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case lexical }
    public let mode: Mode
    public let excerpts: [RetrievedExcerpt]
    public init(excerpts: [RetrievedExcerpt]) { mode = .lexical; self.excerpts = excerpts }
    public var isEmpty: Bool { excerpts.isEmpty }
    /// Only citations from the provided context are accepted by answer code.
    public func containsOnlyValidCitations(_ ids: [String]) -> Bool {
        let allowed = Set(excerpts.map(\.citationID))
        return ids.allSatisfy { allowed.contains($0) }
    }
}

public protocol ContextRetrieving: Sendable {
    func retrieve(_ request: RetrievalRequest) async throws -> ContextBundle
    /// Call again before presenting any generated answer. A held snapshot is
    /// not permission to display sources deleted or edited during generation.
    func validate(_ bundle: ContextBundle, for request: RetrievalRequest) async throws -> Bool
}

public enum MemoryStoreError: Error, Equatable, Sendable {
    case notFound, ineligibleMeeting, notOptedIn, invalidContent, invalidSource
    case revisionConflict, aliasCollision, incompatibleEntity, capacityExceeded, indexingPaused
}
