import Foundation
import Testing

@testable import ActionKit

private let calendarFixtureTime = Date(timeIntervalSince1970: 1_800_000_000)

private func calendarEvent(
    item: String = "item", calendar: String = "work", occurrence: Date? = nil,
    title: String = "Synthetic review", start: Date = calendarFixtureTime, allDay: Bool = false
) throws -> CalendarEventSnapshot {
    try CalendarEventSnapshot(calendarID: calendar, calendarItemID: item, occurrenceDate: occurrence,
                              title: title, startDate: start, endDate: start.addingTimeInterval(allDay ? 86_400 : 1_800),
                              timeZoneIdentifier: allDay ? nil : "America/New_York", isAllDay: allDay)
}

struct CalendarEventSnapshotTests {
    @Test func detachedRecurrenceKeepsIdentityButInvalidatesItsBrief() throws {
        let first = try calendarEvent(occurrence: calendarFixtureTime)
        let moved = try calendarEvent(occurrence: calendarFixtureTime, start: calendarFixtureTime.addingTimeInterval(3_600))
        let nextOccurrence = try calendarEvent(occurrence: calendarFixtureTime.addingTimeInterval(86_400))
        #expect(first.id == moved.id)
        #expect(first.revision != moved.revision)
        #expect(first.id != nextOccurrence.id)
    }

    @Test func nonrecurringMovesKeepIdentityButCalendarOrSyncIdentityChangesDoNot() throws {
        let first = try calendarEvent()
        #expect(try calendarEvent(start: calendarFixtureTime.addingTimeInterval(3_600)).id == first.id)
        #expect(try calendarEvent(title: "New title").revision != first.revision)
        #expect(try calendarEvent(item: "replacement-after-sync").id != first.id)
        #expect(try calendarEvent(calendar: "personal").id != first.id)
    }

    @Test func encodedSnapshotContainsOnlyApprovedMetadataAndRoundTrips() throws {
        let event = try calendarEvent(occurrence: calendarFixtureTime.addingTimeInterval(0.123456))
        let data = try JSONEncoder().encode(event)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["calendarID", "calendarItemID", "occurrenceDate", "title", "startDate", "endDate", "timeZoneIdentifier", "isAllDay"])
        let restored = try JSONDecoder().decode(CalendarEventSnapshot.self, from: data)
        #expect(restored == event)
        #expect(restored.id == event.id)
        #expect(restored.revision == event.revision)
    }

    @Test func invalidMetadataAndPersistedDecodingCannotBypassValidation() throws {
        #expect(throws: CalendarSnapshotError.invalidIdentifier) { try calendarEvent(item: "") }
        #expect(throws: CalendarSnapshotError.contentTooLong) { try calendarEvent(title: String(repeating: "x", count: 8_193)) }
        #expect(throws: CalendarSnapshotError.invalidDate) { try calendarEvent(start: Date(timeIntervalSince1970: .infinity)) }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(calendarEvent())) as? [String: Any])
        json["timeZoneIdentifier"] = "Mars/Colony"
        #expect(throws: CalendarSnapshotError.invalidTimeZone) {
            try JSONDecoder().decode(CalendarEventSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func floatingAllDaySnapshotDoesNotInventAnAbsoluteTimeZone() throws {
        let event = try calendarEvent(allDay: true)
        #expect(event.isAllDay)
        #expect(event.timeZoneIdentifier == nil)
        #expect(try JSONDecoder().decode(CalendarEventSnapshot.self, from: JSONEncoder().encode(event)) == event)
    }
}

@MainActor
private final class FakeCalendarPlatform: ActionPlatformStore {
    var access: ActionAccess = .fullAccess
    var sources = [CalendarSourceSnapshot(id: "work", title: "Read-only work calendar")]
    var snapshots: [CalendarEventSnapshot] = []
    var truncated = false
    var revokeDuringRead = false
    var revokeDuringSources = false
    var sourceReads = 0
    var eventReads: [(Set<String>, Date, Date, Int)] = []
    var requests = 0
    var saves = 0
    func permissions() -> ActionPermissionSnapshot { .init(calendars: access, reminders: .denied) }
    func targets(kind: ExternalActionKind) -> [ActionTargetSnapshot] { [] }
    func request(_ access: ActionAccessRequest) async throws -> Bool { requests += 1; return true }
    func save(_ action: ReviewedAction) throws -> String? { saves += 1; return nil }
    func reconcile(_ action: ReviewedAction) async -> ActionReconciliationResult { .notFound }
    func calendarSources() -> [CalendarSourceSnapshot] {
        sourceReads += 1
        if revokeDuringSources { access = .denied }
        return sources
    }
    func events(calendarIDs: Set<String>, from: Date, to: Date, limit: Int) -> CalendarPlatformRead {
        eventReads.append((calendarIDs, from, to, limit))
        if revokeDuringRead { access = .denied }
        return CalendarPlatformRead(events: snapshots, isTruncated: truncated)
    }
}

@MainActor
struct CalendarEventReadingTests {
    @Test func onlyFullReadPermissionCanListOrQueryWithoutImplicitPrompts() throws {
        for denied in [ActionAccess.notDetermined, .writeOnly, .denied, .restricted, .unavailable] {
            let platform = FakeCalendarPlatform()
            platform.access = denied
            let reader = EventKitActionAdapter(platform: platform)
            #expect(reader.readableCalendars().isEmpty)
            let result = reader.upcomingEvents(selectedCalendarIDs: ["work"], startingAt: calendarFixtureTime)
            #expect(result.state == .readAccessRequired)
            #expect(result.events.isEmpty)
            #expect(!result.isAuthoritative)
            #expect(platform.sourceReads == 0 && platform.eventReads.isEmpty)
            #expect(platform.requests == 0 && platform.saves == 0)
        }
    }

    @Test func selectedReadOnlyCalendarsAreAvailableWithoutWriteCapability() throws {
        let platform = FakeCalendarPlatform()
        platform.snapshots = [try calendarEvent()]
        let reader = EventKitActionAdapter(platform: platform)
        #expect(reader.targets(kind: .calendarEvent).isEmpty)
        #expect(reader.readableCalendars() == platform.sources)
        let result = reader.upcomingEvents(selectedCalendarIDs: ["work"], startingAt: calendarFixtureTime)
        #expect(result.events == platform.snapshots)
        #expect(result.isAuthoritative)
        #expect(platform.eventReads.first?.0 == ["work"])
        #expect(platform.requests == 0 && platform.saves == 0)
    }

    @Test func noSelectionOrInvalidWindowNeverQueriesCalendarData() {
        let platform = FakeCalendarPlatform()
        let reader = EventKitActionAdapter(platform: platform)
        #expect(reader.upcomingEvents(selectedCalendarIDs: [], startingAt: calendarFixtureTime).state == .noCalendarsSelected)
        #expect(reader.upcomingEvents(selectedCalendarIDs: ["work"], startingAt: Date(timeIntervalSince1970: .infinity)).state == .invalidRequest)
        #expect(reader.upcomingEvents(selectedCalendarIDs: [""], startingAt: calendarFixtureTime).state == .invalidRequest)
        #expect(reader.upcomingEvents(selectedCalendarIDs: Set((0...100).map(String.init)), startingAt: calendarFixtureTime).state == .invalidRequest)
        #expect(platform.sourceReads == 0 && platform.eventReads.isEmpty)
    }

    @Test func missingSourcesAreExplicitAndNeverExpandIntoAllCalendars() throws {
        let platform = FakeCalendarPlatform()
        platform.snapshots = [try calendarEvent()]
        let reader = EventKitActionAdapter(platform: platform)
        let none = reader.upcomingEvents(selectedCalendarIDs: ["missing"], startingAt: calendarFixtureTime)
        #expect(none.unavailableCalendarIDs == ["missing"])
        #expect(!none.isAuthoritative)
        #expect(platform.eventReads.isEmpty)
        let partial = reader.upcomingEvents(selectedCalendarIDs: ["work", "missing"], startingAt: calendarFixtureTime)
        #expect(partial.events == platform.snapshots)
        #expect(partial.unavailableCalendarIDs == ["missing"])
        #expect(!partial.isAuthoritative)
        #expect(platform.eventReads.first?.0 == ["work"])
    }

    @Test func revokedAccessDiscardsReadResultsWithoutRetainingStaleMetadata() throws {
        let platform = FakeCalendarPlatform()
        platform.snapshots = [try calendarEvent()]
        platform.revokeDuringRead = true
        let reader = EventKitActionAdapter(platform: platform)
        let result = reader.upcomingEvents(selectedCalendarIDs: ["work"], startingAt: calendarFixtureTime)
        #expect(result.state == .readAccessRequired && result.events.isEmpty)
        #expect(reader.readableCalendars().isEmpty)
        #expect(reader.upcomingEvents(selectedCalendarIDs: ["work"], startingAt: calendarFixtureTime).events.isEmpty)
        #expect(platform.eventReads.count == 1)
        #expect(platform.requests == 0 && platform.saves == 0)
    }

    @Test func revocationWhileListingSourcesStopsBeforeEventRead() {
        let platform = FakeCalendarPlatform()
        platform.revokeDuringSources = true
        let reader = EventKitActionAdapter(platform: platform)
        #expect(reader.readableCalendars().isEmpty)
        platform.access = .fullAccess
        #expect(reader.upcomingEvents(selectedCalendarIDs: ["work"], startingAt: calendarFixtureTime).state == .readAccessRequired)
        #expect(platform.eventReads.isEmpty)
    }

    @Test func filtersUnexpectedSourcesAndBoundsAndMarksResultIncomplete() throws {
        let platform = FakeCalendarPlatform()
        platform.snapshots = [try calendarEvent(), try calendarEvent(item: "other", calendar: "unselected"),
                              try calendarEvent(item: "future", start: calendarFixtureTime.addingTimeInterval(86_400)),
                              try calendarEvent(item: "past", start: calendarFixtureTime.addingTimeInterval(-86_400))]
        let result = EventKitActionAdapter(platform: platform).upcomingEvents(selectedCalendarIDs: ["work"], startingAt: calendarFixtureTime)
        #expect(result.events.map(\.calendarItemID) == ["item"])
        #expect(result.isTruncated && !result.isAuthoritative)
    }

    @Test func snapshotsAreChronologicalBoundedAndTruncationIsNotACompleteCensus() throws {
        let platform = FakeCalendarPlatform()
        platform.snapshots = try (0..<102).reversed().map { try calendarEvent(item: "item-\($0)", start: calendarFixtureTime.addingTimeInterval(Double($0))) }
        let result = EventKitActionAdapter(platform: platform).upcomingEvents(selectedCalendarIDs: ["work"], startingAt: calendarFixtureTime)
        #expect(result.events.count == 100)
        #expect(result.events.first?.calendarItemID == "item-0")
        #expect(result.events.last?.calendarItemID == "item-99")
        #expect(result.isTruncated && !result.isAuthoritative)
        #expect(platform.eventReads.first?.3 == 100)
    }

    @Test func completedEmptyRefreshCanRemoveCancelledOrMovedAwayOccurrences() throws {
        let platform = FakeCalendarPlatform()
        let reader = EventKitActionAdapter(platform: platform)
        platform.snapshots = [try calendarEvent()]
        #expect(reader.upcomingEvents(selectedCalendarIDs: ["work"], startingAt: calendarFixtureTime).events.count == 1)
        platform.snapshots = []
        let changed = reader.upcomingEvents(selectedCalendarIDs: ["work"], startingAt: calendarFixtureTime)
        #expect(changed.events.isEmpty && changed.isAuthoritative)
        platform.truncated = true
        #expect(!reader.upcomingEvents(selectedCalendarIDs: ["work"], startingAt: calendarFixtureTime).isAuthoritative)
    }

    @Test func lookaheadIsTwentyFourRealHoursAcrossDST() throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-11-01T05:30:00Z"))
        let platform = FakeCalendarPlatform()
        let result = EventKitActionAdapter(platform: platform).upcomingEvents(selectedCalendarIDs: ["work"], startingAt: start)
        #expect(result.windowEnd.timeIntervalSince(result.windowStart) == 86_400)
        #expect(platform.eventReads.first?.2 == start.addingTimeInterval(86_400))
    }
}
