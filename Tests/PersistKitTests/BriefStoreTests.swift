import ActionKit
import Foundation
import MemoryKit
import Testing
import TranscribeKit
@testable import PersistKit

struct BriefStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(title: String = "Cedar review", offset: Double = 3600) throws -> CalendarEventSnapshot {
        try .init(calendarID: "work", calendarItemID: "review", title: title,
                  startDate: now.addingTimeInterval(offset), endDate: now.addingTimeInterval(offset + 1800),
                  timeZoneIdentifier: "UTC", isAllDay: false)
    }
    private func read(_ events: [CalendarEventSnapshot], truncated: Bool = false,
                      state: CalendarReadState = .ready, unavailable: Set<String> = []) -> UpcomingCalendarEvents {
        .init(state: state, events: events, windowStart: now, windowEnd: now.addingTimeInterval(86400),
              unavailableCalendarIDs: unavailable, isTruncated: truncated)
    }
    private func configured() async throws -> (MacapyDatabase, BriefStore) {
        let database = try MacapyDatabase.inMemory(), store = BriefStore(database: database)
        #expect(try await store.preferences() == .init())
        try await store.configure(.init(enabled: true, selectedCalendarIDs: ["work"]))
        try await store.synchronize(read([event()]), now: now)
        return (database, store)
    }
    private func local(_ event: CalendarEventSnapshot, revision: Int = 0) -> BriefSnapshot {
        .init(event: event, mappingRevision: revision, context: .init(excerpts: []), text: "No matching evidence.",
              citationIDs: [], mode: .local, generatedAt: now)
    }

    @Test func movedEventInvalidatesCacheWithoutInventingMeetings() async throws {
        let (database, store) = try await configured(), first = try event()
        try await store.save(local(first), now: now)
        #expect(try await store.snapshot(eventID: first.id, now: now) != nil)
        let moved = try event(offset: 7200)
        try await store.synchronize(read([moved]), now: now)
        #expect(try await store.snapshot(eventID: first.id, now: now) == nil)
        await #expect(throws: BriefStoreError.staleEvent) { try await store.save(local(first), now: now) }
        #expect(try await MeetingStore(database: database).listMeetings().isEmpty)
    }

    @Test func truncatedReadRetainsOccurrencesButCancellationAndRevocationPurgeThem() async throws {
        let (_, store) = try await configured(), first = try event()
        try await store.synchronize(read([], truncated: true), now: now)
        #expect(try await store.events(now: now).count == 1)
        try await store.synchronize(read([]), now: now)
        #expect(try await store.events(now: now).isEmpty)
        try await store.synchronize(read([first]), now: now)
        try await store.save(local(first), now: now)
        try await store.synchronize(read([], state: .readAccessRequired), now: now)
        #expect(try await store.events(now: now).isEmpty)
        #expect(try await store.snapshot(eventID: first.id, now: now) == nil)
    }

    @Test func deselectionUnavailableCalendarDisableAndExpiryRemoveDerivedContent() async throws {
        let (_, store) = try await configured()
        try await store.synchronize(read([], unavailable: ["work"]), now: now)
        #expect(try await store.events(now: now).isEmpty)
        try await store.synchronize(read([event()]), now: now)
        try await store.configure(.init(enabled: true))
        #expect(try await store.events(now: now).isEmpty)
        try await store.configure(.init(enabled: true, selectedCalendarIDs: ["work"]))
        try await store.synchronize(read([event()]), now: now)
        #expect(try await store.events(now: now.addingTimeInterval(100000)).isEmpty)
        try await store.synchronize(read([event()]), now: now)
        try await store.configure(.init())
        #expect(try await store.events(now: now).isEmpty)
    }

    @Test func explicitMappingAndReviewedEvidenceAreRequiredAndDeletionInvalidatesCache() async throws {
        let (database, store) = try await configured(), memory = MemoryStore(database: database)
        let meetings = MeetingStore(database: database)
        let meeting = try await meetings.beginMeeting(startedAt: now.addingTimeInterval(-3600), ephemeral: false)
        let segment = Segment(id: UUID(), source: .mic, text: "Cedar ships Friday", tStart: 0, tEnd: 1)
        try await meetings.append([segment], to: meeting.id)
        try await meetings.endMeeting(id: meeting.id, endedAt: now.addingTimeInterval(-3500))
        let entity = try await memory.createEntity(kind: .project, name: "Cedar")
        try await memory.linkEntity(entity.id, to: meeting.id)
        try await memory.setOptIn(true, meetingID: meeting.id)
        let source = SourceReference(kind: .segment, sourceID: segment.id, revision: 0, meetingID: meeting.id,
                                     startCharacter: 0, endCharacter: segment.text.count)
        let fact = try #require(try await memory.insertCandidates([
            .init(kind: .decision, text: segment.text, statedAt: meeting.startedAt, sources: [source], entityIDs: [entity.id]),
        ], meetingID: meeting.id).first)
        try await memory.review(id: fact.id, expectedRevision: 0, status: .approved)
        let context = try await memory.retrieve(.init(query: "Cedar", entityIDs: [entity.id], asOf: now))
        #expect(context.excerpts.count == 1)
        let first = try event()
        let unmapped = BriefSnapshot(event: first, mappingRevision: 0, context: context, text: "Cedar ships Friday",
            citationIDs: context.excerpts.map(\.citationID), mode: .ai, generatedAt: now)
        await #expect(throws: BriefStoreError.staleSources) { try await store.save(unmapped, now: now) }
        try await store.setMapping(eventID: first.id, expectedEventRevision: first.revision, entityIDs: [entity.id])
        let mapped = try #require(try await store.events(now: now).first)
        let snapshot = BriefSnapshot(event: first, mappingRevision: mapped.mappingRevision, context: context,
            text: "Cedar ships Friday", citationIDs: context.excerpts.map(\.citationID), mode: .ai, generatedAt: now)
        try await store.save(snapshot, now: now)
        #expect(try await store.isCurrent(eventID: first.id, eventRevision: first.revision, mappingRevision: mapped.mappingRevision))
        try await meetings.deleteMeeting(id: meeting.id)
        #expect(try await store.snapshot(eventID: first.id, now: now) == nil)
        await #expect(throws: BriefStoreError.staleSources) { try await store.save(snapshot, now: now) }
        try await meetings.deleteAllUserData()
        #expect(try await store.preferences() == .init())
        #expect(try await store.events(now: now).isEmpty)
    }
}
