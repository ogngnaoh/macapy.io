import CaptureKit
import Foundation
import GRDB
import Testing
import TranscribeKit

@testable import PersistKit

/// Slice-5 check 5: `meetingSummaries()` exact counts on a hand-built
/// database, and rename semantics (searchable new title, dead old title,
/// empty rejected).
struct MeetingSummariesTests {

    @Test func summariesCarryExactDurationSpeakerAndArtifactCounts() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let artifacts = ArtifactStore(database: database)

        // Ended meeting: 61 minutes 1 second, 2 speakers, 3 artifacts.
        let full = try await meetings.beginMeeting(
            startedAt: Date(timeIntervalSince1970: 1_754_000_000), ephemeral: false)
        try await meetings.endMeeting(
            id: full.id, endedAt: Date(timeIntervalSince1970: 1_754_003_661))
        try await meetings.insertSpeakers([
            SpeakerRecord(id: UUID(), meetingID: full.id, label: "S1", embedding: nil),
            SpeakerRecord(id: UUID(), meetingID: full.id, label: "S2", embedding: nil),
        ])
        try await artifacts.insertDrafts(
            [
                try DraftArtifact(kind: .summary, encoding: SummaryPayload(text: "recap")),
                try DraftArtifact(kind: .decision, encoding: DecisionPayload(text: "ship it")),
                try DraftArtifact(
                    kind: .actionItem,
                    encoding: ActionItemPayload(title: "follow up", owner: nil, deadline: nil)),
            ],
            meetingID: full.id)

        // Later, still-active meeting: zero of everything.
        let bare = try await meetings.beginMeeting(
            startedAt: Date(timeIntervalSince1970: 1_754_100_000), ephemeral: false)

        // An ephemeral row (never possible in the on-disk database, but the
        // contract is independent of that construction) stays absent.
        try await meetings.beginMeeting(
            startedAt: Date(timeIntervalSince1970: 1_754_200_000), ephemeral: true)

        let summaries = try await meetings.meetingSummaries()

        #expect(summaries.map(\.id) == [bare.id, full.id])
        let bareSummary = try #require(summaries.first)
        #expect(bareSummary.duration == nil)
        #expect(!bareSummary.hasEnded)
        #expect(bareSummary.speakerCount == 0)
        #expect(bareSummary.artifactCount == 0)

        let fullSummary = try #require(summaries.last)
        #expect(fullSummary.duration == 3661)
        #expect(fullSummary.hasEnded)
        #expect(fullSummary.speakerCount == 2)
        #expect(fullSummary.artifactCount == 3)
    }

    @Test func renameMakesNewTitleSearchableAndOldTitleDead() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let search = SearchStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await meetings.renameMeeting(id: meeting.id, title: "Harvest retrospective")

        try await meetings.renameMeeting(id: meeting.id, title: "Kickoff sync")

        #expect(try await search.search(matching: "harvest") == .empty)
        let hits = try await search.search(matching: "kickoff")
        #expect(hits.meetings.map(\.id) == [meeting.id])
        #expect(try await meetings.meetingSummaries().first?.title == "Kickoff sync")
    }

    @Test func emptyOrWhitespaceTitleIsRejectedAndNothingChanges() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await meetings.renameMeeting(id: meeting.id, title: "Stable title")

        await #expect(throws: MeetingStoreError.emptyTitle) {
            try await meetings.renameMeeting(id: meeting.id, title: "")
        }
        await #expect(throws: MeetingStoreError.emptyTitle) {
            try await meetings.renameMeeting(id: meeting.id, title: "  \n\t ")
        }
        #expect(try await meetings.meeting(id: meeting.id)?.title == "Stable title")
    }

    @Test func storedTitlesAreTrimmed() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)

        try await meetings.renameMeeting(id: meeting.id, title: "  Padded name \n")

        #expect(try await meetings.meeting(id: meeting.id)?.title == "Padded name")
    }
}
