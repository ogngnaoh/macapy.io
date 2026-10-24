import PersistKit
import SwiftUI

// History controls share the native editorial foundations: square fields,
// legible search context, restrained selection and explicit keyboard focus.

// MARK: - Search field

/// A square search field with a visible focus ring. Esc clears; ⌘F focuses
/// through the caller-owned binding. Typed queries retain sentence case.
struct SearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
            TextField("search meetings", text: $text)
                .textFieldStyle(.plain)
                .font(UIType.body)
                .foregroundStyle(DesignTokens.text)
                .focused(focus)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                    focus.wrappedValue = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("clear search")
            }
        }
        .padding(.horizontal, DesignTokens.Space.s2)
        .padding(.vertical, 5)
        .frame(minWidth: 220, minHeight: 30)
        .background(DesignTokens.surface)
        .overlay(Rectangle().stroke(
            focus.wrappedValue ? DesignTokens.accent : DesignTokens.hairlineStrong,
            lineWidth: focus.wrappedValue ? 2 : 1
        ))
        .accessibilityLabel("search meetings")
    }
}

// MARK: - Rows

/// `.row` — history list row and the search results' Meetings group: title,
/// secondary sub line, mono trailing meta.
struct HistoryRow: View {
    let title: String
    let subtitle: String
    let meta: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                    Text(title)
                        .font(UIType.compactReading)
                        .foregroundStyle(DesignTokens.text)
                        .lineLimit(2)
                    HStack {
                    Text(subtitle)
                        .font(UIType.small)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(1)
                Spacer(minLength: DesignTokens.Space.s1)
                Text(meta)
                    .font(UIType.small)
                    .foregroundStyle(DesignTokens.textTertiary)
                    }
            }
            .padding(.horizontal, DesignTokens.Space.s4)
            .padding(.vertical, DesignTokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? DesignTokens.surface : (isHovered ? DesignTokens.sunken : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(DesignTokens.selection).frame(width: 3) }
        }
        .overlay(alignment: .bottom) { Divider().overlay(DesignTokens.hairline) }
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

/// `.passage` — one transcript-passage or artifact search hit: small
/// semibold context line over the highlighted snippet.
struct PassageRow: View {
    let context: String
    let snippet: SearchSnippet
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(context)
                    .font(UIType.bodySemibold)
                    .foregroundStyle(DesignTokens.text)
                    .lineLimit(1)
                SnippetTextView(snippet: snippet)
            }
            .padding(.horizontal, DesignTokens.Space.s4)
            .padding(.vertical, DesignTokens.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? DesignTokens.sunken : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) { Divider().overlay(DesignTokens.hairline) }
    }
}

/// Snippet text with its FTS-matched tokens washed in `signalSoft` — the
/// mockup's `<mark>`. Ranges come from the tokenizer via `SearchSnippet`,
/// so highlighting can never disagree with what actually matched.
struct SnippetTextView: View {
    let snippet: SearchSnippet

    var body: some View {
        Text(Self.attributed(snippet))
            .font(UIType.compactReading)
            .foregroundStyle(DesignTokens.textSecondary)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
    }

    static func attributed(_ snippet: SearchSnippet) -> AttributedString {
        var attributed = AttributedString(snippet.text)
        let characterCount = attributed.characters.count
        for range in snippet.highlights {
            // Defensive bounds check; parse-produced ranges are always valid.
            guard range.lowerBound >= 0, range.upperBound <= characterCount else { continue }
            let start = attributed.index(attributed.startIndex, offsetByCharacters: range.lowerBound)
            let end = attributed.index(start, offsetByCharacters: range.count)
            attributed[start..<end].backgroundColor = DesignTokens.signalSoft
            attributed[start..<end].foregroundColor = DesignTokens.text
        }
        return attributed
    }
}

// MARK: - Section header (promoted from MeetingDetailView in slice 5)

/// A quiet section label, optional status chip, and timing readout.
/// Shared by the review pane and search result groups.
struct SectionHead: View {
    let title: String
    var chip: Chip?
    var draftedIn: Double?

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Text(title)
                .font(MachineType.label())
                .textCase(.lowercase)
                .foregroundStyle(DesignTokens.textSecondary)
            if let chip { chip }
            if let draftedIn {
                Spacer(minLength: DesignTokens.Space.s2)
                Text("drafted in \(Int(draftedIn.rounded()))s")
                    .font(MachineType.label())
                    .foregroundStyle(DesignTokens.textTertiary)
                    .accessibilityLabel("Drafted in \(Int(draftedIn.rounded())) seconds")
            }
        }
    }
}

// MARK: - Button styles

/// Shared primary control. Native keyboard focus remains available around
/// the flat neutral fill; disabled actions retain a readable visible label.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(UIType.bodySemibold)
            .foregroundStyle(isEnabled ? DesignTokens.textOnSelection : DesignTokens.textSecondary)
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background(isEnabled ? DesignTokens.selection.opacity(configuration.isPressed ? 0.8 : 1) : DesignTokens.sunken)
            .overlay(Rectangle().stroke(isEnabled ? DesignTokens.selection : DesignTokens.hairlineStrong))
            .contentShape(Rectangle())
    }
}

/// A quiet, square action that preserves the control's enabled state.
struct SubtleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(UIType.body)
            .foregroundStyle(isEnabled ? DesignTokens.text : DesignTokens.textTertiary)
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background(
                configuration.isPressed ? DesignTokens.sunken : DesignTokens.surface,
                in: Rectangle())
            .overlay(Rectangle().stroke(DesignTokens.hairlineStrong))
            .contentShape(Rectangle())
    }
}

/// An outlined destructive action; red reinforces the explicit label.
struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(UIType.body)
            .foregroundStyle(isEnabled ? DesignTokens.statusRejected : DesignTokens.textTertiary)
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background(
                configuration.isPressed ? DesignTokens.statusRejectedSurface : DesignTokens.surface,
                in: Rectangle())
            .overlay(
                Rectangle().stroke(DesignTokens.hairlineStrong)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Row copy

/// Pure text for history/search rows — formatted in one place so the list
/// and the search results can never phrase the same fact differently.
enum HistoryRowFormat {
    /// "Today · 47m · 3 speakers" (speakers omitted at zero; "in progress"
    /// while the meeting has no duration yet).
    static func summarySubtitle(
        _ summary: MeetingStore.MeetingSummary, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        var parts = [dateLabel(summary.startedAt, now: now, calendar: calendar)]
        if summary.status == MeetingRecord.interruptedStatus { parts.append("interrupted") }
        if let duration = summary.duration {
            parts.append(durationLabel(duration))
        } else if !summary.hasEnded {
            parts.append("in progress")
        }
        if summary.speakerCount > 0 {
            parts.append("\(summary.speakerCount) speaker\(summary.speakerCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    /// "4 items" / "1 item" / "—".
    static func itemsMeta(_ count: Int) -> String {
        count == 0 ? "—" : "\(count) item\(count == 1 ? "" : "s")"
    }

    /// "3 hits" / "1 hit".
    static func hitsMeta(_ count: Int) -> String {
        "\(count) hit\(count == 1 ? "" : "s")"
    }

    /// "matches in transcript and action items" — surfaces in fixed display
    /// order.
    static func surfacesLabel(_ surfaces: Set<SearchSurface>) -> String {
        let order: [(SearchSurface, String)] = [
            (.title, "title"), (.transcript, "transcript"), (.summary, "summary"),
            (.decision, "decisions"), (.actionItem, "action items"),
        ]
        let names = order.filter { surfaces.contains($0.0) }.map(\.1)
        switch names.count {
        case 0: return ""
        case 1: return "matches in \(names[0])"
        case 2: return "matches in \(names[0]) and \(names[1])"
        default:
            return "matches in \(names.dropLast().joined(separator: ", ")), and \(names.last!)"
        }
    }

    /// "Today" / "Yesterday" / "Jul 22" (with year once it differs).
    static func dateLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// "47m" / "1h 07m" / "<1m".
    static func durationLabel(_ duration: TimeInterval) -> String {
        let minutes = Int(duration / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    /// The detail toolbar's meta line: "Jul 24 · 47m 12s".
    static func detailMetaLine(
        startedAt: Date, endedAt: Date?, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        var parts = [dateLabel(startedAt, now: now, calendar: calendar)]
        if let endedAt {
            let seconds = max(0, Int(endedAt.timeIntervalSince(startedAt)))
            if seconds >= 3600 {
                parts.append("\(seconds / 3600)h \((seconds / 60) % 60)m \(seconds % 60)s")
            } else {
                parts.append("\(seconds / 60)m \(seconds % 60)s")
            }
        }
        return parts.joined(separator: " · ")
    }
}
