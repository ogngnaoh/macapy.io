import Foundation
import ActionKit
import MemoryKit
import PersistKit
import Testing
@testable import AppShell

@MainActor struct SampleSessionTests {
    @Test func sampleSeedsOnlyItsPrivateDatabaseAndReentryResetsChanges() async throws {
        let first = try await SampleSession.make()
        #expect(first.database.migrationSnapshotURL == nil)
        #expect(try await first.meetings.listMeetings().count == 2)
        #expect(first.transcript.segments == SampleScenario.segments)
        #expect(first.copilot.canCatchUp)
        let detail = first.makeDetail(first.featuredMeeting)
        await detail.load()
        #expect(detail.artifacts.count == 4)
        try await first.meetings.deleteMeeting(id: first.featuredMeeting.id)
        first.close()
        let second = try await SampleSession.make()
        #expect(second.featuredMeeting.id == first.featuredMeeting.id)
        #expect(try await second.meetings.listMeetings().count == 2)
        second.close()
    }

    @Test func sampleMemoryAndDocumentsUseProductionReviewAndGroundedAnswerPaths() async throws {
        let sample = try await SampleSession.make()
        defer { sample.close() }
        await sample.memory.load()
        #expect(sample.memory.facts.count == 3)
        #expect(sample.memory.facts.filter { $0.status == .approved }.count == 2)
        #expect(sample.memory.linkedEntities.count == 3)
        #expect(sample.memory.documents.count == 1)
        #expect(sample.memory.documents.first?.allowedForAI == true)
        sample.memory.query = "Atlas launch"
        sample.memory.search(); await sample.memory.waitForOperations()
        let context = try #require(sample.memory.contextPreview)
        #expect(!context.isEmpty)
        sample.memory.sendQuestion(); await sample.memory.waitForOperations()
        let answer = try #require(sample.memory.answer)
        #expect(!answer.insufficientEvidence)
        #expect(context.containsOnlyValidCitations(answer.citationIDs))
        #expect(answer.text.contains("June 18"))
        await sample.memory.prepareExtraction()
        sample.memory.sendExtraction(); await sample.memory.waitForOperations()
        #expect(sample.memory.facts.count == 5)
        #expect(sample.memory.facts.filter { $0.status == .approved }.count == 2)
    }

    @Test func sampleBriefUsesFakeCalendarAndSourceLinkedLocalContext() async throws {
        let sample = try await SampleSession.make()
        defer { sample.close() }
        await sample.briefs.start()
        #expect(sample.briefs.events.count == 1)
        #expect(sample.briefs.calendars.first?.id == SampleCalendarReader.calendarID)
        let snapshot = try #require(sample.briefs.snapshot)
        #expect(snapshot.mode == .local)
        #expect(!snapshot.context.isEmpty)
        #expect(snapshot.context.containsOnlyValidCitations(snapshot.citationIDs))
        #expect(snapshot.text.contains("Atlas"))
        #expect(snapshot.event.startDate == SampleScenario.briefDate.addingTimeInterval(3_600))
        #expect(snapshot.context.excerpts.contains { $0.citationID.hasPrefix("document-") })
        #expect(try await sample.meetings.listMeetings().count == 2)
    }

    @Test func dismissingMemoryDoesNotInvalidateAnOpeningBrief() async throws {
        let sample = try await SampleSession.make()
        defer { sample.close() }
        await sample.memory.load()
        let opening = Task { await sample.briefs.start() }
        await Task.yield()
        sample.memory.cancelAndClear(notifySensitiveChange: false)
        await opening.value
        #expect(sample.briefs.events.count == 1)
        #expect(sample.briefs.snapshot != nil)
        // A real source mutation still invalidates the dependent text.
        sample.memory.cancelAndClear()
        #expect(sample.briefs.snapshot == nil)
    }

    @Test func sampleActionReviewOnlyWritesItsFakeAdapterAndTemporaryJournal() async throws {
        let sample = try await SampleSession.make()
        defer { sample.close() }
        let detail = sample.makeDetail(sample.featuredMeeting)
        await detail.load()
        let artifact = try #require(detail.actionItems.first)
        let review = try #require(detail.makeActionReview?(artifact, .reminder))
        #expect(review.isSample)
        await review.load()
        #expect(review.targets.first?.title == "Sample reminders")
        review.prepareReview()
        await review.approveAndCreate()
        #expect(review.succeeded)
        #expect(sample.sampleActions.created.count == 1)
        await review.approveAndCreate()
        #expect(sample.sampleActions.created.count == 1)
        #expect(review.records.count == 1)
        sample.close()
        #expect(sample.sampleActions.created.isEmpty)
        let reset = try await SampleSession.make()
        defer { reset.close() }
        #expect(reset.sampleActions.created.isEmpty)
        #expect(try await ActionJournalStore(database: reset.database).records(for: artifact.id).isEmpty)
    }

    @Test func sampleCloseClearsEveryWorkspaceSnapshot() async throws {
        let sample = try await SampleSession.make()
        await sample.memory.load(); await sample.briefs.start()
        #expect(!sample.memory.facts.isEmpty && sample.briefs.snapshot != nil)
        sample.close()
        #expect(sample.memory.facts.isEmpty && sample.memory.documents.isEmpty && sample.memory.entities.isEmpty)
        #expect(sample.memory.meetings.isEmpty && sample.memory.selectedMeetingID == nil)
        #expect(sample.briefs.snapshot == nil && sample.briefs.events.isEmpty && sample.briefs.calendars.isEmpty)
    }

    @Test func scriptedAnswerIsExplicitlyBoundedAndHasNaturalStop() async throws {
        let provider = SampleProvider()
        let request = ProviderKit.CompletionRequest(model: "scripted", messages: [.user("What is the launch plan?")], purpose: .generation)
        var output = ""
        var terminal = false
        for try await event in provider.stream(request) {
            switch event {
            case .token(let token): output += token
            case .completed(let completion): terminal = completion.finishReason == "stop"
            default: break
            }
        }
        #expect(terminal)
        #expect(output.contains("June 18"))
    }
}

import ProviderKit
