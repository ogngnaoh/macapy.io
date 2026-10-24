import CryptoKit
import Foundation

public enum ExternalActionKind: String, Codable, Sendable, CaseIterable {
    case calendarEvent
    case reminder
}

public struct ActionTargetSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let kind: ExternalActionKind
    public let allowsContentModifications: Bool

    public init(id: String, title: String, kind: ExternalActionKind, allowsContentModifications: Bool) {
        self.id = id
        self.title = title
        self.kind = kind
        self.allowsContentModifications = allowsContentModifications
    }
}

public enum ActionSchedule: Codable, Sendable, Equatable {
    case calendar(start: Date, end: Date, timeZoneIdentifier: String)
    case reminder(dueDate: Date?, timeZoneIdentifier: String)

    public var kind: ExternalActionKind {
        switch self {
        case .calendar: .calendarEvent
        case .reminder: .reminder
        }
    }

    public var timeZoneIdentifier: String {
        switch self {
        case .calendar(_, _, let identifier), .reminder(_, let identifier): identifier
        }
    }
}

public enum ActionValidationError: Error, Sendable, Equatable {
    case invalidRevision
    case invalidTarget
    case emptyTitle
    case contentTooLong
    case reservedMarker
    case invalidSchedule
    case invalidTimeZone
}

/// The exact immutable payload a user reviewed. There is no attendee,
/// recurrence, existing-item edit, or delete field in this contract.
public struct ReviewedAction: Codable, Sendable, Equatable, Identifiable {
    public let operationID: UUID
    public let artifactID: UUID
    public let artifactRevision: Int
    public let target: ActionTargetSnapshot
    public let title: String
    public let notes: String
    public let schedule: ActionSchedule
    public var id: UUID { operationID }
    public var kind: ExternalActionKind { schedule.kind }

    public init(
        operationID: UUID = UUID(), artifactID: UUID, artifactRevision: Int,
        target: ActionTargetSnapshot, title: String, notes: String,
        schedule: ActionSchedule
    ) throws {
        guard artifactRevision >= 0 else { throw ActionValidationError.invalidRevision }
        guard !target.id.isEmpty, target.id.utf8.count <= 1_024,
              !target.title.isEmpty, target.title.utf8.count <= 2_048,
              target.kind == schedule.kind, target.allowsContentModifications
        else { throw ActionValidationError.invalidTarget }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActionValidationError.emptyTitle
        }
        guard title.utf8.count <= 1_024, notes.utf8.count <= 16_384 else {
            throw ActionValidationError.contentTooLong
        }
        guard !title.lowercased().contains(Self.markerPrefix),
              !notes.lowercased().contains(Self.markerPrefix)
        else { throw ActionValidationError.reservedMarker }
        guard TimeZone(identifier: schedule.timeZoneIdentifier) != nil else {
            throw ActionValidationError.invalidTimeZone
        }
        let normalizedSchedule: ActionSchedule
        func supportedDate(_ date: Date) -> Bool {
            // EventKit dates must be representable civil dates (years 1–9999),
            // not merely finite Double values that could provoke ObjC errors.
            (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970)
        }
        func millisecondDate(_ date: Date) -> Date {
            Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
        }
        switch schedule {
        case .calendar(let start, let end, _):
            guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
                  supportedDate(start), supportedDate(end),
                  (start.timeIntervalSince1970 * 1_000).isFinite,
                  (end.timeIntervalSince1970 * 1_000).isFinite,
                  millisecondDate(end) > millisecondDate(start) else { throw ActionValidationError.invalidSchedule }
            normalizedSchedule = .calendar(start: millisecondDate(start), end: millisecondDate(end), timeZoneIdentifier: schedule.timeZoneIdentifier)
        case .reminder(let dueDate, _):
            guard dueDate?.timeIntervalSince1970.isFinite != false,
                  dueDate.map(supportedDate) != false,
                  dueDate.map({ ($0.timeIntervalSince1970 * 1_000).isFinite }) != false
            else { throw ActionValidationError.invalidSchedule }
            normalizedSchedule = .reminder(dueDate: dueDate.map(millisecondDate), timeZoneIdentifier: schedule.timeZoneIdentifier)
        }
        self.operationID = operationID
        self.artifactID = artifactID
        self.artifactRevision = artifactRevision
        self.target = target
        self.title = title
        self.notes = notes
        // Freeze millisecond precision before review/hash generation, avoiding
        // unstable floating-point date roundtrips in persisted JSON.
        self.schedule = normalizedSchedule
    }

    private static let markerPrefix = "[macapy-operation:"
    public var operationMarker: String { "\(Self.markerPrefix)\(operationID.uuidString.lowercased())]" }
    /// Display this in review, too: the opaque recovery marker is the only
    /// addition to the reviewed notes that EventKit receives.
    public var externalNotes: String { notes.isEmpty ? operationMarker : notes + "\n\n" + operationMarker }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ReviewedAction {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Self.self, from: data)
    }

    public var intentHash: String {
        // Validation excludes nonfinite dates and all fields are encodable.
        // A failed encode is still represented distinctly; callers persist
        // with encoded() first and therefore fail before any dispatch.
        (try? encoded()).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "invalid"
    }

    private enum CodingKeys: String, CodingKey {
        case operationID, artifactID, artifactRevision, target, title, notes, schedule
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            operationID: values.decode(UUID.self, forKey: .operationID),
            artifactID: values.decode(UUID.self, forKey: .artifactID),
            artifactRevision: values.decode(Int.self, forKey: .artifactRevision),
            target: values.decode(ActionTargetSnapshot.self, forKey: .target),
            title: values.decode(String.self, forKey: .title),
            notes: values.decode(String.self, forKey: .notes),
            schedule: values.decode(ActionSchedule.self, forKey: .schedule)
        )
    }
}

public enum ActionAccess: String, Sendable, Equatable {
    case notDetermined, denied, restricted, writeOnly, fullAccess, unavailable
    public var canCreate: Bool { self == .writeOnly || self == .fullAccess }
    public var canRead: Bool { self == .fullAccess }
}

public struct ActionPermissionSnapshot: Sendable, Equatable {
    public let calendars: ActionAccess
    public let reminders: ActionAccess
    public init(calendars: ActionAccess, reminders: ActionAccess) {
        self.calendars = calendars
        self.reminders = reminders
    }

    public func canCreate(_ kind: ExternalActionKind) -> Bool {
        kind == .calendarEvent ? calendars.canCreate : reminders == .fullAccess
    }
}

public enum ActionFailure: String, Codable, Sendable, Equatable {
    case permissionDenied, targetUnavailable, targetChanged, cancelledBeforeDispatch
}

public enum ActionDispatchResult: Sendable, Equatable {
    case created(identifier: String)
    /// Known pre-save rejection; no platform save was attempted.
    case failed(ActionFailure)
    /// A save was attempted but its outcome cannot be proven. Never retry it.
    case unknown
}

public enum ActionReconciliationResult: Sendable, Equatable {
    case found(identifier: String)
    case notFound
    case ambiguous
    case readAccessRequired
    case unavailable
}

@MainActor
public protocol ExternalActionAdapter: AnyObject, Sendable {
    func permissionSnapshot() -> ActionPermissionSnapshot
    func targets(kind: ExternalActionKind) -> [ActionTargetSnapshot]
    func dispatch(_ action: ReviewedAction) async -> ActionDispatchResult
    func reconcile(_ action: ReviewedAction) async -> ActionReconciliationResult
}
