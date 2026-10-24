import ActionKit
import Foundation
import PersistKit
import Testing
@testable import AppShell

@MainActor
struct ActionReviewModelTests {
    private final class Adapter: ExternalActionAdapter {
        var dispatches: [ReviewedAction] = []
        var result: ActionDispatchResult = .created(identifier: "synthetic-item")
        var hold = false
        var continuation: CheckedContinuation<Void, Never>?
        func permissionSnapshot() -> ActionPermissionSnapshot { .init(calendars: .fullAccess, reminders: .fullAccess) }
        func targets(kind: ExternalActionKind) -> [ActionTargetSnapshot] {
            [.init(id: "synthetic", title: "Synthetic destination", kind: kind, allowsContentModifications: true)]
        }
        func dispatch(_ action: ReviewedAction) async -> ActionDispatchResult {
            dispatches.append(action)
            if hold { await withCheckedContinuation { continuation = $0 } }
            return result
        }
        func reconcile(_ action: ReviewedAction) async -> ActionReconciliationResult { .notFound }
    }

    private func setup() async throws -> (MacapyDatabase, ArtifactRecord, ActionJournalStore, Adapter, ActionReviewModel) {
        let database = try MacapyDatabase.inMemory()
        let meeting = try await MeetingStore(database: database).beginMeeting(startedAt: Date(), ephemeral: false)
        let artifact = try await ArtifactStore(database: database).insertDrafts([
            DraftArtifact(kind: .actionItem, encoding: ActionItemPayload(title: "Synthetic action", owner: nil, deadline: nil))
        ], meetingID: meeting.id)[0]
        let journal = ActionJournalStore(database: database)
        let adapter = Adapter()
        let model = ActionReviewModel(artifact: artifact, kind: .reminder, journal: journal, adapter: adapter,
                                     requestAccess: { _ in Issue.record("Unexpected permission request"); return false })
        await model.load()
        return (database, artifact, journal, adapter, model)
    }

    @Test func localReviewCannotWriteAndApprovalUsesFrozenFields() async throws {
        let (_, _, journal, adapter, model) = try await setup()
        model.notes = "Synthetic reviewed note"
        model.prepareReview()
        let reviewed = try #require(model.reviewed)
        #expect(adapter.dispatches.isEmpty)
        #expect(try await journal.records(for: model.artifact.id).isEmpty)
        model.title = "Changed after review"
        model.notes = "Changed after review"
        await model.approveAndCreate()
        #expect(adapter.dispatches == [reviewed])
        #expect(try await journal.record(operationID: reviewed.id)?.status == .created)
        #expect(model.succeeded)
    }

    @Test func concurrentClicksAndCancelledPresentationStillSettleOneSave() async throws {
        let (_, _, journal, adapter, model) = try await setup()
        adapter.hold = true
        model.prepareReview()
        let operationID = try #require(model.reviewed?.id)
        let first = Task { await model.approveAndCreate() }
        for _ in 0..<1_000 where adapter.continuation == nil { await Task.yield() }
        let continuation = try #require(adapter.continuation)
        await model.approveAndCreate()
        #expect(adapter.dispatches.count == 1)
        first.cancel()
        continuation.resume()
        await first.value
        #expect(try await journal.record(operationID: operationID)?.status == .created)
        #expect(model.succeeded)
    }

    @Test func editedSourceRefusesDispatch() async throws {
        let (database, artifact, _, adapter, model) = try await setup()
        model.prepareReview()
        _ = try await ArtifactStore(database: database).edit(id: artifact.id, expectedRevision: artifact.revision,
            content: .actionItem(title: "New source revision", owner: nil, deadline: nil))
        await model.approveAndCreate()
        #expect(adapter.dispatches.isEmpty)
        #expect(model.message?.contains("source changed") == true)
    }

    @Test func unknownCannotRetryEvenWhenLookupFindsNothing() async throws {
        let (_, _, journal, adapter, model) = try await setup()
        adapter.result = .unknown
        model.prepareReview()
        await model.approveAndCreate()
        let record = try #require(model.records.first)
        #expect(record.status == .needsReconciliation)
        await model.reconcile(record)
        await model.approveAndCreate()
        model.editReview()
        model.prepareReview()
        await model.approveAndCreate()
        #expect(adapter.dispatches.count == 1)
        #expect(try await journal.record(operationID: record.id)?.status == .needsReconciliation)
    }
}
