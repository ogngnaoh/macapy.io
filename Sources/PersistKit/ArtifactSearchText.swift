import Foundation

/// Derives the `artifacts.searchText` column from a row's kind + payload
/// (slice-05 doc decision 2): the one pure function both `ArtifactStore`
/// (on insert) and migration `v5-search` (backfill) call, so live rows and
/// legacy rows can never disagree on what an artifact's searchable text is.
/// Raw payload JSON is never indexed — its keys ("title", "owner") would
/// match every row.
public enum ArtifactSearchText {
    /// Searchable text for one artifact row. Unknown kinds and payloads that
    /// don't decode yield "" — an unsearchable artifact, never a crash or a
    /// JSON-noise index entry.
    public static func derive(kind: String, payload: String) -> String {
        func decode<T: Decodable>(_ type: T.Type) -> T? {
            try? JSONDecoder().decode(type, from: Data(payload.utf8))
        }
        switch ArtifactKind(rawValue: kind) {
        case .summary:
            return decode(SummaryPayload.self)?.text ?? ""
        case .decision:
            return decode(DecisionPayload.self)?.text ?? ""
        case .actionItem:
            guard let item = decode(ActionItemPayload.self) else { return "" }
            return [item.title, item.owner, item.deadline]
                .compactMap(\.self)
                .joined(separator: " ")
        case nil:
            return ""
        }
    }
}
