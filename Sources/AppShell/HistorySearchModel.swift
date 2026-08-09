import Foundation
import Observation
import PersistKit
import os

/// The History window's state: summary rows, the active search, and the
/// selection (including a passage deep-link's scroll target). Fetch-on-appear
/// by design — nothing observes the database; every mutation path calls an
/// explicit `reload()` (slice-05 doc decision 9).
@MainActor
@Observable
final class HistorySearchModel {
    private let meetings: MeetingStore
    private let search: SearchStore?
    /// ~200 ms of debounce between keystrokes and the FTS query; 0 in tests
    /// so the oracles stay deterministic (slice-05 doc decision 6).
    private let debounceNanos: UInt64
    private let log = Logger(subsystem: "io.macapy.app", category: "HistorySearch")

    private(set) var summaries: [MeetingStore.MeetingSummary] = []
    private(set) var results: SearchResults = .empty
    private(set) var loadError: String?
    var selectedMeetingID: UUID?
    /// Set by a passage tap; the detail view scrolls to (and briefly
    /// highlights) this segment, then clears it.
    var targetSegmentID: UUID?

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(meetings: MeetingStore, search: SearchStore?, debounceNanos: UInt64 = 200_000_000) {
        self.meetings = meetings
        self.search = search
        self.debounceNanos = debounceNanos
    }

    var query: String = "" {
        didSet { scheduleSearch() }
    }

    /// True when the sidebar shows the three grouped result sections instead
    /// of the summary list.
    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedSummary: MeetingStore.MeetingSummary? {
        guard let selectedMeetingID else { return nil }
        return summaries.first { $0.id == selectedMeetingID }
    }

    /// Fetches the summary list and re-runs the active query (idempotent —
    /// the appear hook and every mutation path call it).
    func load() async {
        do {
            summaries = try await meetings.meetingSummaries()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        await runSearchNow()
    }

    // MARK: - Selection

    func select(meeting id: UUID) {
        selectedMeetingID = id
        targetSegmentID = nil
    }

    /// Passage deep-link (slice-05 doc decision 5): select the meeting and
    /// carry the segment id for the detail view's scroll-to.
    func select(passage: PassageSearchHit) {
        selectedMeetingID = passage.meetingID
        targetSegmentID = passage.segmentID
    }

    func select(artifact: ArtifactSearchHit) {
        selectedMeetingID = artifact.meetingID
        targetSegmentID = nil
    }

    // MARK: - Mutations

    /// Renames and reloads. Returns false (leaving everything unchanged) for
    /// an empty title — the view reverts its editor (check 5's UI half).
    func rename(meetingID: UUID, to title: String) async -> Bool {
        do {
            try await meetings.renameMeeting(id: meetingID, title: title)
        } catch {
            log.error("rename failed: \(error.localizedDescription)")
            return false
        }
        await load()
        return true
    }

    /// Deletes one meeting, then reloads the list, clears a selection that
    /// pointed at it, and re-runs the active query so its hits vanish
    /// (check 16).
    func deleteMeeting(id: UUID) async {
        do {
            try await meetings.deleteMeeting(id: id)
        } catch {
            log.error("delete failed: \(error.localizedDescription)")
            loadError = error.localizedDescription
            return
        }
        if selectedMeetingID == id {
            selectedMeetingID = nil
            targetSegmentID = nil
        }
        await load()
    }

    // MARK: - Search plumbing

    private func scheduleSearch() {
        searchTask?.cancel()
        let nanos = debounceNanos
        searchTask = Task { [weak self] in
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard !Task.isCancelled else { return }
            await self?.runSearchNow()
        }
    }

    /// Test support: awaits the in-flight debounce/search, so oracles never
    /// poll.
    func settleSearch() async {
        await searchTask?.value
    }

    private func runSearchNow() async {
        guard isSearching, let search else {
            results = .empty
            return
        }
        do {
            results = try await search.search(matching: query)
        } catch {
            log.error("search failed: \(error.localizedDescription)")
            results = .empty
        }
    }
}
