import Foundation
import PersistKit
import ProviderKit

/// One line of transcript as the extractor sees it — speaker label + text,
/// already decoupled from `AudioSource` so diarized labels (M2 slice 4) slot
/// in without touching the extraction layer.
public struct TranscriptLine: Sendable, Equatable {
    public var speaker: String
    public var text: String

    public init(speaker: String, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// What one extraction call returns (SPEC §6.4: one structured-output pass →
/// summary, decisions, action items with owner/deadline where stated).
public struct MeetingExtraction: Codable, Sendable, Equatable {
    public struct ActionItem: Codable, Sendable, Equatable {
        public var title: String
        /// Exactly as stated in the meeting, or `nil` when nobody was named.
        public var owner: String?
        /// Exactly as stated, or `nil` — never a guessed date.
        public var deadline: String?

        public init(title: String, owner: String?, deadline: String?) {
            self.title = title
            self.owner = owner
            self.deadline = deadline
        }
    }

    public var summary: String
    public var decisions: [String]
    public var actionItems: [ActionItem]

    public init(summary: String, decisions: [String], actionItems: [ActionItem]) {
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
    }

    enum CodingKeys: String, CodingKey {
        case summary
        case decisions
        case actionItems = "action_items"
    }
}

extension MeetingExtraction {
    /// The strict response-format contract every extraction call carries.
    /// Optional-as-stated fields are `["string", "null"]` because strict mode
    /// requires every property listed in `required` — absence is expressed as
    /// an explicit JSON null, which decodes to `nil` above.
    ///
    /// `try!` is safe: the literal serializes by construction, and every
    /// request-building test would trip a failure immediately.
    static let responseFormat = ResponseFormat(
        name: "meeting_extraction",
        schema: try! JSONSchema([
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "decisions": [
                    "type": "array",
                    "items": ["type": "string"],
                ],
                "action_items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "owner": ["type": ["string", "null"]],
                            "deadline": ["type": ["string", "null"]],
                        ],
                        "required": ["title", "owner", "deadline"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["summary", "decisions", "action_items"],
            "additionalProperties": false,
        ])
    )

    /// Rows-in-waiting for `ArtifactStore.insertDrafts`. Blank strings the
    /// model shouldn't produce (but may) are dropped or normalized to `nil`
    /// here, so no empty artifact ever reaches review.
    func drafts() throws -> [DraftArtifact] {
        var drafts: [DraftArtifact] = []
        let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryText.isEmpty {
            drafts.append(try DraftArtifact(kind: .summary, encoding: SummaryPayload(text: summaryText)))
        }
        for decision in decisions {
            let text = decision.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            drafts.append(try DraftArtifact(kind: .decision, encoding: DecisionPayload(text: text)))
        }
        for item in actionItems {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            drafts.append(try DraftArtifact(
                kind: .actionItem,
                encoding: ActionItemPayload(
                    title: title,
                    owner: Self.normalized(item.owner),
                    deadline: Self.normalized(item.deadline)
                )))
        }
        return drafts
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
