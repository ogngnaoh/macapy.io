import ActionKit
import Foundation

/// Sample-only capability implementations. Neither has a platform store,
/// credentials, a URLSession, or an external-service factory.
@MainActor final class SampleActionAdapter: ExternalActionAdapter {
    private(set) var created: [ReviewedAction] = []
    func permissionSnapshot() -> ActionPermissionSnapshot { .init(calendars: .fullAccess, reminders: .fullAccess) }
    func targets(kind: ExternalActionKind) -> [ActionTargetSnapshot] {
        [.init(id: "sample-\(kind.rawValue)", title: kind == .calendarEvent ? "Sample calendar" : "Sample reminders", kind: kind, allowsContentModifications: true)]
    }
    func dispatch(_ action: ReviewedAction) async -> ActionDispatchResult {
        created.append(action)
        return .created(identifier: "sample-\(action.operationID.uuidString.lowercased())")
    }
    func reconcile(_ action: ReviewedAction) async -> ActionReconciliationResult {
        created.contains(where: { $0.operationID == action.operationID })
            ? .found(identifier: "sample-\(action.operationID.uuidString.lowercased())") : .notFound
    }
    func reset() { created = [] }
}

@MainActor final class SampleCalendarReader: CalendarEventReading {
    static let calendarID = "sample-team-calendar"
    let event: CalendarEventSnapshot
    init(now: Date = Date()) throws {
        event = try CalendarEventSnapshot(calendarID: Self.calendarID, calendarItemID: "sample-atlas-readiness",
            title: "Atlas / Readiness review", startDate: now.addingTimeInterval(3_600), endDate: now.addingTimeInterval(5_400),
            timeZoneIdentifier: TimeZone.current.identifier, isAllDay: false)
    }
    func readableCalendars() -> [CalendarSourceSnapshot] { [.init(id: Self.calendarID, title: "Sample team calendar")] }
    func upcomingEvents(selectedCalendarIDs: Set<String>, startingAt: Date) -> UpcomingCalendarEvents {
        let end = startingAt.addingTimeInterval(86_400)
        return .init(state: selectedCalendarIDs.isEmpty ? .noCalendarsSelected : .ready,
            events: selectedCalendarIDs.contains(Self.calendarID) && event.endDate > startingAt && event.startDate < end ? [event] : [],
            windowStart: startingAt, windowEnd: end)
    }
}

/// Shared by sample provider contexts so closing/resetting the tour makes even
/// a retained workspace ineligible to show another scripted completion.
final class SampleLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    var isOpen: Bool { lock.withLock { open } }
    func close() { lock.withLock { open = false } }
}
