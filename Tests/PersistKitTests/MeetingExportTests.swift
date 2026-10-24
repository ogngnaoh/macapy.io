import CaptureKit
import Foundation
import GRDB
import Testing
import TranscribeKit

@testable import PersistKit

struct MeetingExportTests {
    private func fixture() async throws -> (MacapyDatabase, MeetingRecord, [Segment], [ArtifactRecord]) {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let artifacts = ArtifactStore(database: database)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = try await meetings.beginMeeting(startedAt: started, ephemeral: false)
        try await meetings.renameMeeting(id: meeting.id, title: "Résumé & <release> [plan]")
        let segments = [
            Segment(id: UUID(), source: .system, text: "Later — 日本語 😀", tStart: 64, tEnd: 67.5),
            Segment(id: UUID(), source: .mic, text: "First\n![remote](https://example.com/track)", tStart: 1, tEnd: 3),
        ]
        try await meetings.append(segments, to: meeting.id)
        let speaker = SpeakerRecord(id: UUID(), meetingID: meeting.id, label: "S1", embedding: Data("private-voice-vector".utf8))
        try await meetings.insertSpeakers([speaker])
        try await meetings.assignSpeakers([segments[0].id: speaker.id], meetingID: meeting.id)
        let rows = try await artifacts.insertDrafts([
            try DraftArtifact(kind: .summary, encoding: SummaryPayload(text: "A café launch — 你好")),
            try DraftArtifact(kind: .decision, encoding: DecisionPayload(text: "Ship <safe> & sound.")),
            try DraftArtifact(kind: .actionItem, encoding: ActionItemPayload(title: "Send *notes*", owner: nil, deadline: "Friday")),
        ], meetingID: meeting.id, createdAt: started)
        _ = try await artifacts.edit(id: rows[2].id, expectedRevision: 0,
                                    content: .actionItem(title: "Send *notes*", owner: "Mina", deadline: nil), at: started)
        try await artifacts.setStatus(.approved, id: rows[2].id)
        _ = try await artifacts.setCompletion(true, id: rows[2].id, expectedRevision: 1, at: started)
        try await meetings.endMeeting(id: meeting.id, endedAt: started.addingTimeInterval(120))
        try await database.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO settings(key,value) VALUES(?,?)", arguments: ["private-setting", "secret-credential-canary"])
        }
        return (database, try #require(try await meetings.meeting(id: meeting.id)), segments, rows)
    }

    @Test func fullJSONHasStableSourcesReviewCompletionAndNoPrivateInternals() async throws {
        let (database, meeting, segments, rows) = try await fixture()
        let snapshot = try await MeetingExportStore(database: database).snapshot(meetingID: meeting.id, exportedAt: meeting.startedAt)
        let data = try snapshot.data(format: .json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingExportSnapshot.self, from: data)
        #expect(snapshot == decoded)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.transcript.map(\.id) == [segments[1].id, segments[0].id])
        #expect(decoded.transcript.map(\.speakerLabel) == ["You", "S1"])
        #expect(decoded.transcript[1].startSeconds == 64)
        #expect(decoded.transcript[1].endSeconds == 67.5)
        #expect(decoded.artifacts.map(\.id) == rows.map(\.id))
        #expect(decoded.artifacts[2].reviewStatus == "approved")
        #expect(decoded.artifacts[2].revision == 1)
        #expect(decoded.artifacts[2].completedAt != nil)
        #expect(decoded.artifacts[2].editedAt != nil)
        let json = String(decoding: data, as: UTF8.self)
        for forbidden in ["secret-credential-canary", "private-voice-vector", "embedding", "searchText", "spend_ledger", "estCostUSD", "rawAudio"] {
            #expect(!json.contains(forbidden))
        }
        #expect(try snapshot.data(format: .json) == data)
    }

    @Test func markdownEscapesUserContentAndPreservesUnicodeAndChronology() async throws {
        let (database, meeting, _, _) = try await fixture()
        let snapshot = try await MeetingExportStore(database: database).snapshot(meetingID: meeting.id)
        let markdown = String(decoding: try snapshot.data(format: .markdown), as: UTF8.self)
        #expect(markdown.contains("Résumé &amp; &lt;release&gt; \\[plan\\]"))
        #expect(markdown.contains("\\!\\[remote\\]\\(https://example\\.com/track\\)"))
        #expect(markdown.contains("A café launch — 你好"))
        #expect(markdown.contains("Later — 日本語 😀"))
        #expect(markdown.contains("[00:01–00:03] You"))
        #expect(markdown.contains("[01:04–01:07] S1"))
        #expect(markdown.contains("- [x] Send \\*notes\\*"))
        #expect(markdown.contains("Review: approved"))
        let plain = String(decoding: try snapshot.data(format: .text), as: UTF8.self)
        #expect(plain.contains("Résumé & <release> [plan]"))
        #expect(plain.contains("Send *notes*"))
        #expect(!snapshot.suggestedFileName(format: .json).contains(meeting.title))
    }

    @Test func selectionsLimitIncludedContent() async throws {
        let (database, meeting, _, _) = try await fixture()
        let store = MeetingExportStore(database: database)
        let transcript = try await store.snapshot(meetingID: meeting.id, selection: .transcript)
        #expect(transcript.artifacts.isEmpty)
        #expect(transcript.transcript.count == 2)
        let summary = try await store.snapshot(meetingID: meeting.id, selection: .summary)
        #expect(summary.artifacts.map(\.kind) == ["summary"])
        #expect(summary.transcript.isEmpty && summary.speakers.isEmpty)
        let actions = try await store.snapshot(meetingID: meeting.id, selection: .actionItems)
        #expect(actions.artifacts.map(\.kind) == ["action_item"])
        #expect(actions.transcript.isEmpty && actions.speakers.isEmpty)
    }

    @Test func activeEphemeralAndDeletedMeetingsCannotExport() async throws {
        let database = try MacapyDatabase.inMemory()
        let meetings = MeetingStore(database: database)
        let store = MeetingExportStore(database: database)
        let active = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        await #expect(throws: MeetingExportError.meetingNotCompleted) { try await store.snapshot(meetingID: active.id) }
        let ephemeral = try await meetings.beginMeeting(startedAt: Date(), ephemeral: true)
        try await meetings.endMeeting(id: ephemeral.id, endedAt: Date())
        await #expect(throws: MeetingExportError.ephemeralMeeting) { try await store.snapshot(meetingID: ephemeral.id) }
        try await meetings.deleteMeeting(id: active.id)
        await #expect(throws: MeetingExportError.meetingNotFound) { try await store.snapshot(meetingID: active.id) }
    }

    @Test func unknownPayloadFailsInsteadOfLeakingArbitraryJSON() async throws {
        let (database, meeting, _, rows) = try await fixture()
        try await database.dbWriter.write { db in
            try db.execute(sql: "UPDATE artifacts SET kind = ?, payload = ? WHERE id = ?",
                           arguments: ["future_private_kind", #"{"diagnostics":"private-body-canary"}"#, rows[0].id])
        }
        await #expect(throws: MeetingExportError.unsupportedArtifact) {
            try await MeetingExportStore(database: database).snapshot(meetingID: meeting.id)
        }
    }

    @Test func atomicSaveCancellationAndFailurePreserveExistingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("meeting.md")
        let original = Data("existing content".utf8)
        try original.write(to: destination)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try MeetingExportWriter.write(Data("cancelled content".utf8), to: destination)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try Data(contentsOf: destination) == original)
        #expect(throws: (any Error).self) {
            try MeetingExportWriter.write(Data("bad location".utf8), to: directory.appendingPathComponent("missing/meeting.md"))
        }
        #expect(try Data(contentsOf: destination) == original)
        let replacement = Data("complete replacement".utf8)
        try MeetingExportWriter.write(replacement, to: destination)
        #expect(try Data(contentsOf: destination) == replacement)
        #expect(throws: MeetingExportError.invalidDestination) {
            try MeetingExportWriter.write(replacement, to: URL(string: "https://example.com/export")!)
        }
    }
}
