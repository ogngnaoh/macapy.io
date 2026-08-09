import CaptureKit
import Foundation
import GRDB
import Testing
import TranscribeKit

@testable import PersistKit

/// Slice-5 checks 2 (correctness across surfaces), 3 (query robustness), and
/// 4 (snippet fidelity) against a hand-built in-memory database.
struct SearchStoreTests {

    // MARK: - Fixture

    /// Two meetings with planted vocabulary:
    /// - "Roadmap planning" (2026-08-02): segments with "glimmerwing" (once,
    ///   known surrounding text) and a triple-"quasar" segment; three
    ///   artifacts all containing "zephyr", the action item with owner Dana /
    ///   deadline Friday.
    /// - "Weekly standup" (2026-08-01): one segment with a single "quasar"
    ///   in a longer sentence (worse bm25 than the triple), one with
    ///   "Glimmerwing" capitalized (case-folding proof).
    private struct Fixture {
        let database: MacapyDatabase
        let search: SearchStore
        let roadmap: MeetingRecord
        let standup: MeetingRecord
        let roadmapSegments: [Segment]
        let standupSegments: [Segment]
        let artifacts: [ArtifactRecord]
    }

    private func makeFixture() async throws -> Fixture {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let artifactStore = ArtifactStore(database: database)

        let roadmap = try await meetings.beginMeeting(
            startedAt: Date(timeIntervalSince1970: 1_754_100_000), ephemeral: false)
        try await meetings.renameMeeting(id: roadmap.id, title: "Roadmap planning")
        let standup = try await meetings.beginMeeting(
            startedAt: Date(timeIntervalSince1970: 1_754_000_000), ephemeral: false)
        try await meetings.renameMeeting(id: standup.id, title: "Weekly standup")

        let roadmapSegments = [
            Segment(
                id: UUID(), source: .system,
                text: "the glimmerwing prototype flew over the ridge",
                tStart: 14.0, tEnd: 17.5),
            Segment(id: UUID(), source: .mic, text: "quasar quasar quasar", tStart: 30.0, tEnd: 31.0),
        ]
        try await meetings.append(roadmapSegments, to: roadmap.id)
        let standupSegments = [
            Segment(
                id: UUID(), source: .system,
                text: "one quasar appeared in the long rambling status update today",
                tStart: 5.0, tEnd: 9.0),
            Segment(
                id: UUID(), source: .mic,
                text: "Glimmerwing shipped late again", tStart: 12.0, tEnd: 14.0),
        ]
        try await meetings.append(standupSegments, to: standup.id)

        let artifacts = try await artifactStore.insertDrafts(
            [
                try DraftArtifact(
                    kind: .summary, encoding: SummaryPayload(text: "we reviewed the zephyr rollout")),
                try DraftArtifact(
                    kind: .decision, encoding: DecisionPayload(text: "zephyr ships behind a flag")),
                try DraftArtifact(
                    kind: .actionItem,
                    encoding: ActionItemPayload(
                        title: "document the zephyr flag", owner: "Dana", deadline: "Friday")),
            ],
            meetingID: roadmap.id)

        return Fixture(
            database: database,
            search: SearchStore(database: database),
            roadmap: roadmap, standup: standup,
            roadmapSegments: roadmapSegments, standupSegments: standupSegments,
            artifacts: artifacts)
    }

    /// The substring of `snippet.text` covered by one highlight range
    /// (character offsets, as `SearchSnippet` defines them).
    private func highlighted(_ snippet: SearchSnippet, _ range: Range<Int>) -> String {
        let start = snippet.text.index(snippet.text.startIndex, offsetBy: range.lowerBound)
        let end = snippet.text.index(snippet.text.startIndex, offsetBy: range.upperBound)
        return String(snippet.text[start..<end])
    }

    // MARK: - Check 2: correctness across surfaces

    @Test func titleQueryHitsTheMeetingsGroupOnly() async throws {
        let fixture = try await makeFixture()
        let results = try await fixture.search.search(matching: "roadmap")

        #expect(results.meetings.map(\.id) == [fixture.roadmap.id])
        #expect(results.meetings.first?.title == "Roadmap planning")
        #expect(results.meetings.first?.hitCount == 1)
        #expect(results.meetings.first?.surfaces == [.title])
        #expect(results.passages.isEmpty)
        #expect(results.artifacts.isEmpty)
    }

    @Test func passageHitCarriesSegmentIDTStartAndMeetingTitle() async throws {
        let fixture = try await makeFixture()
        let results = try await fixture.search.search(matching: "prototype")

        let passage = try #require(results.passages.first)
        #expect(results.passages.count == 1)
        #expect(passage.segmentID == fixture.roadmapSegments[0].id)
        #expect(passage.meetingID == fixture.roadmap.id)
        #expect(passage.meetingTitle == "Roadmap planning")
        #expect(passage.tStart == 14.0)
    }

    @Test func everyArtifactPayloadFieldIsSearchable() async throws {
        let fixture = try await makeFixture()

        let summary = try await fixture.search.search(matching: "rollout")
        #expect(summary.artifacts.map(\.artifactID) == [fixture.artifacts[0].id])
        #expect(summary.artifacts.first?.kind == "summary")

        let decision = try await fixture.search.search(matching: "behind")
        #expect(decision.artifacts.map(\.artifactID) == [fixture.artifacts[1].id])

        let title = try await fixture.search.search(matching: "document")
        #expect(title.artifacts.map(\.artifactID) == [fixture.artifacts[2].id])

        let owner = try await fixture.search.search(matching: "dana")
        #expect(owner.artifacts.map(\.artifactID) == [fixture.artifacts[2].id])

        let deadline = try await fixture.search.search(matching: "friday")
        #expect(deadline.artifacts.map(\.artifactID) == [fixture.artifacts[2].id])
        #expect(deadline.artifacts.first?.meetingTitle == "Roadmap planning")
    }

    @Test func absentTermReturnsThreeEmptyGroups() async throws {
        let fixture = try await makeFixture()
        let results = try await fixture.search.search(matching: "xylophone")
        #expect(results == .empty)
        #expect(results.isEmpty)
    }

    @Test func meetingsGroupAggregatesCrossSurfaceHitsExactly() async throws {
        let fixture = try await makeFixture()
        // "zephyr" is in all three roadmap artifacts and nowhere else.
        let results = try await fixture.search.search(matching: "zephyr")

        let meeting = try #require(results.meetings.first)
        #expect(results.meetings.count == 1)
        #expect(meeting.id == fixture.roadmap.id)
        #expect(meeting.hitCount == 3)
        #expect(meeting.surfaces == [.summary, .decision, .actionItem])

        // "glimmerwing" is one roadmap segment + one standup segment.
        let glimmer = try await fixture.search.search(matching: "glimmerwing")
        #expect(Set(glimmer.meetings.map(\.id)) == [fixture.roadmap.id, fixture.standup.id])
        #expect(glimmer.meetings.allSatisfy { $0.hitCount == 1 && $0.surfaces == [.transcript] })
    }

    @Test func groupOrderIsBM25ThenTiebreak() async throws {
        let fixture = try await makeFixture()
        // Roadmap's "quasar quasar quasar" outranks standup's single quasar
        // in a longer sentence (higher term frequency, shorter document).
        let results = try await fixture.search.search(matching: "quasar")

        #expect(results.passages.map(\.segmentID) == [
            fixture.roadmapSegments[1].id,
            fixture.standupSegments[0].id,
        ])
        #expect(results.meetings.map(\.id) == [fixture.roadmap.id, fixture.standup.id])
    }

    // MARK: - Check 3: query robustness

    @Test(arguments: ["\"", "((", "NEAR(a,b)", "*", "😀", "", "   ", "\n\t"])
    func hostileQueryNeverThrows(query: String) async throws {
        let fixture = try await makeFixture()
        _ = try await fixture.search.search(matching: query)
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func emptyAndWhitespaceQueriesReturnEmptyResults(query: String) async throws {
        let fixture = try await makeFixture()
        let results = try await fixture.search.search(matching: query)
        #expect(results == .empty)
    }

    @Test func multiTokenQueryANDsAllPrefixes() async throws {
        let fixture = try await makeFixture()

        // Positive: both tokens present (as prefixes) in one segment.
        let both = try await fixture.search.search(matching: "glimmerwing proto")
        #expect(both.passages.map(\.segmentID) == [fixture.roadmapSegments[0].id])

        // Negative: each token matches somewhere, but never together.
        let never = try await fixture.search.search(matching: "glimmerwing quasar")
        #expect(never == .empty)
    }

    // MARK: - Check 4: snippet fidelity

    @Test func sentinelParseRoundTripsTextAndRanges() {
        let open = String(SearchSnippet.highlightOpen)
        let close = String(SearchSnippet.highlightClose)

        let parsed = SearchSnippet.parse("ab \(open)cd\(close) ef \(open)gh\(close)")
        #expect(parsed.text == "ab cd ef gh")
        #expect(parsed.highlights == [3..<5, 9..<11])

        #expect(SearchSnippet.parse("no highlights") == SearchSnippet(text: "no highlights", highlights: []))
        // Defensive: unpaired open highlights to the end; stray close is dropped.
        #expect(SearchSnippet.parse("a \(open)tail") == SearchSnippet(text: "a tail", highlights: [2..<6]))
        #expect(SearchSnippet.parse("a\(close) b") == SearchSnippet(text: "a b", highlights: []))
    }

    @Test func everyHighlightRangeIsACaseFoldedQueryToken() async throws {
        let fixture = try await makeFixture()
        let results = try await fixture.search.search(matching: "glimmerwing")

        #expect(results.passages.count == 2)
        for passage in results.passages {
            #expect(!passage.snippet.highlights.isEmpty)
            for range in passage.snippet.highlights {
                #expect(highlighted(passage.snippet, range).lowercased() == "glimmerwing")
            }
        }
        // The planted needle's known surrounding text survives around the
        // highlight (self-verifying: parse dropped only the sentinels).
        let roadmapPassage = try #require(
            results.passages.first { $0.segmentID == fixture.roadmapSegments[0].id })
        #expect(roadmapPassage.snippet.text.contains("glimmerwing prototype flew over the ridge"))
        // Case-folding proof: the standup corpus token is capitalized.
        let standupPassage = try #require(
            results.passages.first { $0.segmentID == fixture.standupSegments[1].id })
        #expect(standupPassage.snippet.text.contains("Glimmerwing shipped late"))
        #expect(
            standupPassage.snippet.highlights.map { highlighted(standupPassage.snippet, $0) }
                == ["Glimmerwing"])
    }

    @Test func multiTokenQueryHighlightsEachMatchedToken() async throws {
        let fixture = try await makeFixture()
        let results = try await fixture.search.search(matching: "zephyr flag")

        // "document the zephyr flag" — both tokens highlighted, in order.
        let hit = try #require(
            results.artifacts.first { $0.artifactID == fixture.artifacts[2].id })
        let tokens = hit.snippet.highlights.map { highlighted(hit.snippet, $0).lowercased() }
        #expect(tokens == ["zephyr", "flag"])
    }
}
