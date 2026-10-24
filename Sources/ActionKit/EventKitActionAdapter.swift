import EventKit
import Foundation

enum ActionAccessRequest: Sendable, Equatable {
    case calendarWrite, calendarRead, reminders
}

@MainActor
protocol ActionPlatformStore: AnyObject {
    func permissions() -> ActionPermissionSnapshot
    func targets(kind: ExternalActionKind) -> [ActionTargetSnapshot]
    func request(_ access: ActionAccessRequest) async throws -> Bool
    func save(_ action: ReviewedAction) throws -> String?
    func reconcile(_ action: ReviewedAction) async -> ActionReconciliationResult
    func calendarSources() -> [CalendarSourceSnapshot]
    func events(calendarIDs: Set<String>, from: Date, to: Date, limit: Int) -> CalendarPlatformRead
}

struct CalendarPlatformRead {
    let events: [CalendarEventSnapshot]
    let isTruncated: Bool
}

/// EventKit stays behind one main-actor owner. No constructor, read, or save
/// requests permission; only the three explicit request methods can prompt.
@MainActor
public final class EventKitActionAdapter: ExternalActionAdapter, CalendarEventReading {
    private let platform: any ActionPlatformStore

    public init() { platform = SystemActionPlatformStore() }
    init(platform: any ActionPlatformStore) { self.platform = platform }

    public func permissionSnapshot() -> ActionPermissionSnapshot { platform.permissions() }
    public func targets(kind: ExternalActionKind) -> [ActionTargetSnapshot] {
        guard platform.permissions().canCreate(kind) else { return [] }
        return platform.targets(kind: kind).filter(\.allowsContentModifications)
    }

    public func requestCalendarWriteAccess() async throws -> Bool { try await platform.request(.calendarWrite) }
    public func requestCalendarReadAccess() async throws -> Bool { try await platform.request(.calendarRead) }
    public func requestReminderAccess() async throws -> Bool { try await platform.request(.reminders) }

    public func readableCalendars() -> [CalendarSourceSnapshot] {
        guard platform.permissions().calendars.canRead else { return [] }
        let sources = platform.calendarSources()
        guard platform.permissions().calendars.canRead else { return [] }
        return sources
    }

    /// No retained cache and no implicit permission requests. The composition
    /// root invokes this only after opt-in, outside active capture, and refreshes
    /// on EventKit change/wake. An incomplete result cannot prune valid briefs.
    public func upcomingEvents(selectedCalendarIDs: Set<String>, startingAt start: Date) -> UpcomingCalendarEvents {
        let end = start.addingTimeInterval(86_400)
        func empty(_ state: CalendarReadState) -> UpcomingCalendarEvents {
            UpcomingCalendarEvents(state: state, events: [], windowStart: start, windowEnd: end)
        }
        guard CalendarEventSnapshot.validDate(start), CalendarEventSnapshot.validDate(end),
              selectedCalendarIDs.count <= 100,
              selectedCalendarIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096 })
        else { return empty(.invalidRequest) }
        guard !selectedCalendarIDs.isEmpty else { return empty(.noCalendarsSelected) }
        guard platform.permissions().calendars.canRead else { return empty(.readAccessRequired) }
        guard !Task.isCancelled else { return empty(.unavailable) }
        let available = Set(platform.calendarSources().map(\.id))
        let selected = selectedCalendarIDs.intersection(available)
        let missing = selectedCalendarIDs.subtracting(available)
        guard platform.permissions().calendars.canRead else { return empty(.readAccessRequired) }
        guard !selected.isEmpty else {
            return UpcomingCalendarEvents(state: .ready, events: [], windowStart: start, windowEnd: end,
                                          unavailableCalendarIDs: missing)
        }
        let read = platform.events(calendarIDs: selected, from: start, to: end, limit: 100)
        guard platform.permissions().calendars.canRead else { return empty(.readAccessRequired) }
        guard !Task.isCancelled else { return empty(.unavailable) }
        var distinct: [String: CalendarEventSnapshot] = [:]
        var incomplete = read.isTruncated
        for event in read.events {
            guard selected.contains(event.calendarID), event.startDate < end, event.endDate > start else {
                incomplete = true
                continue
            }
            if let existing = distinct[event.id], existing != event { incomplete = true; continue }
            distinct[event.id] = event
        }
        let events = distinct.values.sorted {
            $0.startDate == $1.startDate ? $0.id < $1.id : $0.startDate < $1.startDate
        }
        return UpcomingCalendarEvents(state: .ready, events: Array(events.prefix(100)), windowStart: start, windowEnd: end,
                                      unavailableCalendarIDs: missing, isTruncated: incomplete || events.count > 100)
    }

    /// Call only after durable journal admission. The adapter does exactly one
    /// save and never retries a thrown/ambiguous platform result.
    public func dispatch(_ action: ReviewedAction) async -> ActionDispatchResult {
        guard !Task.isCancelled else { return .failed(.cancelledBeforeDispatch) }
        guard platform.permissions().canCreate(action.kind) else { return .failed(.permissionDenied) }
        guard let target = platform.targets(kind: action.kind).first(where: { $0.id == action.target.id }),
              target.allowsContentModifications else { return .failed(.targetUnavailable) }
        guard target == action.target else { return .failed(.targetChanged) }
        do {
            guard let identifier = try platform.save(action), !identifier.isEmpty else { return .unknown }
            return .created(identifier: identifier)
        } catch {
            // EventKit and SQLite cannot commit atomically. Do not turn an
            // ambiguous save failure into permission for another write.
            return .unknown
        }
    }

    public func reconcile(_ action: ReviewedAction) async -> ActionReconciliationResult {
        let permission = action.kind == .calendarEvent ? platform.permissions().calendars : platform.permissions().reminders
        guard permission.canRead else { return .readAccessRequired }
        guard !Task.isCancelled else { return .unavailable }
        return await platform.reconcile(action)
    }
}

@MainActor
private final class SystemActionPlatformStore: ActionPlatformStore {
    private let store = EKEventStore()

    func permissions() -> ActionPermissionSnapshot {
        ActionPermissionSnapshot(
            calendars: Self.access(EKEventStore.authorizationStatus(for: .event)),
            reminders: Self.access(EKEventStore.authorizationStatus(for: .reminder)))
    }

    private static func access(_ value: EKAuthorizationStatus) -> ActionAccess {
        switch value {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .writeOnly: .writeOnly
        case .fullAccess: .fullAccess
        @unknown default: .unavailable
        }
    }

    func request(_ access: ActionAccessRequest) async throws -> Bool {
        switch access {
        case .calendarWrite: try await store.requestWriteOnlyAccessToEvents()
        case .calendarRead: try await store.requestFullAccessToEvents()
        case .reminders: try await store.requestFullAccessToReminders()
        }
    }

    func targets(kind: ExternalActionKind) -> [ActionTargetSnapshot] {
        store.calendars(for: kind == .calendarEvent ? .event : .reminder).map {
            ActionTargetSnapshot(id: $0.calendarIdentifier, title: $0.title, kind: kind,
                                 allowsContentModifications: $0.allowsContentModifications)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func calendarSources() -> [CalendarSourceSnapshot] {
        store.calendars(for: .event).map { CalendarSourceSnapshot(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func events(calendarIDs: Set<String>, from: Date, to: Date, limit: Int) -> CalendarPlatformRead {
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        // Never pass nil/empty calendars to a predicate and accidentally widen
        // the read to the user's other calendars.
        guard !calendars.isEmpty else { return CalendarPlatformRead(events: [], isTruncated: true) }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        var snapshots: [CalendarEventSnapshot] = []
        var scanned = 0
        var truncated = calendars.count != calendarIDs.count
        store.enumerateEvents(matching: predicate) { event, stop in
            scanned += 1
            defer {
                if scanned >= 1_000 { truncated = true; stop.pointee = true }
            }
            guard event.status != .canceled else { return }
            guard let start = event.startDate, let end = event.endDate,
                  start < to, end > from, let calendarID = event.calendar?.calendarIdentifier,
                  calendarIDs.contains(calendarID) else { return }
            guard let snapshot = try? CalendarEventSnapshot(
                calendarID: calendarID, calendarItemID: event.calendarItemIdentifier,
                occurrenceDate: event.occurrenceDate,
                title: event.title ?? "Untitled event", startDate: start, endDate: end,
                timeZoneIdentifier: event.timeZone?.identifier, isAllDay: event.isAllDay)
            else { truncated = true; return }
            snapshots.append(snapshot)
            // EventKit enumeration order is unspecified. Retain the earliest
            // bounded set; truncation is explicit and never a complete census.
            if snapshots.count > limit {
                truncated = true
                snapshots.sort { $0.startDate == $1.startDate ? $0.id < $1.id : $0.startDate < $1.startDate }
                snapshots.removeLast()
            }
        }
        return CalendarPlatformRead(events: snapshots, isTruncated: truncated)
    }

    func save(_ action: ReviewedAction) throws -> String? {
        // Recheck the real object immediately before constructing the new item.
        guard let calendar = store.calendar(withIdentifier: action.target.id),
              calendar.allowsContentModifications, calendar.title == action.target.title else {
            throw PlatformFailure.targetUnavailable
        }
        switch action.schedule {
        case .calendar(let start, let end, let zone):
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = action.title
            event.notes = action.externalNotes
            event.startDate = start
            event.endDate = end
            event.timeZone = TimeZone(identifier: zone)
            event.isAllDay = false
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier ?? event.calendarItemIdentifier
        case .reminder(let dueDate, let zone):
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = calendar
            reminder.title = action.title
            reminder.notes = action.externalNotes
            if let dueDate {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: zone)!
                reminder.dueDateComponents = calendar.dateComponents(
                    [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: dueDate)
            }
            try store.save(reminder, commit: true)
            return reminder.calendarItemIdentifier
        }
    }

    func reconcile(_ action: ReviewedAction) async -> ActionReconciliationResult {
        guard let calendar = store.calendar(withIdentifier: action.target.id) else { return .unavailable }
        switch action.schedule {
        case .calendar(let start, let end, _):
            // Explicit reconciliation is bounded to this target and ±1 year.
            // A missing marker never authorizes a second save.
            let predicate = store.predicateForEvents(
                withStart: start.addingTimeInterval(-31_536_000),
                end: end.addingTimeInterval(31_536_000), calendars: [calendar])
            var identifiers: Set<String> = []
            var scanned = 0
            store.enumerateEvents(matching: predicate) { event, stop in
                scanned += 1
                if event.notes?.contains(action.operationMarker) == true {
                    identifiers.insert(event.eventIdentifier ?? event.calendarItemIdentifier)
                }
                if identifiers.count > 1 || scanned >= 10_000 { stop.pointee = true }
            }
            if identifiers.count > 1 { return .ambiguous }
            if scanned >= 10_000 { return .unavailable }
            return identifiers.first.map { .found(identifier: $0) } ?? .notFound
        case .reminder:
            return await ReminderReconciliation(store: store).find(
                predicate: store.predicateForReminders(in: [calendar]), marker: action.operationMarker)
        }
    }

    private enum PlatformFailure: Error { case targetUnavailable }
}

/// EventKit delivers its completion on an unspecified queue. This transfer is
/// consumed only on MainActor; the callback never reads/mutates reminder items.
private struct ReminderTransfer: @unchecked Sendable {
    let reminders: [EKReminder]?
}

@MainActor
private final class ReminderReconciliation {
    private let store: EKEventStore
    private var token: Any?
    private var continuation: CheckedContinuation<ActionReconciliationResult, Never>?

    init(store: EKEventStore) { self.store = store }

    func find(predicate: NSPredicate, marker: String) async -> ActionReconciliationResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .unavailable); return }
                self.continuation = continuation
                token = store.fetchReminders(matching: predicate) { [weak self] reminders in
                    let transfer = ReminderTransfer(reminders: reminders)
                    Task { @MainActor in
                        guard let self else { return }
                        guard let reminders = transfer.reminders else { self.finish(.unavailable); return }
                        let identifiers = Set(reminders.lazy.filter { $0.notes?.contains(marker) == true }
                            .prefix(2).map(\.calendarItemIdentifier))
                        self.finish(identifiers.count > 1 ? .ambiguous : identifiers.first.map { .found(identifier: $0) } ?? .notFound)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    private func finish(_ result: ActionReconciliationResult) {
        let pending = continuation
        continuation = nil
        token = nil
        pending?.resume(returning: result)
    }

    private func cancel() {
        if let token { store.cancelFetchRequest(token) }
        finish(.unavailable)
    }
}
