import PersistKit
import SwiftUI
import TranscribeKit

/// History (design/04-history.html): summary rows with duration · speaker
/// count · artifact count, and — the moment the search field has text — the
/// three grouped result sections (Meetings / Transcript passages /
/// Artifacts) with passage deep-links into meeting detail. One
/// `NavigationSplitView`; the mockups' two-window presentation is
/// presentation, not structure (slice-05 doc decision 6).
struct HistoryView: View {
    let model: HistorySearchModel
    let store: MeetingStore
    /// Builds the artifacts-pane model for a selected meeting (slice 3).
    /// Defaults to none so previews and shell-less constructions still show
    /// transcripts; the app's scene graph passes the coordinator's factory.
    var makeDetailModel: @MainActor (MeetingRecord) -> MeetingDetailModel? = { _ in nil }

    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("History")
                .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SearchField(
                    text: Binding(get: { model.query }, set: { model.query = $0 }),
                    focus: $searchFocused
                )
            }
        }
        .background(
            // ⌘F focuses the search field (slice-05 doc decision 6); an
            // invisible button carries the shortcut.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .frame(minWidth: 720, minHeight: 400)
        .task { await model.load() }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.isSearching {
                    searchResults
                } else {
                    summaryRows
                }
            }
        }
        .background(DesignTokens.bg)
        .overlay { sidebarOverlay }
    }

    @ViewBuilder
    private var summaryRows: some View {
        ForEach(model.summaries) { summary in
            HistoryRow(
                title: summary.title,
                subtitle: HistoryRowFormat.summarySubtitle(summary),
                meta: HistoryRowFormat.itemsMeta(summary.artifactCount),
                isSelected: model.selectedMeetingID == summary.id,
                action: { model.select(meeting: summary.id) }
            )
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = model.results
        if !results.meetings.isEmpty {
            groupHead("Meetings · \(results.meetings.count)")
            ForEach(results.meetings) { hit in
                HistoryRow(
                    title: hit.title,
                    subtitle: searchSubtitle(for: hit),
                    meta: HistoryRowFormat.hitsMeta(hit.hitCount),
                    isSelected: model.selectedMeetingID == hit.id,
                    action: { model.select(meeting: hit.id) }
                )
            }
        }
        if !results.passages.isEmpty {
            groupHead("Transcript passages · \(results.passages.count)")
            ForEach(results.passages) { passage in
                PassageRow(
                    context: "\(passage.meetingTitle) · \(TranscriptRows.timestampLabel(tStart: passage.tStart))",
                    snippet: passage.snippet,
                    action: { model.select(passage: passage) }
                )
            }
        }
        if !results.artifacts.isEmpty {
            groupHead("Artifacts · \(results.artifacts.count)")
            ForEach(results.artifacts) { artifact in
                PassageRow(
                    context: artifactContext(for: artifact),
                    snippet: artifact.snippet,
                    action: { model.select(artifact: artifact) }
                )
            }
        }
    }

    private func groupHead(_ title: String) -> some View {
        SectionHead(title: title)
            .padding(.horizontal, DesignTokens.Space.s4)
            .padding(.top, DesignTokens.Space.s2)
            .padding(.bottom, DesignTokens.Space.s1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func searchSubtitle(for hit: MeetingSearchHit) -> String {
        var parts = [HistoryRowFormat.dateLabel(hit.startedAt)]
        if let summary = model.summaries.first(where: { $0.id == hit.id }),
           let duration = summary.duration {
            parts.append(HistoryRowFormat.durationLabel(duration))
        }
        let surfaces = HistoryRowFormat.surfacesLabel(hit.surfaces)
        if !surfaces.isEmpty { parts.append(surfaces) }
        return parts.joined(separator: " · ")
    }

    private func artifactContext(for artifact: ArtifactSearchHit) -> String {
        let kind = switch ArtifactKind(rawValue: artifact.kind) {
        case .summary: "Summary"
        case .decision: "Decision"
        case .actionItem: "Action item"
        case nil: "Artifact"
        }
        return "\(kind) · \(artifact.meetingTitle)"
    }

    @ViewBuilder
    private var sidebarOverlay: some View {
        if let loadError = model.loadError, model.summaries.isEmpty {
            EmptyStateView(title: "Couldn't load history", message: loadError)
        } else if model.isSearching && model.results.isEmpty {
            EmptyStateView(
                title: "No matches",
                message: "Nothing in titles, transcripts, or artifacts matches “\(model.query)”."
            )
        } else if !model.isSearching && model.summaries.isEmpty {
            EmptyStateView(
                title: "No meetings yet",
                message: "Press ⌥⌘M when your next meeting starts.\nEverything stays on this Mac."
            )
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let summary = model.selectedSummary {
            MeetingDetailView(
                store: store,
                meeting: summary.asRecord,
                makeModel: makeDetailModel,
                targetSegmentID: model.targetSegmentID,
                onTargetConsumed: { model.targetSegmentID = nil },
                onRename: { title in
                    await model.rename(meetingID: summary.id, to: title)
                },
                onDelete: {
                    await model.deleteMeeting(id: summary.id)
                }
            )
            .id(summary.id)
        } else {
            EmptyStateView(
                title: "Select a meeting",
                message: "Its transcript and artifacts open here."
            )
        }
    }
}

// The read-only transcript view that used to live here (M1's
// MeetingTranscriptView) moved into MeetingDetailView's transcript pane —
// slice 3 turned the detail into transcript + artifacts.
