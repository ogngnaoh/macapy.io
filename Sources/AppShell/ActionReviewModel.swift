import ActionKit
import Foundation
import Observation
import PersistKit

/// Owns one explicit approval. Dismissing its sheet does not cancel settlement
/// after EventKit may have written; the journal survives the presentation.
@MainActor
@Observable
final class ActionReviewModel: Identifiable {
    let id = UUID()
    let artifact: ArtifactRecord
    let kind: ExternalActionKind
    let isSample: Bool
    var title: String
    var notes = ""
    var targetID = ""
    var start: Date
    var end: Date
    var hasDueDate = false
    var timeZoneIdentifier = TimeZone.current.identifier
    private(set) var targets: [ActionTargetSnapshot] = []
    private(set) var canCreate = false
    private(set) var reviewed: ReviewedAction?
    private(set) var records: [ActionJournalRecord] = []
    private(set) var isBusy = false
    private(set) var message: String?
    private(set) var succeeded = false

    @ObservationIgnored private let journal: ActionJournalStore
    @ObservationIgnored private let adapter: any ExternalActionAdapter
    @ObservationIgnored private let requestAccess: @MainActor (Bool) async throws -> Bool

    init(artifact: ArtifactRecord, kind: ExternalActionKind, journal: ActionJournalStore,
         adapter: any ExternalActionAdapter, now: Date = Date(), isSample: Bool = false,
         requestAccess: @escaping @MainActor (Bool) async throws -> Bool) {
        self.artifact = artifact
        self.kind = kind
        self.isSample = isSample
        self.journal = journal
        self.adapter = adapter
        self.requestAccess = requestAccess
        self.title = artifact.payload(as: ActionItemPayload.self)?.title ?? ""
        self.start = now.addingTimeInterval(3_600)
        self.end = now.addingTimeInterval(5_400)
    }

    func load() async {
        refreshPermissions()
        do { records = try await journal.records(for: artifact.id).filter { $0.action.target.kind == kind } }
        catch { message = "The action history could not be read. Reopen this item before creating anything."; canCreate = false }
    }

    private func refreshPermissions() {
        canCreate = adapter.permissionSnapshot().canCreate(kind)
        targets = adapter.targets(kind: kind)
        if !targets.contains(where: { $0.id == targetID }) { targetID = targets.first?.id ?? "" }
    }

    func grantAccess(forReconciliation: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let allowed = try await requestAccess(forReconciliation)
            message = allowed ? nil : "Access was not granted. You can change it in macOS Privacy & Security settings."
        } catch { message = "macOS could not grant access. Check Privacy & Security settings and try again." }
        refreshPermissions()
    }

    func prepareReview() {
        guard !isBusy, canCreate, let target = targets.first(where: { $0.id == targetID }) else {
            message = "Choose an available destination first."; return
        }
        do {
            let schedule: ActionSchedule = kind == .calendarEvent
                ? .calendar(start: start, end: end, timeZoneIdentifier: timeZoneIdentifier)
                : .reminder(dueDate: hasDueDate ? start : nil, timeZoneIdentifier: timeZoneIdentifier)
            reviewed = try ReviewedAction(artifactID: artifact.id, artifactRevision: artifact.revision,
                target: target, title: title, notes: notes, schedule: schedule)
            message = nil
        } catch { message = "Check the title, destination, time zone and dates. The end must be after the start." }
    }

    func editReview() { guard !isBusy else { return }; reviewed = nil; message = nil }

    /// The button invokes this in an owned Task, never a view .task. No
    /// cancellation checkpoint is allowed between dispatch and settlement.
    func approveAndCreate() async {
        guard !isBusy, !succeeded, let reviewed else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await journal.prepare(reviewed)
            let persisted = try await journal.admit(operationID: reviewed.operationID, expectedHash: reviewed.intentHash)
            let result = await adapter.dispatch(persisted)
            do {
                let settled = try await journal.finish(operationID: persisted.operationID, expectedHash: persisted.intentHash, result: result)
                switch result {
                case .created:
                    succeeded = true
                    message = settled == nil ? "Created. The local source was removed while this action was finishing." : "Created in \(persisted.target.title)."
                case .failed:
                    message = "Nothing was created. Access or the destination changed. Close this review and try again."
                case .unknown:
                    message = "The outcome could not be confirmed. Do not create it again. Check the destination, or use Check outcome below."
                }
            } catch {
                // Leave dispatching durable; launch recovery turns it into
                // needsReconciliation. Never turn an uncertain save into retry.
                message = "The action may have been created, but its receipt could not be saved. Do not create it again. Reopen macapy to check its outcome."
            }
            records = (try? await journal.records(for: artifact.id).filter { $0.action.target.kind == kind }) ?? records
        } catch {
            switch error as? ActionJournalError {
            case .revisionConflict, .sourceRejected, .sourceNotFound:
                message = "This source changed or was removed. Close this review and review the current item."
            case .alreadyPreparedOrDispatched:
                message = "This action already has a saved attempt. Check its outcome before doing anything else."
            default:
                message = "Approval could not be saved. No external action was dispatched."
            }
        }
    }

    func reconcile(_ record: ActionJournalRecord) async {
        guard !isBusy, record.status == .needsReconciliation, record.action.target.kind == kind else { return }
        isBusy = true
        defer { isBusy = false }
        let result = await adapter.reconcile(record.action)
        do {
            _ = try await journal.recordReconciliation(operationID: record.id, expectedHash: record.intentHash, result: result)
            records = try await journal.records(for: artifact.id).filter { $0.action.target.kind == kind }
            switch result {
            case .found: message = "The existing item was found. No new item was created."
            case .readAccessRequired: message = "Reading this outcome requires separate permission. Use Allow outcome lookup, then check again."
            case .notFound: message = "No match was found. This does not prove the save failed; automatic retry remains blocked."
            case .ambiguous: message = "More than one match was found. Review the destination directly; automatic retry remains blocked."
            case .unavailable: message = "The destination could not be read. Your saved attempt remains unchanged."
            }
        } catch { message = "The outcome could not be saved. No new item was created." }
    }
}
