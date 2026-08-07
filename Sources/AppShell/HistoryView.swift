import PersistKit
import SwiftUI
import TranscribeKit

/// Minimal past-meetings list (verification surface, not the full M2 history
/// feature — slice-04 doc decision 8): fetch-on-appear from `MeetingStore`,
/// no `ValueObservation`. Reskinned to the "Quiet instrument" system: native
/// window furniture (List, split view) stays system-styled; text, gutters,
/// and empty states draw from Design tokens.
struct HistoryView: View {
    let store: MeetingStore
    /// Builds the artifacts-pane model for a selected meeting (slice 3).
    /// Defaults to none so previews and shell-less constructions still show
    /// transcripts; the app's scene graph passes the coordinator's factory.
    var makeDetailModel: @MainActor (MeetingRecord) -> MeetingDetailModel? = { _ in nil }

    @State private var meetings: [MeetingRecord] = []
    @State private var loadError: String?
    @State private var selectedID: MeetingRecord.ID?

    var body: some View {
        NavigationSplitView {
            List(meetings, selection: $selectedID) { meeting in
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(UIType.bodySemibold)
                        .foregroundStyle(DesignTokens.text)
                    Text(meeting.startedAt, format: .dateTime)
                        .font(UIType.small)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                .padding(.vertical, 2)
                .tag(meeting.id)
            }
            .navigationTitle("History")
            .overlay {
                if meetings.isEmpty {
                    if let loadError {
                        EmptyStateView(
                            title: "Couldn't load history",
                            message: loadError
                        )
                    } else {
                        EmptyStateView(
                            title: "No meetings yet",
                            message: "Press ⌥⌘M when your next meeting starts.\nEverything stays on this Mac."
                        )
                    }
                }
            }
        } detail: {
            if let selectedMeeting {
                MeetingDetailView(
                    store: store,
                    meeting: selectedMeeting,
                    makeModel: makeDetailModel
                )
            } else {
                EmptyStateView(
                    title: "Select a meeting",
                    message: "Its transcript and artifacts open here."
                )
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .task { await loadMeetings() }
    }

    private var selectedMeeting: MeetingRecord? {
        guard let selectedID else { return nil }
        return meetings.first { $0.id == selectedID }
    }

    private func loadMeetings() async {
        do {
            meetings = try await store.listMeetings()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// The read-only transcript view that used to live here (M1's
// MeetingTranscriptView) moved into MeetingDetailView's transcript pane —
// slice 3 turned the detail into transcript + artifacts.
