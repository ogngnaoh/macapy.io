import ActionKit
import Foundation
import GRDB
import Testing

@testable import PersistKit

struct ActionJournalTests {
    private struct Setup: Sendable {
        let database: MacapyDatabase
        let meeting: MeetingRecord
        let artifact: ArtifactRecord
        let journal: ActionJournalStore
    }

    private func setup(database: MacapyDatabase? = nil) async throws -> Setup {
        let database = try database ?? MacapyDatabase.inMemory()
        let meeting = try await MeetingStore(database: database).beginMeeting(startedAt: Date(), ephemeral: false)
        let artifacts = try await ArtifactStore(database: database).insertDrafts([
            DraftArtifact(kind: .actionItem, encoding: ActionItemPayload(title: "Review the synthetic draft", owner: nil, deadline: nil))
        ], meetingID: meeting.id)
        return Setup(database: database, meeting: meeting, artifact: artifacts[0], journal: ActionJournalStore(database: database))
    }

    private func review(_ setup: Setup, operationID: UUID = UUID(), title: String = "Review the synthetic draft", targetID: String = "work") throws -> ReviewedAction {
        try ReviewedAction(
            operationID: operationID, artifactID: setup.artifact.id, artifactRevision: setup.artifact.revision,
            target: .init(id: targetID, title: "Work", kind: .calendarEvent, allowsContentModifications: true),
            title: title, notes: "Synthetic note", schedule: .calendar(
                start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_003_600), timeZoneIdentifier: "America/New_York"))
    }

    @Test func preparationPersistsExactReviewAndIsIdempotentWithoutDispatch() async throws {
        let setup = try await setup()
        let action = try review(setup)
        let prepared = try await setup.journal.prepare(action)
        #expect(prepared.action == action)
        #expect(prepared.status == .prepared)
        #expect(prepared.dispatchedAt == nil)
        #expect(prepared.externalIdentifier == nil)
        #expect(try await setup.journal.prepare(action) == prepared)
        #expect(try await setup.journal.records(for: action.artifactID).count == 1)
    }

    @Test func operationReuseCannotChangeTheReviewedPayload() async throws {
        let setup = try await setup()
        let action = try review(setup)
        try await setup.journal.prepare(action)
        let modified = try review(setup, operationID: action.operationID, title: "Changed after review")
        await #expect(throws: ActionJournalError.intentConflict) { try await setup.journal.prepare(modified) }
        await #expect(throws: ActionJournalError.intentConflict) {
            try await setup.journal.admit(operationID: action.operationID, expectedHash: modified.intentHash)
        }
        #expect(try await setup.journal.record(operationID: action.operationID)?.status == .prepared)
    }

    @Test func aSecondOperationIDDoesNotBypassDuplicateProtection() async throws {
        let setup = try await setup()
        try await setup.journal.prepare(review(setup))
        await #expect(throws: ActionJournalError.alreadyPreparedOrDispatched) {
            try await setup.journal.prepare(review(setup))
        }
        // Distinct user-reviewed destinations are separate per-item operations.
        try await setup.journal.prepare(review(setup, targetID: "another-target"))
        #expect(try await setup.journal.records(for: setup.artifact.id).count == 2)
    }

    @Test func separateStoreActorsCompeteForExactlyOneAdmission() async throws {
        let setup = try await setup()
        let action = try review(setup)
        try await setup.journal.prepare(action)
        let anotherJournal = ActionJournalStore(database: setup.database)
        let admissions = await withTaskGroup(of: Bool.self) { group in
            for journal in [setup.journal, anotherJournal] {
                group.addTask {
                    do {
                        _ = try await journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
                        return true
                    } catch ActionJournalError.alreadyPreparedOrDispatched { return false }
                    catch { Issue.record("Unexpected admission failure"); return false }
                }
            }
            var successes = 0
            for await admitted in group where admitted { successes += 1 }
            return successes
        }
        #expect(admissions == 1)
        #expect(try await setup.journal.record(operationID: action.operationID)?.status == .dispatching)
    }

    @Test func editAfterReviewPreventsBothPreparationAndDispatchAdmission() async throws {
        let setup = try await setup()
        let action = try review(setup)
        try await setup.journal.prepare(action)
        _ = try await ArtifactStore(database: setup.database).edit(
            id: setup.artifact.id, expectedRevision: setup.artifact.revision,
            content: .actionItem(title: "Edited later", owner: nil, deadline: nil))
        await #expect(throws: ActionJournalError.revisionConflict) {
            try await setup.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        }
        await #expect(throws: ActionJournalError.revisionConflict) { try await setup.journal.prepare(action) }
    }

    @Test func approvalAloneDoesNotPrepareAnyExternalAction() async throws {
        let setup = try await setup()
        try await ArtifactStore(database: setup.database).setStatus(.approved, id: setup.artifact.id)
        #expect(try await setup.journal.records(for: setup.artifact.id).isEmpty)
    }

    @Test func ephemeralSourceCannotPrepareAnExternalAction() async throws {
        let setup = try await setup()
        try await setup.database.dbWriter.write { db in
            try db.execute(sql: "UPDATE meetings SET ephemeral = 1 WHERE id = ?", arguments: [setup.meeting.id])
        }
        await #expect(throws: ActionJournalError.ephemeralSource) { try await setup.journal.prepare(review(setup)) }
        #expect(try await setup.journal.records(for: setup.artifact.id).isEmpty)
    }

    @Test func unknownOutcomeCannotBeRetriedEvenWhenReadbackFindsNothing() async throws {
        let setup = try await setup()
        let action = try review(setup)
        try await setup.journal.prepare(action)
        _ = try await setup.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        try await setup.journal.finish(operationID: action.operationID, expectedHash: action.intentHash, result: .unknown)
        for outcome in [ActionReconciliationResult.notFound, .ambiguous, .readAccessRequired, .unavailable] {
            let row = try await setup.journal.recordReconciliation(operationID: action.operationID, expectedHash: action.intentHash, result: outcome)
            #expect(row?.status == .needsReconciliation)
        }
        await #expect(throws: ActionJournalError.alreadyPreparedOrDispatched) {
            try await setup.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        }
        await #expect(throws: ActionJournalError.alreadyPreparedOrDispatched) {
            try await setup.journal.prepare(review(setup))
        }
        let found = try await setup.journal.recordReconciliation(operationID: action.operationID, expectedHash: action.intentHash, result: .found(identifier: "existing-event"))
        #expect(found?.status == .created)
        #expect(found?.externalIdentifier == "existing-event")
    }

    @Test func knownPreSaveFailureAllowsANewExplicitReviewButNeverReadmitsOldOperation() async throws {
        let setup = try await setup()
        let action = try review(setup)
        try await setup.journal.prepare(action)
        _ = try await setup.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        try await setup.journal.finish(operationID: action.operationID, expectedHash: action.intentHash, result: .failed(.permissionDenied))
        await #expect(throws: ActionJournalError.alreadyPreparedOrDispatched) {
            try await setup.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        }
        let newReview = try review(setup)
        #expect(try await setup.journal.prepare(newReview).status == .prepared)
        #expect(try await setup.journal.records(for: action.artifactID).count == 2)
    }

    @Test func successfulSettlementIsFinalAndPreservesReturnedIdentifier() async throws {
        let setup = try await setup()
        let action = try review(setup)
        try await setup.journal.prepare(action)
        _ = try await setup.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        let result = try await setup.journal.finish(operationID: action.operationID, expectedHash: action.intentHash, result: .created(identifier: "created-event"))
        #expect(result?.status == .created)
        #expect(result?.externalIdentifier == "created-event")
        await #expect(throws: ActionJournalError.invalidState) {
            try await setup.journal.finish(operationID: action.operationID, expectedHash: action.intentHash, result: .unknown)
        }
    }

    @Test func interruptionRecoveryMarksOnlyAdmittedOperationsUnknown() async throws {
        let setup = try await setup()
        let admitted = try review(setup)
        let untouched = try review(setup, targetID: "another-target")
        try await setup.journal.prepare(admitted)
        try await setup.journal.prepare(untouched)
        _ = try await setup.journal.admit(operationID: admitted.operationID, expectedHash: admitted.intentHash)
        try await setup.journal.recoverInterruptedDispatches()
        #expect(try await setup.journal.record(operationID: admitted.operationID)?.status == .needsReconciliation)
        #expect(try await setup.journal.record(operationID: untouched.operationID)?.status == .prepared)
        #expect(try await setup.journal.unresolvedRecords().map(\.id) == [admitted.operationID])
    }

    @Test func reopeningAnOnDiskDatabaseRecoversInterruptedDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.sqlite")
        let first = try await setup(database: MacapyDatabase.onDisk(at: url))
        let action = try review(first)
        try await first.journal.prepare(action)
        _ = try await first.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        // A separate pool observes the committed pre-save journal; reopening
        // invokes the composition-owned recovery hook without needing EventKit.
        let reopened = try MacapyDatabase.onDisk(at: url)
        let recovered = try await ActionJournalStore(database: reopened).record(operationID: action.operationID)
        #expect(recovered?.status == .needsReconciliation)
        #expect(recovered?.externalIdentifier == nil)
    }

    @Test func journalWriteFailureLeavesNoDispatchableIntent() async throws {
        let setup = try await setup()
        try await setup.database.dbWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_action BEFORE INSERT ON action_journal BEGIN SELECT RAISE(ABORT,'synthetic storage failure'); END")
        }
        let action = try review(setup)
        await #expect(throws: (any Error).self) { try await setup.journal.prepare(action) }
        #expect(try await setup.journal.record(operationID: action.operationID) == nil)
        await #expect(throws: ActionJournalError.notFound) {
            try await setup.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        }
    }

    @Test func settlementFailureRemainsUnknownAfterRecoveryRatherThanRetryable() async throws {
        let setup = try await setup()
        let action = try review(setup)
        try await setup.journal.prepare(action)
        _ = try await setup.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        try await setup.database.dbWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_settlement BEFORE UPDATE ON action_journal WHEN NEW.status='created' BEGIN SELECT RAISE(ABORT,'synthetic settlement failure'); END")
        }
        await #expect(throws: (any Error).self) {
            try await setup.journal.finish(operationID: action.operationID, expectedHash: action.intentHash, result: .created(identifier: "platform-saved"))
        }
        #expect(try await setup.journal.record(operationID: action.operationID)?.status == .dispatching)
        try await setup.journal.recoverInterruptedDispatches()
        #expect(try await setup.journal.record(operationID: action.operationID)?.status == .needsReconciliation)
        await #expect(throws: ActionJournalError.alreadyPreparedOrDispatched) {
            try await setup.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        }
    }

    @Test func rejectedSourceOrTamperedJournalCannotBeDispatched() async throws {
        let setup = try await setup()
        let action = try review(setup)
        try await setup.journal.prepare(action)
        try await ArtifactStore(database: setup.database).setStatus(.rejected, id: setup.artifact.id)
        await #expect(throws: ActionJournalError.sourceRejected) {
            try await setup.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        }
        try await setup.database.dbWriter.write { db in
            try db.execute(sql: "UPDATE action_journal SET intentHash='tampered' WHERE operationID=?", arguments: [action.operationID])
        }
        await #expect(throws: ActionJournalError.corruptRecord) {
            try await setup.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        }
    }

    @Test func sourceDeletionCascadesJournalAndLateResultCannotResurrectIt() async throws {
        let setup = try await setup()
        let action = try review(setup)
        try await setup.journal.prepare(action)
        _ = try await setup.journal.admit(operationID: action.operationID, expectedHash: action.intentHash)
        try await MeetingStore(database: setup.database).deleteMeeting(id: setup.meeting.id)
        #expect(try await setup.journal.record(operationID: action.operationID) == nil)
        #expect(try await setup.journal.finish(operationID: action.operationID, expectedHash: action.intentHash, result: .created(identifier: "late-event")) == nil)
    }

    @Test func deletingJournalPurgesRecoverySnapshotFirst() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = directory.appendingPathComponent("synthetic.pre-migration")
        try Data("synthetic snapshot".utf8).write(to: snapshot)
        let inMemory = try MacapyDatabase.inMemory()
        let database = MacapyDatabase(dbWriter: inMemory.dbWriter, migrationSnapshotURL: snapshot)
        let setup = try await setup(database: database)
        try await setup.journal.prepare(review(setup))
        try await setup.journal.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        #expect(try await setup.journal.records(for: setup.artifact.id).isEmpty)
    }
}
