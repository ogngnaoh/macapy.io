import CaptureKit
import Foundation
import GRDB
import ProviderKit
import Testing
import TranscribeKit

@testable import PersistKit

/// Slice-5 checks 11 (per-meeting delete: zero orphans, zero stale FTS) and
/// 13 (delete-everything: byte-level residue oracle on a real on-disk
/// database).
struct MeetingDataDeletionTests {

    /// Seeds one fully-populated meeting: segments, speakers (with one
    /// segment attributed), three artifacts, and a metered spend row. All
    /// planted text carries the given single-token tag so its search hits
    /// (and byte residue) are attributable to exactly this meeting.
    @discardableResult
    private func seedMeeting(
        meetings: MeetingStore, artifacts: ArtifactStore, ledger: SpendLedgerStore,
        tag: String, startedAt: Date
    ) async throws -> (meeting: MeetingRecord, segments: [Segment]) {
        let meeting = try await meetings.beginMeeting(startedAt: startedAt, ephemeral: false)
        try await meetings.renameMeeting(id: meeting.id, title: "Meeting \(tag)")
        let segments = [
            Segment(id: UUID(), source: .system, text: "they mentioned \(tag) twice, \(tag) exactly",
                    tStart: 1.0, tEnd: 3.0),
            Segment(id: UUID(), source: .mic, text: "I noted \(tag) as well", tStart: 4.0, tEnd: 5.0),
        ]
        try await meetings.append(segments, to: meeting.id)
        let speaker = SpeakerRecord(id: UUID(), meetingID: meeting.id, label: "S1", embedding: nil)
        try await meetings.insertSpeakers([speaker])
        try await meetings.assignSpeakers([segments[0].id: speaker.id], meetingID: meeting.id)
        try await artifacts.insertDrafts(
            [
                try DraftArtifact(kind: .summary, encoding: SummaryPayload(text: "summary of \(tag)")),
                try DraftArtifact(kind: .decision, encoding: DecisionPayload(text: "decided \(tag)")),
                try DraftArtifact(
                    kind: .actionItem,
                    encoding: ActionItemPayload(title: "do \(tag)", owner: "Ana", deadline: nil)),
            ],
            meetingID: meeting.id)
        try await ledger.record(
            SpendEntry(
                id: UUID(), meetingID: meeting.id, model: "model-\(tag)",
                usage: TokenUsage(promptTokens: 10, cachedTokens: 0, completionTokens: 5),
                estCostUSD: 0.01, purpose: .artifact, at: startedAt))
        try await meetings.endMeeting(id: meeting.id, endedAt: startedAt.addingTimeInterval(60))
        return (meeting, segments)
    }

    private func docsizeCounts(_ database: MacapyDatabase) throws -> [String: Int] {
        try database.dbWriter.read { db in
            var counts: [String: Int] = [:]
            for table in ["meetings_fts_docsize", "segments_fts_docsize", "artifacts_fts_docsize"] {
                counts[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            }
            return counts
        }
    }

    // MARK: - Check 11: per-meeting delete

    @Test func deletingOneMeetingRemovesExactlyItsRowsAndItsSearchHits() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let artifacts = ArtifactStore(database: database)
        let ledger = SpendLedgerStore(database: database)
        let search = SearchStore(database: database)

        let doomed = try await seedMeeting(
            meetings: meetings, artifacts: artifacts, ledger: ledger,
            tag: "wombatred", startedAt: Date(timeIntervalSince1970: 1_754_000_000))
        let kept = try await seedMeeting(
            meetings: meetings, artifacts: artifacts, ledger: ledger,
            tag: "heronblue", startedAt: Date(timeIntervalSince1970: 1_754_100_000))
        // A spend row outside any meeting (settings "test connection") must
        // survive a per-meeting delete untouched.
        try await ledger.record(
            SpendEntry(
                id: UUID(), meetingID: nil, model: "probe",
                usage: TokenUsage(promptTokens: 1, cachedTokens: 0, completionTokens: 1),
                estCostUSD: nil, purpose: .classifier, at: Date(timeIntervalSince1970: 1_754_000_500)))

        // Pre-delete: the doomed meeting's tag hits all three groups.
        let doomedHits = try await search.search(matching: "wombatred")
        #expect(doomedHits.meetings.map(\.id) == [doomed.meeting.id])
        #expect(doomedHits.passages.count == 2)
        #expect(doomedHits.artifacts.count == 3)

        let before = try DatabaseDump.dump(database)
        let docsizeBefore = try docsizeCounts(database)

        try await meetings.deleteMeeting(id: doomed.meeting.id)

        // Whole-database row-diff: after == before minus exactly the rows
        // that referenced the doomed meeting (its own row included).
        let doomedKey = DatabaseDump.key(for: doomed.meeting.id)
        var expected = before
        for (table, rows) in expected {
            expected[table] = rows.filter { _, columns in
                columns["id"] != doomedKey && columns["meetingID"] != doomedKey
            }
        }
        #expect(try DatabaseDump.dump(database) == expected)

        // Every search hit for the doomed content is gone, across all groups…
        #expect(try await search.search(matching: "wombatred") == .empty)
        // …the kept meeting's hits survive…
        let keptHits = try await search.search(matching: "heronblue")
        #expect(keptHits.meetings.map(\.id) == [kept.meeting.id])
        #expect(keptHits.passages.count == 2)
        #expect(keptHits.artifacts.count == 3)
        // …and the FTS docsize tables dropped by exactly the doomed
        // meeting's contribution (1 title, 2 segments, 3 artifacts).
        let docsizeAfter = try docsizeCounts(database)
        #expect(docsizeAfter["meetings_fts_docsize"] == docsizeBefore["meetings_fts_docsize"]! - 1)
        #expect(docsizeAfter["segments_fts_docsize"] == docsizeBefore["segments_fts_docsize"]! - 2)
        #expect(docsizeAfter["artifacts_fts_docsize"] == docsizeBefore["artifacts_fts_docsize"]! - 3)
    }

    // MARK: - Check 13: delete-everything

    @Test func deleteEverythingLeavesNoRowsNoBytesAndAWorkingDatabase() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("macapy.sqlite")
        let database = try MacapyDatabase.onDisk(at: dbURL)
        let meetings = MeetingStore(database: database)
        let artifacts = ArtifactStore(database: database)
        let ledger = SpendLedgerStore(database: database)
        let settings = SettingsStore(database: database)
        let search = SearchStore(database: database)

        // Canaries are single lowercase tokens so the FTS index stores them
        // verbatim — a byte-grep catches residue in table pages, index
        // pages, and the WAL alike.
        try await seedMeeting(
            meetings: meetings, artifacts: artifacts, ledger: ledger,
            tag: "canaryzqmeeting", startedAt: Date(timeIntervalSince1970: 1_754_000_000))
        try await ledger.record(
            SpendEntry(
                id: UUID(), meetingID: nil, model: "canaryzqorphanmodel",
                usage: TokenUsage(promptTokens: 1, cachedTokens: 0, completionTokens: 1),
                estCostUSD: nil, purpose: .classifier, at: Date(timeIntervalSince1970: 1_754_000_100)))
        try await settings.set("survives", forKey: "macapy.test.probe")

        try await meetings.deleteAllUserData()

        // Every user-data table and every FTS index is empty; settings live.
        let (tableCounts, settingsCount) = try await database.dbWriter.read { db in
            var counts: [String: Int] = [:]
            for table in [
                "meetings", "segments", "artifacts", "speakers", "spend_ledger",
                "meetings_fts_docsize", "segments_fts_docsize", "artifacts_fts_docsize",
            ] {
                counts[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            }
            return (counts, try Int.fetchOne(db, sql: "SELECT count(*) FROM settings") ?? -1)
        }
        #expect(tableCounts.allSatisfy { $0.value == 0 })
        #expect(settingsCount == 1)
        #expect(try await settings.value(forKey: "macapy.test.probe") == "survives")

        // Byte-grep: no canary bytes anywhere in the database files —
        // checkpoint(TRUNCATE) + VACUUM proven, not assumed.
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: dbURL.path + suffix)
            guard let data = try? Data(contentsOf: url) else { continue }
            #expect(
                !data.contains(subsequence: Data("canaryzq".utf8)),
                "canary bytes survived in \(url.lastPathComponent)")
        }

        // The database still works: begin, append, search.
        let fresh = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await meetings.append(
            [Segment(id: UUID(), source: .mic, text: "afterlife check", tStart: 0, tEnd: 1)],
            to: fresh.id)
        #expect(try await search.search(matching: "afterlife").passages.count == 1)
    }
}

extension Data {
    /// Naive subsequence scan — fixture-sized inputs, oracle-grade clarity.
    func contains(subsequence needle: Data) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return (0...(count - needle.count)).contains { offset in
            self[startIndex + offset..<startIndex + offset + needle.count] == needle
        }
    }
}
