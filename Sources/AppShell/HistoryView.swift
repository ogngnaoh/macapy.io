import PersistKit
import SwiftUI
import TranscribeKit

/// History (docs/design/04-history.html): summary rows with duration · speaker
/// count · artifact count, and — the moment the search field has text — the
/// three grouped result sections (Meetings / Transcript passages /
/// Artifacts) with passage deep-links into meeting detail. One
/// Native split navigation when standalone; a fixed rail when embedded avoids
/// changing the parent window's toolbar or title as the selected meeting changes.
struct HistoryView: View {
    let model: HistorySearchModel
    let store: MeetingStore
    /// Builds the artifacts-pane model for a selected meeting (slice 3).
    /// Defaults to none so previews and shell-less constructions still show
    /// transcripts; the app's scene graph passes the coordinator's factory.
    var makeDetailModel: @MainActor (MeetingRecord) -> MeetingDetailModel? = { _ in nil }

    var isEmbedded = false

    @FocusState private var searchFocused: Bool

    var body: some View {
        workspace
            .background(
                Button("find") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            )
            .frame(minWidth: 1000, minHeight: 480)
            .background(DesignTokens.bg)
            .task { await model.load() }
    }

    @ViewBuilder
    private var workspace: some View {
        if isEmbedded {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("saved meetings").font(UIType.bodySemibold)
                        .padding(.horizontal, 20).padding(.top, 25).padding(.bottom, 15)
                    SearchField(text: Binding(get: { model.query }, set: { model.query = $0 }), focus: $searchFocused)
                        .padding(.horizontal, 5).padding(.bottom, 15)
                    sidebar
                }
                .frame(width: 235)
                .background(DesignTokens.sunken)
                Rectangle().fill(DesignTokens.hairline).frame(width: 1)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            NavigationSplitView {
                sidebar
                    .navigationTitle("history")
                    .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 330)
            } detail: {
                detail
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    SearchField(text: Binding(get: { model.query }, set: { model.query = $0 }), focus: $searchFocused)
                }
            }
        }
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
        .background(DesignTokens.sunken)
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
            groupHead("meetings · \(results.meetings.count)")
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
            groupHead("transcript passages · \(results.passages.count)")
            ForEach(results.passages) { passage in
                PassageRow(
                    context: "\(passage.meetingTitle) · \(TranscriptRows.timestampLabel(tStart: passage.tStart))",
                    snippet: passage.snippet,
                    action: { model.select(passage: passage) }
                )
            }
        }
        if !results.artifacts.isEmpty {
            groupHead("outputs · \(results.artifacts.count)")
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
            EmptyStateView(title: "couldn’t load history", message: loadError)
        } else if model.isSearching && model.results.isEmpty {
            EmptyStateView(
                title: "no matches",
                message: "Nothing in titles, transcripts, or artifacts matches “\(model.query)”."
            )
        } else if !model.isSearching && model.summaries.isEmpty {
            EmptyStateView(
                title: "no meetings yet",
                message: "Press ⌥⌘M when your next meeting starts.\nEverything stays on this mac."
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
                title: "select a meeting",
                message: "its transcript and reviewed output open here."
            )
        }
    }
}

// The read-only transcript view that used to live here (M1's
// MeetingTranscriptView) moved into MeetingDetailView's transcript pane —
// slice 3 turned the detail into transcript + artifacts.
