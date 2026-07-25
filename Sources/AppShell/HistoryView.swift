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
                MeetingTranscriptView(store: store, meeting: selectedMeeting)
            } else {
                EmptyStateView(
                    title: "Select a meeting",
                    message: "Its transcript opens here."
                )
            }
        }
        .frame(minWidth: 480, minHeight: 320)
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

/// Read-only transcript for one persisted meeting — reopened, not re-editable
/// (M1 exit criterion 2's "reopenable from the list"). Same caption treatment
/// as the live panel: mono attribution gutter, SF text.
private struct MeetingTranscriptView: View {
    let store: MeetingStore
    let meeting: MeetingRecord

    @State private var segments: [Segment] = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(segments) { segment in
                    TranscriptLineView(
                        speaker: PanelView.speakerLabel(for: segment.source),
                        isYou: segment.source == .mic,
                        text: segment.text,
                        isVolatile: false
                    )
                }
            }
            .padding(.vertical, DesignTokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(meeting.title)
        .overlay {
            if segments.isEmpty {
                if let loadError {
                    EmptyStateView(
                        title: "Couldn't load transcript",
                        message: loadError
                    )
                } else {
                    EmptyStateView(
                        title: "No transcript",
                        message: "This meeting has no captured lines."
                    )
                }
            }
        }
        .task(id: meeting.id) { await loadSegments() }
    }

    private func loadSegments() async {
        do {
            segments = try await store.segments(for: meeting.id)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
