import Foundation
import GRDB

public enum MeetingExportError: Error, Equatable, Sendable {
    case meetingNotFound
    case meetingNotCompleted
    case ephemeralMeeting
    case unsupportedArtifact
    case invalidDestination
}

public enum MeetingExportFormat: String, CaseIterable, Sendable {
    case markdown
    case text
    case json

    public var fileExtension: String {
        switch self { case .markdown: "md"; case .text: "txt"; case .json: "json" }
    }
}

public enum MeetingExportSelection: String, Codable, CaseIterable, Sendable {
    case all
    case transcript
    case summary
    case actionItems
}

/// An explicit allowlist, rather than encoding database records. Export v1
/// contains human-readable meeting data and stable source identities, never
/// settings, usage accounting, private diagnostics, or speaker embeddings.
public struct MeetingExportSnapshot: Codable, Equatable, Sendable {
    public struct Meeting: Codable, Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let startedAt: Date
        public let endedAt: Date
        public let status: String
    }

    public struct Speaker: Codable, Equatable, Sendable {
        public let id: UUID
        public let label: String
    }

    public struct Passage: Codable, Equatable, Sendable {
        public let id: UUID
        public let source: String
        public let speakerID: UUID?
        public let speakerLabel: String
        public let startSeconds: Double
        public let endSeconds: Double
        public let text: String
    }

    public struct Artifact: Codable, Equatable, Sendable {
        public let id: UUID
        public let kind: String
        public let text: String?
        public let title: String?
        public let owner: String?
        public let deadline: String?
        public let reviewStatus: String
        public let revision: Int
        public let createdAt: Date
        public let editedAt: Date?
        public let completedAt: Date?

        fileprivate init(_ row: ArtifactRecord) throws {
            id = row.id
            kind = row.kind
            reviewStatus = row.status
            revision = row.revision
            createdAt = row.createdAt
            editedAt = row.editedAt
            completedAt = row.completedAt
            switch row.artifactKind {
            case .summary:
                guard let payload = row.payload(as: SummaryPayload.self) else {
                    throw MeetingExportError.unsupportedArtifact
                }
                text = payload.text; title = nil; owner = nil; deadline = nil
            case .decision:
                guard let payload = row.payload(as: DecisionPayload.self) else {
                    throw MeetingExportError.unsupportedArtifact
                }
                text = payload.text; title = nil; owner = nil; deadline = nil
            case .actionItem:
                guard let payload = row.payload(as: ActionItemPayload.self) else {
                    throw MeetingExportError.unsupportedArtifact
                }
                text = nil; title = payload.title; owner = payload.owner; deadline = payload.deadline
            case nil:
                // Do not leak arbitrary JSON from an unknown future kind or
                // silently omit part of an explicitly complete export.
                throw MeetingExportError.unsupportedArtifact
            }
        }
    }

    public let schemaVersion: Int
    public let exportedAt: Date
    public let selection: MeetingExportSelection
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let transcript: [Passage]
    public let artifacts: [Artifact]

    public func data(format: MeetingExportFormat) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(self)
        case .markdown, .text:
            return Data(render(markdown: format == .markdown).utf8)
        }
    }

    /// Stable file name without meeting text or file-system metacharacters.
    public func suggestedFileName(format: MeetingExportFormat) -> String {
        "macapy-\(meeting.id.uuidString.lowercased()).\(format.fileExtension)"
    }

    private func render(markdown: Bool) -> String {
        func content(_ value: String) -> String {
            let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            guard markdown else { return normalized }
            // Escape inline syntax and raw HTML. Each line is escaped so
            // user content cannot turn into headings, lists, or remote images.
            let specials = Set("\\`*_{}[]()#+-.!|>")
            return normalized.reduce(into: "") { result, character in
                switch character {
                case "&": result += "&amp;"
                case "<": result += "&lt;"
                case ">": result += "&gt;"
                default:
                    if specials.contains(character) { result.append("\\") }
                    result.append(character)
                }
            }
        }
        func heading(_ value: String) -> String { markdown ? "## \(value)" : value.uppercased() }
        let date = ISO8601DateFormatter()
        var lines = [markdown ? "# \(content(meeting.title))" : meeting.title,
                     "", "Started: \(date.string(from: meeting.startedAt))",
                     "Ended: \(date.string(from: meeting.endedAt))", ""]
        for (kind, title) in [("summary", "Summary"), ("decision", "Decisions"), ("action_item", "Action items")] {
            let rows = artifacts.filter { $0.kind == kind }
            guard !rows.isEmpty else { continue }
            lines += [heading(title), ""]
            for row in rows {
                let value = content(row.text ?? row.title ?? "")
                if kind == "action_item" {
                    lines.append("- [\(row.completedAt == nil ? " " : "x")] \(value)")
                    if let owner = row.owner { lines.append("  Owner: \(content(owner))") }
                    if let deadline = row.deadline { lines.append("  Deadline: \(content(deadline))") }
                    lines.append("  Review: \(content(row.reviewStatus))")
                } else {
                    lines += [value, "Review: \(content(row.reviewStatus))"]
                }
                if row.editedAt != nil { lines.append("Edited locally · revision \(row.revision)") }
                lines.append("")
            }
        }
        if selection == .all || selection == .transcript {
            lines += [heading("Transcript"), ""]
            if transcript.isEmpty { lines += ["No transcript was captured.", ""] }
            for passage in transcript {
                lines += ["[\(Self.timestamp(passage.startSeconds))–\(Self.timestamp(passage.endSeconds))] \(content(passage.speakerLabel))",
                          content(passage.text), ""]
            }
        }
        lines.append("Exported from macapy. Audio is never stored; playback is unavailable.")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 2) else { return "--:--" }
        let value = Int(seconds.rounded(.down))
        if value >= 3_600 {
            return String(format: "%02d:%02d:%02d", value / 3_600, (value / 60) % 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// Snapshot all selected content in one SQLite read transaction. Separate
/// asynchronous store reads could mix a renamed meeting with stale artifacts.
public actor MeetingExportStore {
    private let database: MacapyDatabase

    public init(database: MacapyDatabase) { self.database = database }

    public func snapshot(
        meetingID: UUID,
        selection: MeetingExportSelection = .all,
        exportedAt: Date = Date()
    ) throws -> MeetingExportSnapshot {
        try Task.checkCancellation()
        return try database.dbWriter.read { db in
            guard let row = try MeetingRecord.fetchOne(db, id: meetingID) else {
                throw MeetingExportError.meetingNotFound
            }
            guard !row.ephemeral else { throw MeetingExportError.ephemeralMeeting }
            guard row.hasEnded, let endedAt = row.endedAt else {
                throw MeetingExportError.meetingNotCompleted
            }
            let includeTranscript = selection == .all || selection == .transcript
            let speakers = includeTranscript ? try SpeakerRecord.filter(Column("meetingID") == meetingID)
                .order(Column("label"), Column("id")).fetchAll(db) : []
            let labels = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.label) })
            let segments = includeTranscript ? try SegmentRecord.filter(Column("meetingID") == meetingID)
                .order(Column("tStart"), Column.rowID).fetchAll(db) : []
            let records = selection == .transcript ? [] : try ArtifactRecord
                .filter(Column("meetingID") == meetingID)
                .order(Column("createdAt"), Column.rowID).fetchAll(db)
            let filtered = records.filter { record in
                switch selection {
                case .all: true
                case .transcript: false
                case .summary: record.artifactKind == .summary
                case .actionItems: record.artifactKind == .actionItem
                }
            }
            return try MeetingExportSnapshot(
                schemaVersion: 1, exportedAt: exportedAt, selection: selection,
                meeting: .init(id: row.id, title: row.title, startedAt: row.startedAt,
                               endedAt: endedAt, status: row.status),
                speakers: speakers.map { .init(id: $0.id, label: $0.label) },
                transcript: segments.map {
                    .init(id: $0.id, source: $0.source, speakerID: $0.speakerId,
                          speakerLabel: $0.speakerId.flatMap { labels[$0] } ?? ($0.source == "us" ? "You" : "Them"),
                          startSeconds: $0.tStart, endSeconds: $0.tEnd, text: $0.text)
                }, artifacts: filtered.map { try .init($0) })
        }
    }
}

/// Local, atomic file replacement. The UI owns destination selection and
/// overwrite confirmation. Cancellation before this short filesystem boundary
/// leaves an existing destination untouched; once replacement starts it drains.
public enum MeetingExportWriter {
    public static func write(_ data: Data, to destination: URL) throws {
        try Task.checkCancellation()
        guard destination.isFileURL else { throw MeetingExportError.invalidDestination }
        try data.write(to: destination, options: .atomic)
    }
}
