import CaptureKit
import Foundation
import GRDB
import Testing
import TranscribeKit

@testable import PersistKit

/// Slice-5 checks 6 (performance at seeded scale), 7 (fixture economics),
/// and 8a (incremental index) against the cached `SearchFixtureSeeder`
/// database. Serialized: both tests share the cache, and only one build may
/// run. Elapsed times are logged as evidence (decision 10: in-test
/// measurement is the performance authority; the release-harness split
/// remains the documented escalation if debug timing ever flakes).
@Suite(.serialized)
struct SearchScaleTests {

    /// Check 6 + check 7's build/warm economics: floors asserted and logged,
    /// planted-needle and common-token searches each < 1 s.
    @Test func seededScaleSearchesStayUnderOneSecond() async throws {
        let clock = ContinuousClock()
        let testStart = clock.now
        let fixture = try SearchFixtureSeeder.fixture()
        let openElapsed = (clock.now - testStart).seconds
        if let buildSeconds = fixture.buildSeconds {
            print("[scale] cold fixture build: \(buildSeconds)s")
            #expect(buildSeconds < 60)  // check 7: cold build budget
        } else {
            print("[scale] warm fixture open: \(openElapsed)s")
            #expect(openElapsed < 5)  // check 7: warm access budget
        }

        let database = try MacapyDatabase.onDisk(at: fixture.url)
        let search = SearchStore(database: database)

        // Floors (counts asserted ≥ and logged — no silent shrinkage).
        let counts = try await database.dbWriter.read { db in
            (
                meetings: try Int.fetchOne(db, sql: "SELECT count(*) FROM meetings") ?? 0,
                segments: try Int.fetchOne(db, sql: "SELECT count(*) FROM segments") ?? 0,
                artifacts: try Int.fetchOne(db, sql: "SELECT count(*) FROM artifacts") ?? 0,
                threeHour: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT count(*) FROM meetings
                        WHERE (julianday(endedAt) - julianday(startedAt)) * 86400 >= 10800
                        """) ?? 0
            )
        }
        print("[scale] fixture: \(counts.meetings) meetings, \(counts.segments) segments, "
            + "\(counts.artifacts) artifacts, \(counts.threeHour) three-hour meetings")
        #expect(counts.meetings >= SearchFixtureSeeder.Floors.meetings)
        #expect(counts.segments >= SearchFixtureSeeder.Floors.segments * SearchFixtureSeeder.scale())
        #expect(counts.artifacts >= SearchFixtureSeeder.Floors.artifacts)
        #expect(counts.threeHour >= SearchFixtureSeeder.Floors.threeHourMeetings)

        // Planted needle: exactly one passage, < 1 s.
        let needleStart = clock.now
        let needle = try await search.search(matching: SearchFixtureSeeder.needleToken)
        let needleElapsed = (clock.now - needleStart).seconds
        print("[scale] needle search: \(needleElapsed)s")
        #expect(needleElapsed < 1.0)
        #expect(needle.passages.count == 1)
        #expect(needle.passages.first?.snippet.text.contains("baseline drifted") == true)
        #expect(needle.meetings.count == 1)
        #expect(needle.meetings.first?.hitCount == 1)

        // Title and artifact needles hit their groups.
        let title = try await search.search(matching: SearchFixtureSeeder.titleNeedleToken)
        #expect(title.meetings.count == 1)
        #expect(title.meetings.first?.surfaces == [.title])
        let artifact = try await search.search(matching: SearchFixtureSeeder.artifactNeedleToken)
        #expect(artifact.artifacts.count == 1)
        #expect(artifact.artifacts.first?.kind == "action_item")

        // Common token: every ninth segment carries it, so the exact global
        // hit count is derivable — and the search still lands < 1 s.
        let commonStart = clock.now
        let common = try await search.search(matching: SearchFixtureSeeder.commonToken)
        let commonElapsed = (clock.now - commonStart).seconds
        print("[scale] common-token search: \(commonElapsed)s")
        #expect(commonElapsed < 1.0)
        #expect(common.meetings.count == counts.meetings)
        #expect(common.passages.count == 100)  // display cap; counts stay exact:
        let expectedHits = (counts.segments + 8) / 9
        #expect(common.meetings.map(\.hitCount).reduce(0, +) == expectedHits)

        if fixture.buildSeconds == nil {
            let total = (clock.now - testStart).seconds
            print("[scale] warm suite body: \(total)s")
            #expect(total < 2.5)  // check 7: warm-cache suite half-budget
        }
    }

    /// Check 8a: a 25-row batch appended through the normal store path to
    /// the seeded database is searchable in the same test with no wait, and
    /// the append itself stays under the 250 ms tripwire. Runs against a
    /// copy so the shared cache never accumulates test rows.
    @Test func batchAppendedToSeededDatabaseIsImmediatelySearchable() async throws {
        let clock = ContinuousClock()
        let testStart = clock.now
        let fixture = try SearchFixtureSeeder.fixture()
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        let scratchURL = scratchDir.appendingPathComponent("fixture.sqlite")
        try FileManager.default.copyItem(at: fixture.url, to: scratchURL)

        let database = try MacapyDatabase.onDisk(at: scratchURL)
        let meetings = MeetingStore(database: database)
        let search = SearchStore(database: database)
        let segmentsBefore = try await database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM segments") ?? 0
        }
        #expect(segmentsBefore >= SearchFixtureSeeder.Floors.segments)

        let meeting = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        let batch = (0..<25).map { index in
            Segment(
                id: UUID(), source: .system,
                text: "wrenincremental follow up number \(index)",
                tStart: Double(index) * 2.0, tEnd: Double(index) * 2.0 + 1.9)
        }

        let appendStart = clock.now
        try await meetings.append(batch, to: meeting.id)
        let appendElapsed = (clock.now - appendStart).seconds
        print("[scale] 25-row batch append onto \(segmentsBefore) rows: \(appendElapsed)s")
        #expect(appendElapsed < 0.25)

        // Searchable the moment the flush's transaction committed — the
        // very next statement, no wait, no reopen.
        let results = try await search.search(matching: "wrenincremental")
        #expect(results.passages.count == 25)
        #expect(results.meetings.map(\.id) == [meeting.id])
        #expect(results.meetings.first?.hitCount == 25)

        if fixture.buildSeconds == nil {
            let total = (clock.now - testStart).seconds
            print("[scale] warm incremental body: \(total)s")
            #expect(total < 2.5)  // check 7: warm-cache suite half-budget
        }
    }

    /// Check 7's staleness safety: the cache path is keyed by version and
    /// scale, so bumping either can never reuse an old fixture.
    @Test func cacheURLIsVersionAndScaleKeyed() {
        let current = SearchFixtureSeeder.cacheURL(version: 1, scale: 1)
        #expect(current.path.contains("v1-x1"))
        #expect(SearchFixtureSeeder.cacheURL(version: 2, scale: 1) != current)
        #expect(SearchFixtureSeeder.cacheURL(version: 1, scale: 8) != current)
    }
}
