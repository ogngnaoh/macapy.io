import PersistKit
import SwiftUI
import TranscribeKit

/// Minimal past-meetings list (verification surface, not the full M2 history
/// feature — slice-04 doc decision 8): fetch-on-appear from `MeetingStore`,
/// no `ValueObservation`. Replaces `HistoryPlaceholderView`.
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
                    Text(meeting.startedAt, format: .dateTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(meeting.id)
            }
            .navigationTitle("History")
            .overlay {
                if meetings.isEmpty {
                    if let loadError {
                        ContentUnavailableView(
                            "Couldn't load history",
                            systemImage: "exclamationmark.triangle",
                            description: Text(loadError)
                        )
                    } else {
                        ContentUnavailableView(
                            "No meetings yet",
                            systemImage: "clock",
                            description: Text("Past meetings appear here once one ends.")
                        )
                    }
                }
            }
        } detail: {
            if let selectedMeeting {
                MeetingTranscriptView(store: store, meeting: selectedMeeting)
            } else {
                ContentUnavailableView("Select a Meeting", systemImage: "text.bubble")
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
/// (exit criterion 2's "reopenable from the list").
private struct MeetingTranscriptView: View {
    let store: MeetingStore
    let meeting: MeetingRecord

    @State private var segments: [Segment] = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(segments) { segment in
                    Text("\(PanelView.speakerLabel(for: segment.source)): \(segment.text)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(meeting.title)
        .overlay {
            if segments.isEmpty {
                if let loadError {
                    ContentUnavailableView(
                        "Couldn't load transcript",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else {
                    ContentUnavailableView("No Transcript", systemImage: "text.bubble")
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
