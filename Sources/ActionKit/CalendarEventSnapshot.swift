import CryptoKit
import Foundation

/// A readable source, including calendars that do not permit new events.
public struct CalendarSourceSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public enum CalendarSnapshotError: Error, Sendable, Equatable {
    case invalidIdentifier, invalidDate, invalidTimeZone, contentTooLong
}

/// The complete calendar metadata allowed into local brief matching. Event
/// descriptions, attendee lists, locations and URLs are deliberately absent.
/// Local EventKit identifiers can change after a full sync: treat that as a new
/// identity requiring a new mapping, never a fuzzy title-based association.
public struct CalendarEventSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let calendarID: String
    public let calendarItemID: String
    /// The original scheduled occurrence, which survives a detached occurrence
    /// moving to a different time. Nil for nonrecurring events.
    public let occurrenceDate: Date?
    public let title: String
    public let startDate: Date
    public let endDate: Date
    /// Nil means a floating event, interpreted in the system calendar time zone.
    public let timeZoneIdentifier: String?
    public let isAllDay: Bool

    public init(
        calendarID: String, calendarItemID: String, occurrenceDate: Date? = nil,
        title: String, startDate: Date, endDate: Date, timeZoneIdentifier: String?, isAllDay: Bool
    ) throws {
        guard !calendarID.isEmpty, !calendarItemID.isEmpty,
              calendarID.utf8.count <= 4_096, calendarItemID.utf8.count <= 4_096
        else { throw CalendarSnapshotError.invalidIdentifier }
        guard title.utf8.count <= 8_192 else { throw CalendarSnapshotError.contentTooLong }
        guard Self.validDate(startDate), Self.validDate(endDate),
              occurrenceDate.map(Self.validDate) ?? true else { throw CalendarSnapshotError.invalidDate }
        if let timeZoneIdentifier, TimeZone(identifier: timeZoneIdentifier) == nil {
            throw CalendarSnapshotError.invalidTimeZone
        }
        let start = Self.normalized(startDate)
        let end = Self.normalized(endDate)
        guard end > start else { throw CalendarSnapshotError.invalidDate }
        self.calendarID = calendarID
        self.calendarItemID = calendarItemID
        self.occurrenceDate = occurrenceDate.map(Self.normalized)
        self.title = title
        self.startDate = start
        self.endDate = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isAllDay = isAllDay
    }

    public var id: String {
        Self.digest([calendarID, calendarItemID, occurrenceDate.map(Self.timestamp) ?? ""])
    }

    /// Only eligible metadata changes invalidate a brief. Editing an unrelated
    /// event description cannot trigger another provider generation.
    public var revision: String {
        Self.digest([id, title, Self.timestamp(startDate), Self.timestamp(endDate),
                     timeZoneIdentifier ?? "", isAllDay ? "all-day" : "timed"])
    }

    private enum CodingKeys: String, CodingKey {
        case calendarID, calendarItemID, occurrenceDate, title, startDate, endDate, timeZoneIdentifier, isAllDay
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            calendarID: values.decode(String.self, forKey: .calendarID),
            calendarItemID: values.decode(String.self, forKey: .calendarItemID),
            occurrenceDate: values.decodeIfPresent(Date.self, forKey: .occurrenceDate),
            title: values.decode(String.self, forKey: .title),
            startDate: values.decode(Date.self, forKey: .startDate),
            endDate: values.decode(Date.self, forKey: .endDate),
            timeZoneIdentifier: values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier),
            isAllDay: values.decode(Bool.self, forKey: .isAllDay))
    }

    static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (-62_135_596_800...253_402_214_400).contains(seconds)
    }

    private static func normalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    private static func timestamp(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }

    private static func digest(_ values: [String]) -> String {
        // Length framing avoids delimiter collisions in user-controlled titles.
        var data = Data()
        for value in values {
            let bytes = Data(value.utf8)
            data.append(contentsOf: String(bytes.count).utf8)
            data.append(58)
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CalendarReadState: Sendable, Equatable {
    case ready, readAccessRequired, noCalendarsSelected, invalidRequest, unavailable
}

public struct UpcomingCalendarEvents: Sendable, Equatable {
    public let state: CalendarReadState
    public let events: [CalendarEventSnapshot]
    public let windowStart: Date
    public let windowEnd: Date
    public let unavailableCalendarIDs: Set<String>
    public let isTruncated: Bool
    /// Only a complete read may remove missing occurrences from a local cache.
    /// Permission loss/disablement must instead purge calendar-derived content.
    public var isAuthoritative: Bool {
        state == .ready && !isTruncated && unavailableCalendarIDs.isEmpty
    }

    public init(state: CalendarReadState, events: [CalendarEventSnapshot], windowStart: Date, windowEnd: Date,
                unavailableCalendarIDs: Set<String> = [], isTruncated: Bool = false) {
        self.state = state; self.events = events; self.windowStart = windowStart; self.windowEnd = windowEnd
        self.unavailableCalendarIDs = unavailableCalendarIDs; self.isTruncated = isTruncated
    }
}

@MainActor
public protocol CalendarEventReading: AnyObject, Sendable {
    func readableCalendars() -> [CalendarSourceSnapshot]
    /// Call only when calendar briefs are enabled. The window is always 24 real
    /// hours, even across DST; selectedCalendarIDs never expands to all sources.
    func upcomingEvents(selectedCalendarIDs: Set<String>, startingAt: Date) -> UpcomingCalendarEvents
}
