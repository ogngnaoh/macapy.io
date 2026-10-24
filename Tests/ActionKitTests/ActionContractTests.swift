import Foundation
import Testing

@testable import ActionKit

struct ActionContractTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func action(
        operationID: UUID = UUID(), artifactID: UUID = UUID(), revision: Int = 2,
        title: String = "Review the draft", notes: String = "Synthetic review notes",
        schedule: ActionSchedule? = nil
    ) throws -> ReviewedAction {
        let schedule = schedule ?? .calendar(start: start, end: start.addingTimeInterval(1_800), timeZoneIdentifier: "America/New_York")
        return try ReviewedAction(
            operationID: operationID, artifactID: artifactID, artifactRevision: revision,
            target: .init(id: "synthetic-target", title: "Work", kind: schedule.kind, allowsContentModifications: true),
            title: title, notes: notes, schedule: schedule)
    }

    @Test func reviewRoundTripPreservesExactPayloadAndRecoveryIdentity() throws {
        let reviewed = try action()
        let restored = try ReviewedAction.decode(reviewed.encoded())
        #expect(restored == reviewed)
        #expect(restored.intentHash == reviewed.intentHash)
        #expect(reviewed.intentHash.count == 64)
        #expect(reviewed.externalNotes == reviewed.notes + "\n\n" + reviewed.operationMarker)
        #expect(!reviewed.operationMarker.contains(reviewed.artifactID.uuidString))
    }

    @Test func hashChangesWhenExactReviewedContentChanges() throws {
        let operationID = UUID()
        let artifactID = UUID()
        let first = try action(operationID: operationID, artifactID: artifactID)
        let changed = try action(operationID: operationID, artifactID: artifactID, title: "A different title")
        #expect(first.intentHash != changed.intentHash)
    }

    @Test func rejectsAmbiguousMissingOrMalformedReviewFields() throws {
        #expect(throws: ActionValidationError.emptyTitle) { try action(title: " \n") }
        #expect(throws: ActionValidationError.invalidRevision) { try action(revision: -1) }
        #expect(throws: ActionValidationError.invalidTimeZone) {
            try action(schedule: .calendar(start: start, end: start.addingTimeInterval(1), timeZoneIdentifier: "Mars/Colony"))
        }
        #expect(throws: ActionValidationError.invalidSchedule) {
            try action(schedule: .calendar(start: start, end: start, timeZoneIdentifier: "UTC"))
        }
        #expect(throws: ActionValidationError.invalidSchedule) {
            try action(schedule: .reminder(dueDate: Date(timeIntervalSince1970: .infinity), timeZoneIdentifier: "UTC"))
        }
        #expect(throws: ActionValidationError.reservedMarker) {
            try action(notes: "Injected [MACAPY-OPERATION:unrelated]")
        }
    }

    @Test func decodingCannotBypassValidation() throws {
        let reviewed = try action()
        var json = try #require(JSONSerialization.jsonObject(with: reviewed.encoded()) as? [String: Any])
        json["title"] = ""
        #expect(throws: ActionValidationError.emptyTitle) {
            try ReviewedAction.decode(JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func absoluteCalendarDatesPreserveTheDSTOffsetBoundary() throws {
        let formatter = ISO8601DateFormatter()
        let before = try #require(formatter.date(from: "2026-11-01T05:30:00Z"))
        let after = try #require(formatter.date(from: "2026-11-01T06:30:00Z"))
        let reviewed = try action(schedule: .calendar(start: before, end: after, timeZoneIdentifier: "America/New_York"))
        #expect(try ReviewedAction.decode(reviewed.encoded()).schedule == reviewed.schedule)
        #expect(after.timeIntervalSince(before) == 3_600)
    }

    @Test func remindersCanExplicitlyHaveNoDueDate() throws {
        let reviewed = try action(schedule: .reminder(dueDate: nil, timeZoneIdentifier: "UTC"))
        #expect(reviewed.kind == .reminder)
        #expect(try ReviewedAction.decode(reviewed.encoded()) == reviewed)
    }

    @Test func fractionalDatesHaveStableHashesAcrossPersistence() throws {
        for offset in [0.00001, 0.123456, 0.999999] {
            let date = start.addingTimeInterval(offset)
            let reviewed = try action(schedule: .calendar(start: date, end: date.addingTimeInterval(1_800), timeZoneIdentifier: "UTC"))
            #expect(try ReviewedAction.decode(reviewed.encoded()).intentHash == reviewed.intentHash)
        }
    }

    @Test func remindersRequireFullAccessEvenIfAPlatformReportsWriteOnly() {
        let permissions = ActionPermissionSnapshot(calendars: .writeOnly, reminders: .writeOnly)
        #expect(permissions.canCreate(.calendarEvent))
        #expect(!permissions.canCreate(.reminder))
    }
}

@MainActor
private final class FakeActionPlatform: ActionPlatformStore {
    var access = ActionPermissionSnapshot(calendars: .writeOnly, reminders: .fullAccess)
    var availableTargets: [ActionTargetSnapshot] = []
    var permissionRequests: [ActionAccessRequest] = []
    var saved: [ReviewedAction] = []
    var identifier: String? = "synthetic-external-id"
    var throwsAfterSave = false
    var reconciliation: ActionReconciliationResult = .notFound
    var reconciliations = 0
    func permissions() -> ActionPermissionSnapshot { access }
    func targets(kind: ExternalActionKind) -> [ActionTargetSnapshot] { availableTargets.filter { $0.kind == kind } }
    func request(_ access: ActionAccessRequest) async throws -> Bool { permissionRequests.append(access); return true }
    func save(_ action: ReviewedAction) throws -> String? {
        saved.append(action)
        if throwsAfterSave { throw FakeFailure.ambiguous }
        return identifier
    }
    func reconcile(_ action: ReviewedAction) async -> ActionReconciliationResult {
        reconciliations += 1
        return reconciliation
    }
    func calendarSources() -> [CalendarSourceSnapshot] { [] }
    func events(calendarIDs: Set<String>, from: Date, to: Date, limit: Int) -> CalendarPlatformRead {
        CalendarPlatformRead(events: [], isTruncated: false)
    }
    enum FakeFailure: Error { case ambiguous }
}

@MainActor
struct EventKitActionAdapterTests {
    private func setup() throws -> (FakeActionPlatform, EventKitActionAdapter, ReviewedAction) {
        let target = ActionTargetSnapshot(id: "target", title: "Work", kind: .calendarEvent, allowsContentModifications: true)
        let action = try ReviewedAction(artifactID: UUID(), artifactRevision: 0, target: target,
                                        title: "Synthetic event", notes: "", schedule: .calendar(
                                            start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200), timeZoneIdentifier: "UTC"))
        let platform = FakeActionPlatform()
        platform.availableTargets = [target]
        return (platform, EventKitActionAdapter(platform: platform), action)
    }

    @Test func readAndDispatchNeverRequestPermissionsImplicitly() async throws {
        let (platform, adapter, action) = try setup()
        _ = adapter.permissionSnapshot()
        _ = adapter.targets(kind: .calendarEvent)
        #expect(await adapter.dispatch(action) == .created(identifier: "synthetic-external-id"))
        #expect(platform.saved == [action])
        #expect(platform.permissionRequests.isEmpty)
    }

    @Test func deniedOrRevokedAccessProducesKnownFailureWithoutSave() async throws {
        let (platform, adapter, action) = try setup()
        platform.access = .init(calendars: .denied, reminders: .denied)
        #expect(await adapter.dispatch(action) == .failed(.permissionDenied))
        #expect(platform.saved.isEmpty)
        #expect(platform.permissionRequests.isEmpty)
    }

    @Test func renamedTargetRequiresFreshReview() async throws {
        let (platform, adapter, action) = try setup()
        platform.availableTargets = [.init(id: action.target.id, title: "Renamed", kind: .calendarEvent, allowsContentModifications: true)]
        #expect(await adapter.dispatch(action) == .failed(.targetChanged))
        #expect(platform.saved.isEmpty)
    }

    @Test func thrownOrIdentifierlessSaveIsUnknownAndNeverRetried() async throws {
        let (platform, adapter, action) = try setup()
        platform.throwsAfterSave = true
        #expect(await adapter.dispatch(action) == .unknown)
        #expect(platform.saved.count == 1)
        platform.throwsAfterSave = false
        platform.identifier = nil
        #expect(await adapter.dispatch(action) == .unknown)
        #expect(platform.saved.count == 2, "Exactly one save per admitted call; the journal prevents calling again for this intent")
    }

    @Test func writeOnlyReconciliationExplainsReadAccessWithoutPromptOrFetch() async throws {
        let (platform, adapter, action) = try setup()
        #expect(await adapter.reconcile(action) == .readAccessRequired)
        #expect(platform.reconciliations == 0)
        #expect(platform.permissionRequests.isEmpty)
    }

    @Test func readReconciliationNeverPerformsAnotherWrite() async throws {
        let (platform, adapter, action) = try setup()
        platform.access = .init(calendars: .fullAccess, reminders: .fullAccess)
        platform.reconciliation = .found(identifier: "found-id")
        #expect(await adapter.reconcile(action) == .found(identifier: "found-id"))
        #expect(platform.reconciliations == 1)
        #expect(platform.saved.isEmpty)
    }

    @Test func permissionRequestsRequireExplicitMethods() async throws {
        let (platform, adapter, _) = try setup()
        #expect(try await adapter.requestCalendarWriteAccess())
        #expect(try await adapter.requestCalendarReadAccess())
        #expect(try await adapter.requestReminderAccess())
        #expect(platform.permissionRequests == [.calendarWrite, .calendarRead, .reminders])
        #expect(platform.saved.isEmpty)
    }
}
