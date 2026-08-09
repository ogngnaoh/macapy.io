import CaptureKit
import Foundation
import PersistKit
import Testing
import TranscribeKit

@testable import AppShell

/// Slice-5 checks 9 (deep-link derivation: minute marks, timestamp format,
/// passage selection), 10 (search → select passage → detail rows contain the
/// target at the expected index, over a real in-memory database), and 16
/// (post-delete UI state in `HistorySearchModel`).
@MainActor
struct HistorySearchTests {

    private func attributed(_ source: AudioSource, _ text: String, at tStart: TimeInterval)
        -> AttributedSegment
    {
        AttributedSegment(
            segment: Segment(id: UUID(), source: source, text: text, tStart: tStart, tEnd: tStart + 2),
            speakerID: nil, speakerLabel: nil)
    }

    // MARK: - Check 9: minute marks + timestamp format

    @Test func minuteMarkInsertionIsTableDriven() {
        // (tStarts) → expected row shapes, covering 0 s, the 59→60 s
        // boundary, and past-the-hour.
        let cases: [(tStarts: [TimeInterval], expectedMinutes: [Int], lineCount: Int)] = [
            ([0.0], [0], 1),
            ([0.0, 30.0, 59.0], [0], 3),          // all inside minute zero
            ([59.0, 60.0], [0, 1], 2),            // the 59→60 boundary splits
            ([10.0, 70.0, 130.0], [0, 1, 2], 3),  // one mark per minute
            ([4025.0], [67], 1),                  // > 1 h lands at minute 67
        ]
        for (tStarts, expectedMinutes, lineCount) in cases {
            let rows = TranscriptRows.build(segments: tStarts.map { attributed(.system, "line", at: $0) })
            let minutes = rows.compactMap { row in
                if case .minuteMark(let minute) = row { return minute } else { return nil }
            }
            let lines = rows.filter { if case .line = $0 { true } else { false } }
            #expect(minutes == expectedMinutes)
            #expect(lines.count == lineCount)
        }
    }

    @Test func timestampFormatIsPinned() {
        #expect(TranscriptRows.timestampLabel(minute: 0) == "00:00")
        #expect(TranscriptRows.timestampLabel(minute: 14) == "00:14")
        #expect(TranscriptRows.timestampLabel(minute: 67) == "01:07")
        #expect(TranscriptRows.timestampLabel(tStart: 845) == "00:14")
        #expect(TranscriptRows.timestampLabel(tStart: 4025) == "01:07")
    }

    @Test func passageSelectionSetsMeetingAndTargetAndTargetIsInBuiltRows() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let model = HistorySearchModel(
            meetings: meetings, search: SearchStore(database: database), debounceNanos: 0)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        let segments = [
            Segment(id: UUID(), source: .system, text: "opening remarks", tStart: 5, tEnd: 7),
            Segment(id: UUID(), source: .mic, text: "the lantern schedule slipped", tStart: 65, tEnd: 68),
        ]
        try await meetings.append(segments, to: meeting.id)

        model.query = "lantern"
        await model.settleSearch()
        let passage = try #require(model.results.passages.first)

        model.select(passage: passage)

        #expect(model.selectedMeetingID == meeting.id)
        #expect(model.targetSegmentID == segments[1].id)
        let rows = TranscriptRows.build(segments: try await meetings.attributedSegments(for: meeting.id))
        #expect(rows.contains { $0.id == segments[1].id.uuidString })
    }

    // MARK: - Check 10: search-to-detail flow over a real database

    @Test func searchToDetailFlowLandsOnTheTargetRowAtTheExpectedIndex() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let model = HistorySearchModel(
            meetings: meetings, search: SearchStore(database: database), debounceNanos: 0)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await meetings.renameMeeting(id: meeting.id, title: "Lantern planning")
        let segments = [
            Segment(id: UUID(), source: .system, text: "intro and greetings", tStart: 10, tEnd: 12),
            Segment(id: UUID(), source: .mic, text: "the cobaltmoth deadline moved", tStart: 70, tEnd: 73),
            Segment(id: UUID(), source: .system, text: "closing notes", tStart: 130, tEnd: 132),
        ]
        try await meetings.append(segments, to: meeting.id)
        await model.load()

        model.query = "cobaltmoth"
        await model.settleSearch()
        let passage = try #require(model.results.passages.first)
        #expect(passage.meetingTitle == "Lantern planning")
        model.select(passage: passage)

        // What the detail view loads and builds (the scroll gesture itself is
        // the shipped PanelView mechanism; pixels fold into dogfooding).
        let loaded = try await meetings.attributedSegments(for: model.selectedMeetingID!)
        let rows = TranscriptRows.build(segments: loaded)
        // [mark 00:00, line, mark 00:01, target line, mark 00:02, line]
        #expect(rows.count == 6)
        #expect(rows[3].id == model.targetSegmentID?.uuidString)
        if case .line(let attributed) = rows[3] {
            #expect(attributed.segment.text.contains("cobaltmoth"))
        } else {
            Issue.record("expected a transcript line at index 3, got \(rows[3])")
        }
    }

    // MARK: - Check 16: post-delete UI state

    @Test func deleteMeetingReloadsClearsSelectionAndRerunsTheActiveQuery() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let model = HistorySearchModel(
            meetings: meetings, search: SearchStore(database: database), debounceNanos: 0)
        let doomed = try await meetings.beginMeeting(
            startedAt: Date(timeIntervalSince1970: 1_754_000_000), ephemeral: false)
        try await meetings.append(
            [Segment(id: UUID(), source: .system, text: "emberfox came up twice", tStart: 1, tEnd: 3)],
            to: doomed.id)
        let kept = try await meetings.beginMeeting(
            startedAt: Date(timeIntervalSince1970: 1_754_100_000), ephemeral: false)
        try await meetings.append(
            [Segment(id: UUID(), source: .mic, text: "emberfox again, elsewhere", tStart: 1, tEnd: 3)],
            to: kept.id)
        await model.load()

        model.query = "emberfox"
        await model.settleSearch()
        #expect(model.results.passages.count == 2)
        model.selectedMeetingID = doomed.id
        model.targetSegmentID = model.results.passages.first?.segmentID

        await model.deleteMeeting(id: doomed.id)

        #expect(model.summaries.map(\.id) == [kept.id])
        #expect(model.selectedMeetingID == nil)
        #expect(model.targetSegmentID == nil)
        #expect(model.results.passages.map(\.meetingID) == [kept.id])
        #expect(model.results.meetings.map(\.id) == [kept.id])
    }

    @Test func deletingAnUnselectedMeetingKeepsTheSelection() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let model = HistorySearchModel(
            meetings: meetings, search: SearchStore(database: database), debounceNanos: 0)
        let doomed = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        let kept = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        await model.load()
        model.select(meeting: kept.id)

        await model.deleteMeeting(id: doomed.id)

        #expect(model.selectedMeetingID == kept.id)
        #expect(model.summaries.map(\.id) == [kept.id])
    }
}
