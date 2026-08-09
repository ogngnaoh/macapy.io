import Foundation
import GRDB

/// Where a search hit came from, at the granularity the History UI speaks:
/// "matches in transcript and action items" (slice-05 doc decision 3).
/// Artifact hits carry their kind as the surface; title and transcript are
/// their own.
public enum SearchSurface: String, Sendable, CaseIterable {
    case title
    case transcript
    case summary
    case decision
    case actionItem = "action_item"

    init?(artifactKind: String) {
        guard let kind = ArtifactKind(rawValue: artifactKind) else { return nil }
        switch kind {
        case .summary: self = .summary
        case .decision: self = .decision
        case .actionItem: self = .actionItem
        }
    }
}

/// One FTS5 `snippet()` result, parsed from its ASCII-separator sentinels
/// (slice-05 doc decision 3) into plain text plus highlight ranges. Ranges
/// are `Character` offsets into `text`; each covers one token the tokenizer
/// matched — tokenizer-consistent highlighting, never a hand-rolled substring
/// scan that would diverge on case or diacritics.
public struct SearchSnippet: Sendable, Equatable {
    public var text: String
    public var highlights: [Range<Int>]

    public init(text: String, highlights: [Range<Int>]) {
        self.text = text
        self.highlights = highlights
    }

    /// The sentinels `snippet()` wraps matched tokens in: ASCII unit/record
    /// separators — characters that cannot survive into transcript or
    /// artifact text through any input path this app has.
    static let highlightOpen: Character = "\u{1F}"
    static let highlightClose: Character = "\u{1E}"

    /// Parses raw `snippet()` output. An unpaired open sentinel highlights
    /// through the end of text; a stray close sentinel is dropped —
    /// defensive only, `snippet()` always emits balanced pairs.
    static func parse(_ raw: String) -> SearchSnippet {
        var text = ""
        var highlights: [Range<Int>] = []
        var openedAt: Int?
        var count = 0
        for character in raw {
            switch character {
            case highlightOpen:
                openedAt = count
            case highlightClose:
                if let start = openedAt, start < count {
                    highlights.append(start..<count)
                }
                openedAt = nil
            default:
                text.append(character)
                count += 1
            }
        }
        if let start = openedAt, start < count {
            highlights.append(start..<count)
        }
        return SearchSnippet(text: text, highlights: highlights)
    }
}

/// The Meetings group: one row per meeting with hits anywhere, aggregated
/// across surfaces in Swift (slice-05 doc decision 3) — "3 hits · matches in
/// transcript and action items".
public struct MeetingSearchHit: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var hitCount: Int
    public var surfaces: Set<SearchSurface>
}

/// One matching transcript segment, ready for the passage row + deep link
/// (`<meeting title> · mm:ss`, tap → scroll-to-segment).
public struct PassageSearchHit: Sendable, Equatable, Identifiable {
    public var id: UUID { segmentID }
    public var segmentID: UUID
    public var meetingID: UUID
    public var meetingTitle: String
    public var tStart: TimeInterval
    public var snippet: SearchSnippet
}

/// One matching artifact, with its kind for the group's surface labels.
public struct ArtifactSearchHit: Sendable, Equatable, Identifiable {
    public var id: UUID { artifactID }
    public var artifactID: UUID
    public var meetingID: UUID
    public var meetingTitle: String
    public var kind: String
    public var snippet: SearchSnippet
}

/// The three grouped result sets the History search UI renders (slice-05 doc
/// decision 4). `meetings` always carries *exact* per-meeting hit counts;
/// `passages`/`artifacts` are capped at the store's row limit for display.
public struct SearchResults: Sendable, Equatable {
    public var meetings: [MeetingSearchHit]
    public var passages: [PassageSearchHit]
    public var artifacts: [ArtifactSearchHit]

    public static let empty = SearchResults(meetings: [], passages: [], artifacts: [])

    public var isEmpty: Bool {
        meetings.isEmpty && passages.isEmpty && artifacts.isEmpty
    }
}

/// Read-only search over the three FTS5 tables (schema v5), actor-isolated
/// like the other stores, over the same database. One `read` transaction per
/// query, so the three groups are a consistent snapshot.
public actor SearchStore {
    private let database: MacapyDatabase
    /// Display cap for the passage/artifact groups. The Meetings group's
    /// counts stay exact regardless — nothing is silently truncated, the UI
    /// says "N hits" from the full count.
    private let rowLimit: Int

    public init(database: MacapyDatabase, rowLimit: Int = 100) {
        self.database = database
        self.rowLimit = rowLimit
    }

    /// Searches titles, transcripts, and artifacts. Sanitization is
    /// `FTS5Pattern(matchingAllPrefixesIn:)` (slice-05 doc decision 4):
    /// every token becomes a prefix match, multiple tokens AND together, and
    /// hostile input (quotes, operators, emoji, whitespace) either tokenizes
    /// to a valid pattern or yields `.empty` — it can never throw.
    ///
    /// Ordering (pinned by check 2): passages and artifacts by `bm25()`
    /// ascending (best first), tiebreak rowid ascending (insertion order);
    /// meetings by best rank across all their hits, tiebreak `startedAt`
    /// descending, then id.
    public func search(matching query: String) throws -> SearchResults {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else {
            return .empty
        }
        let open = String(SearchSnippet.highlightOpen)
        let close = String(SearchSnippet.highlightClose)

        return try database.dbWriter.read { db in
            // Title hits: at most one per meeting (title is one field).
            struct TitleHit: Decodable, FetchableRecord {
                var meetingID: UUID
                var title: String
                var startedAt: Date
                var rank: Double
            }
            let titleHits = try TitleHit.fetchAll(
                db,
                sql: """
                    SELECT m.id AS meetingID, m.title, m.startedAt, bm25(meetings_fts) AS rank
                    FROM meetings_fts
                    JOIN meetings m ON m.rowid = meetings_fts.rowid
                    WHERE meetings_fts MATCH :pattern
                    """,
                arguments: ["pattern": pattern.rawPattern])

            struct PassageRow: Decodable, FetchableRecord {
                var segmentID: UUID
                var meetingID: UUID
                var meetingTitle: String
                var tStart: Double
                var snip: String
            }
            let passages = try PassageRow.fetchAll(
                db,
                sql: """
                    SELECT s.id AS segmentID, s.meetingID, m.title AS meetingTitle, s.tStart,
                           snippet(segments_fts, 0, :open, :close, '…', 12) AS snip
                    FROM segments_fts
                    JOIN segments s ON s.rowid = segments_fts.rowid
                    JOIN meetings m ON m.id = s.meetingID
                    WHERE segments_fts MATCH :pattern
                    ORDER BY bm25(segments_fts), segments_fts.rowid
                    LIMIT :limit
                    """,
                arguments: ["open": open, "close": close, "pattern": pattern.rawPattern, "limit": rowLimit]
            ).map {
                PassageSearchHit(
                    segmentID: $0.segmentID, meetingID: $0.meetingID,
                    meetingTitle: $0.meetingTitle, tStart: $0.tStart,
                    snippet: SearchSnippet.parse($0.snip))
            }

            struct ArtifactRow: Decodable, FetchableRecord {
                var artifactID: UUID
                var meetingID: UUID
                var meetingTitle: String
                var kind: String
                var snip: String
            }
            let artifacts = try ArtifactRow.fetchAll(
                db,
                sql: """
                    SELECT a.id AS artifactID, a.meetingID, m.title AS meetingTitle, a.kind,
                           snippet(artifacts_fts, 0, :open, :close, '…', 12) AS snip
                    FROM artifacts_fts
                    JOIN artifacts a ON a.rowid = artifacts_fts.rowid
                    JOIN meetings m ON m.id = a.meetingID
                    WHERE artifacts_fts MATCH :pattern
                    ORDER BY bm25(artifacts_fts), artifacts_fts.rowid
                    LIMIT :limit
                    """,
                arguments: ["open": open, "close": close, "pattern": pattern.rawPattern, "limit": rowLimit]
            ).map {
                ArtifactSearchHit(
                    artifactID: $0.artifactID, meetingID: $0.meetingID,
                    meetingTitle: $0.meetingTitle, kind: $0.kind,
                    snippet: SearchSnippet.parse($0.snip))
            }

            // Exact per-meeting counts for the aggregated Meetings group —
            // grouped SQL counts, independent of the display caps above.
            struct SegmentCount: Decodable, FetchableRecord {
                var meetingID: UUID
                var title: String
                var startedAt: Date
                var hits: Int
                var best: Double
            }
            let segmentCounts = try SegmentCount.fetchAll(
                db,
                sql: """
                    WITH ranked AS MATERIALIZED (
                        SELECT s.meetingID AS meetingID, m.title AS title,
                               m.startedAt AS startedAt, bm25(segments_fts) AS rank
                        FROM segments_fts
                        JOIN segments s ON s.rowid = segments_fts.rowid
                        JOIN meetings m ON m.id = s.meetingID
                        WHERE segments_fts MATCH :pattern
                    )
                    SELECT meetingID, title, startedAt, count(*) AS hits, min(rank) AS best
                    FROM ranked
                    GROUP BY meetingID
                    """,
                arguments: ["pattern": pattern.rawPattern])

            struct ArtifactCount: Decodable, FetchableRecord {
                var meetingID: UUID
                var title: String
                var startedAt: Date
                var kind: String
                var hits: Int
                var best: Double
            }
            let artifactCounts = try ArtifactCount.fetchAll(
                db,
                sql: """
                    WITH ranked AS MATERIALIZED (
                        SELECT a.meetingID AS meetingID, m.title AS title,
                               m.startedAt AS startedAt, a.kind AS kind,
                               bm25(artifacts_fts) AS rank
                        FROM artifacts_fts
                        JOIN artifacts a ON a.rowid = artifacts_fts.rowid
                        JOIN meetings m ON m.id = a.meetingID
                        WHERE artifacts_fts MATCH :pattern
                    )
                    SELECT meetingID, title, startedAt, kind, count(*) AS hits, min(rank) AS best
                    FROM ranked
                    GROUP BY meetingID, kind
                    """,
                arguments: ["pattern": pattern.rawPattern])

            // Swift-side aggregation (decision 3): union the surfaces.
            struct Aggregate {
                var title: String
                var startedAt: Date
                var hitCount = 0
                var surfaces: Set<SearchSurface> = []
                var best: Double = .greatestFiniteMagnitude
            }
            var aggregates: [UUID: Aggregate] = [:]
            func fold(
                _ meetingID: UUID, title: String, startedAt: Date,
                hits: Int, surface: SearchSurface?, rank: Double
            ) {
                var aggregate = aggregates[meetingID] ?? Aggregate(title: title, startedAt: startedAt)
                aggregate.hitCount += hits
                if let surface {
                    aggregate.surfaces.insert(surface)
                }
                aggregate.best = min(aggregate.best, rank)
                aggregates[meetingID] = aggregate
            }
            for hit in titleHits {
                fold(hit.meetingID, title: hit.title, startedAt: hit.startedAt,
                     hits: 1, surface: .title, rank: hit.rank)
            }
            for count in segmentCounts {
                fold(count.meetingID, title: count.title, startedAt: count.startedAt,
                     hits: count.hits, surface: .transcript, rank: count.best)
            }
            for count in artifactCounts {
                fold(count.meetingID, title: count.title, startedAt: count.startedAt,
                     hits: count.hits, surface: SearchSurface(artifactKind: count.kind),
                     rank: count.best)
            }
            let meetings = aggregates
                .map { id, aggregate in
                    MeetingSearchHit(
                        id: id, title: aggregate.title, startedAt: aggregate.startedAt,
                        hitCount: aggregate.hitCount, surfaces: aggregate.surfaces)
                }
                .sorted { lhs, rhs in
                    let lhsBest = aggregates[lhs.id]!.best
                    let rhsBest = aggregates[rhs.id]!.best
                    if lhsBest != rhsBest { return lhsBest < rhsBest }
                    if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }

            return SearchResults(meetings: meetings, passages: passages, artifacts: artifacts)
        }
    }
}
