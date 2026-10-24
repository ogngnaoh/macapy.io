import ActionKit
import Foundation
import GRDB
import ProviderKit
import Testing

@testable import PersistKit

private actor UsageCallCounter {
    var count = 0
    func increment() { count += 1 }
}

private struct UsageFixtureReply: Codable, Equatable { let value: String }

private struct UsageFixtureProvider: LLMProvider {
    let counter: UsageCallCounter
    var operation: @Sendable () async throws -> Void = {}
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.transport("unused synthetic stream")) }
    }
    func completeReportingUsage<T: Decodable>(_ request: CompletionRequest, as type: T.Type) async throws -> CompletedCall<T> {
        await counter.increment()
        try await operation()
        return CompletedCall(value: try JSONDecoder().decode(type, from: Data(#"{"value":"complete"}"#.utf8)),
                             usage: TokenUsage(promptTokens: 100, cachedTokens: 0, completionTokens: 10))
    }
}

struct BackgroundUsageStoreTests {
    private struct Setup: Sendable {
        let database: MacapyDatabase
        let store: BackgroundUsageStore
        let ledger: SpendLedgerStore
        let meeting: MeetingRecord
    }
    private let now = Date()
    private let usage = TokenUsage(promptTokens: 100, cachedTokens: 0, completionTokens: 10)
    private let pricing = PricingTable(rates: ["synthetic": ModelPricing(inputPerMillionUSD: 1, cachedInputPerMillionUSD: 0, outputPerMillionUSD: 1)])

    private func setup(database: MacapyDatabase? = nil) async throws -> Setup {
        let database = try database ?? MacapyDatabase.inMemory()
        let meeting = try await MeetingStore(database: database).beginMeeting(startedAt: now, ephemeral: false)
        try await MeetingStore(database: database).endMeeting(id: meeting.id, endedAt: now.addingTimeInterval(60))
        try await MemoryStore(database: database).setOptIn(true, meetingID: meeting.id)
        return Setup(database: database, store: BackgroundUsageStore(database: database), ledger: SpendLedgerStore(database: database), meeting: meeting)
    }

    private func event(_ setup: Setup, item: String = "one", at: Date? = nil) async throws -> CalendarEventSnapshot {
        let start = at ?? now
        let event = try CalendarEventSnapshot(calendarID: "work", calendarItemID: item, title: "Synthetic brief event",
                                              startDate: start, endDate: start.addingTimeInterval(1_800), timeZoneIdentifier: "UTC", isAllDay: false)
        let briefs = BriefStore(database: setup.database)
        try await briefs.configure(.init(enabled: true, selectedCalendarIDs: ["work"], automaticAIEnabled: true))
        // A partial read adds this fixture without pruning other test events.
        try await briefs.synchronize(.init(state: .ready, events: [event], windowStart: start, windowEnd: start.addingTimeInterval(86_400), isTruncated: true), now: start)
        return event
    }

    private func admission(_ setup: Setup, cost: Double = 0.01, cap: Double? = 1, at: Date? = nil,
                           job: BackgroundUsageJob? = nil) -> UsageAdmission {
        UsageAdmission(scope: .meeting(setup.meeting.id), job: job, model: "synthetic", purpose: job == nil ? .generation : .memory,
                       estimatedCostUSD: cost, meetingCapUSD: cap, at: at ?? now)
    }

    private func brief(_ event: CalendarEventSnapshot, revision: String = "a", cost: Double = 0.01,
                       trigger: BackgroundUsageJob.Trigger = .automatic, at: Date? = nil) -> UsageAdmission {
        UsageAdmission(scope: .briefs, job: .init(id: event.id, revision: String(repeating: revision, count: 64), sourceRevision: event.revision, trigger: trigger),
                       model: "synthetic", purpose: .brief, estimatedCostUSD: cost, meetingCapUSD: nil, at: at ?? now)
    }

    @Test func separateActorsAtomicallyShareLiveAndMemoryMeetingCap() async throws {
        let setup = try await setup()
        let stores = [setup.store, BackgroundUsageStore(database: setup.database)]
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for store in stores {
                group.addTask {
                    do { _ = try await store.admit(admission(setup, cost: 0.60)); return true }
                    catch ProviderError.capReached { return false }
                    catch { Issue.record("Unexpected admission failure"); return false }
                }
            }
            var count = 0
            for await result in group where result { count += 1 }
            return count
        }
        #expect(accepted == 1)
        let memory = BackgroundUsageJob(id: setup.meeting.id.uuidString, revision: String(repeating: "a", count: 64))
        await #expect(throws: (any Error).self) { try await setup.store.admit(admission(setup, cost: 0.50, job: memory)) }
        #expect(try await setup.store.commitmentUSD(meetingID: setup.meeting.id) == 0.60)
    }

    @Test func existingLedgerSpendParticipatesWithoutRebookingOldEntries() async throws {
        let setup = try await setup()
        try await setup.ledger.record(.init(id: UUID(), meetingID: setup.meeting.id, model: "synthetic", usage: usage,
                                            estCostUSD: 0.75, purpose: .artifact, at: now))
        await #expect(throws: (any Error).self) { try await setup.store.admit(admission(setup, cost: 0.30)) }
        _ = try await setup.store.admit(admission(setup, cost: 0.20))
        #expect(try await setup.ledger.entries(meetingID: setup.meeting.id).count == 1)
        #expect(abs(try await setup.store.commitmentUSD(meetingID: setup.meeting.id) - 0.95) < 0.000001)
    }

    @Test func knownSettlementBooksExactlyOnceAndReplacesHoldWithFullActualCost() async throws {
        let setup = try await setup()
        let held = try await setup.store.admit(admission(setup))
        try await setup.store.markDispatched(id: held.id, at: now)
        let first = try await setup.store.settle(id: held.id, usage: usage, costUSD: 0.20, at: now)
        let repeated = try await setup.store.settle(id: held.id, usage: usage, costUSD: 0.20, at: now.addingTimeInterval(10))
        #expect(first == repeated)
        #expect(first?.id == held.id)
        #expect(try await setup.ledger.entries(meetingID: setup.meeting.id).count == 1)
        #expect(try await setup.store.commitmentUSD(meetingID: setup.meeting.id) == 0.20)
        await #expect(throws: DurableUsageError.settlementConflict) { try await setup.store.settle(id: held.id, usage: usage, costUSD: 0.10) }
    }

    @Test func cancellationBeforeDispatchReleasesCostButAfterDispatchRemainsUnknown() async throws {
        let setup = try await setup()
        let prepared = try await setup.store.admit(admission(setup))
        try await setup.store.cancel(id: prepared.id)
        #expect(try await setup.store.commitmentUSD(meetingID: setup.meeting.id) == 0)
        let dispatched = try await setup.store.admit(admission(setup))
        try await setup.store.markDispatched(id: dispatched.id, at: now)
        try await setup.store.cancel(id: dispatched.id)
        #expect(try await setup.store.uncertainUSD(meetingID: setup.meeting.id) == 0.01)
        #expect(try await setup.ledger.entries(meetingID: setup.meeting.id).isEmpty)
        await #expect(throws: DurableUsageError.invalidState) { try await setup.store.markDispatched(id: dispatched.id, at: now) }
    }

    @Test func automaticMemoryRevisionCannotReplayButExplicitRetryStillSharesCap() async throws {
        let setup = try await setup()
        let job = BackgroundUsageJob(id: setup.meeting.id.uuidString, revision: String(repeating: "b", count: 64))
        let first = try await setup.store.admit(admission(setup, cost: 0.60, job: job))
        try await setup.store.markDispatched(id: first.id, at: now)
        try await setup.store.settle(id: first.id, usage: nil, costUSD: nil)
        await #expect(throws: DurableUsageError.duplicateJob) { try await setup.store.admit(admission(setup, cost: 0.10, job: job)) }
        let retry = BackgroundUsageJob(id: job.id, revision: job.revision, trigger: .userInitiated)
        await #expect(throws: (any Error).self) { try await setup.store.admit(admission(setup, cost: 0.50, job: retry)) }
        _ = try await setup.store.admit(admission(setup, cost: 0.30, job: retry))
        #expect(abs(try await setup.store.commitmentUSD(meetingID: setup.meeting.id) - 0.90) < 0.000001)
    }

    @Test func briefAutomaticCountIsDistinctFromExplicitRefreshAndCostsAlwaysApply() async throws {
        let setup = try await setup()
        for index in 0..<5 {
            let value = try await event(setup, item: "auto-\(index)")
            let held = try await setup.store.admit(brief(value, cost: 0))
            try await setup.store.cancel(id: held.id)
        }
        let sixth = try await event(setup, item: "sixth")
        await #expect(throws: DurableUsageError.automaticLimitReached) { try await setup.store.admit(brief(sixth, cost: 0)) }
        _ = try await setup.store.admit(brief(sixth, cost: 0.02, trigger: .userInitiated))
        let summary = try await setup.store.summary(now: now)
        #expect(summary.automaticCount == 5)
        #expect(summary.committedUSD == 0.02)
        #expect(summary.nextResetAt.timeIntervalSince(summary.dayStart) == 86_400)
        #expect(Int(summary.nextResetAt.timeIntervalSince1970) % 86_400 == 0)
    }

    @Test func automaticBriefConsentIsRequiredAtAdmissionAndAgainAtDispatch() async throws {
        let setup = try await setup()
        let value = try await event(setup)
        let briefs = BriefStore(database: setup.database)
        try await briefs.configure(.init(enabled: true, selectedCalendarIDs: ["work"]))
        await #expect(throws: DurableUsageError.sourceUnavailable) { try await setup.store.admit(brief(value)) }
        let explicit = try await setup.store.admit(brief(value, trigger: .userInitiated))
        try await setup.store.markDispatched(id: explicit.id, at: now)
        let another = try await event(setup, item: "automatic-consent")
        let automatic = try await setup.store.admit(brief(another))
        try await briefs.configure(.init(enabled: true, selectedCalendarIDs: ["work"]))
        await #expect(throws: DurableUsageError.sourceUnavailable) { try await setup.store.markDispatched(id: automatic.id, at: now) }
    }

    @Test func briefDebounceAndMeaningfulRevisionAreEnforcedAcrossStoreInstances() async throws {
        let setup = try await setup()
        let value = try await event(setup)
        let held = try await setup.store.admit(brief(value))
        try await setup.store.cancel(id: held.id)
        let reopenedStore = BackgroundUsageStore(database: setup.database)
        await #expect(throws: DurableUsageError.debounceActive) {
            try await reopenedStore.admit(brief(value, revision: "b", at: now.addingTimeInterval(599)))
        }
        await #expect(throws: DurableUsageError.duplicateJob) {
            try await reopenedStore.admit(brief(value, at: now.addingTimeInterval(600)))
        }
        _ = try await reopenedStore.admit(brief(value, revision: "b", at: now.addingTimeInterval(600)))
    }

    @Test func briefPerCallAndDailyCapsNeverClipReportedCost() async throws {
        let setup = try await setup()
        let value = try await event(setup)
        await #expect(throws: (any Error).self) { try await setup.store.admit(brief(value, cost: 0.02001)) }
        let held = try await setup.store.admit(brief(value))
        try await setup.store.markDispatched(id: held.id, at: now)
        try await setup.store.settle(id: held.id, usage: usage, costUSD: 0.095, at: now)
        let next = try await event(setup, item: "next")
        await #expect(throws: (any Error).self) { try await setup.store.admit(brief(next, trigger: .userInitiated)) }
        #expect(try await setup.store.summary(now: now).knownCostUSD == 0.095)
    }

    @Test func unknownChargesSurviveDayRolloverAndClockChangesCannotResetBudget() async throws {
        let setup = try await setup()
        let value = try await event(setup)
        let held = try await setup.store.admit(brief(value))
        try await setup.store.markDispatched(id: held.id, at: now)
        try await setup.store.settle(id: held.id, usage: nil, costUSD: nil)
        let tomorrow = now.addingTimeInterval(86_400)
        let future = try await setup.store.summary(now: tomorrow)
        #expect(future.heldCostUSD == 0.01 && future.automaticCount == 0)
        #expect(try await setup.store.summary(now: now).dayStart == future.dayStart)
        await #expect(throws: DurableUsageError.clockMovedBackwards) { try await setup.store.admit(brief(value, revision: "b", at: now)) }
    }

    @Test func eventDeletionErasesDetailsButNotCountsOrUnknownChargesAndLateResultsStayGone() async throws {
        let setup = try await setup()
        let value = try await event(setup)
        let held = try await setup.store.admit(brief(value))
        try await setup.store.markDispatched(id: held.id, at: now)
        try await BriefStore(database: setup.database).clearCalendarContent()
        let summary = try await setup.store.summary(now: now)
        #expect(summary.heldCostUSD == 0.01 && summary.automaticCount == 1)
        #expect(try await setup.store.settle(id: held.id, usage: usage, costUSD: 0.001) == nil)
        let privateRows = try await setup.database.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_attempts") }
        #expect(privateRows == 0)
        #expect(try await setup.ledger.allEntries().isEmpty)
        #expect(try await setup.store.summary(now: now.addingTimeInterval(86_400)).heldCostUSD == 0.01)
        try await setup.store.resetBudgets()
        #expect(try await setup.store.summary(now: now.addingTimeInterval(86_400)).committedUSD == 0)
    }

    @Test func settledDeletedEventChargeExpiresButDeletionDoesNotResetTodaysCap() async throws {
        let setup = try await setup()
        let value = try await event(setup)
        let held = try await setup.store.admit(brief(value))
        try await setup.store.markDispatched(id: held.id, at: now)
        try await setup.store.settle(id: held.id, usage: usage, costUSD: 0.01, at: now)
        try await BriefStore(database: setup.database).clearCalendarContent()
        #expect(try await setup.store.summary(now: now).knownCostUSD == 0.01)
        #expect(try await setup.ledger.allEntries().isEmpty)
        let tomorrow = try await setup.store.summary(now: now.addingTimeInterval(86_400))
        #expect(tomorrow.committedUSD == 0 && tomorrow.automaticCount == 0)
    }

    @Test func changedEventOrRevokedMemoryConsentPreventsDispatchAdmission() async throws {
        let setup = try await setup()
        let value = try await event(setup)
        let held = try await setup.store.admit(brief(value))
        try await setup.database.dbWriter.write { db in
            try db.execute(sql: "UPDATE brief_events SET revision='changed' WHERE id=?", arguments: [value.id])
        }
        await #expect(throws: DurableUsageError.sourceUnavailable) { try await setup.store.markDispatched(id: held.id, at: now) }
        let memory = try await setup.store.admit(admission(setup, job: .init(id: setup.meeting.id.uuidString, revision: String(repeating: "c", count: 64))))
        try await MemoryStore(database: setup.database).setOptIn(false, meetingID: setup.meeting.id)
        await #expect(throws: DurableUsageError.sourceUnavailable) { try await setup.store.markDispatched(id: memory.id, at: now) }
    }

    @Test func relaunchRecoversOnlyPossiblyDispatchedChargesAndNeverReopensAutomaticJobs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let setup = try await setup(database: MacapyDatabase.onDisk(at: url))
        let first = try await setup.store.admit(admission(setup, cost: 0.20))
        _ = try await setup.store.admit(admission(setup, cost: 0.30))
        try await setup.store.markDispatched(id: first.id, at: now)
        let reopened = try MacapyDatabase.onDisk(at: url)
        #expect(try await BackgroundUsageStore(database: reopened).commitmentUSD(meetingID: setup.meeting.id) == 0.20)
        #expect(try await BackgroundUsageStore(database: reopened).uncertainUSD(meetingID: setup.meeting.id) == 0.20)
    }

    @Test func admissionFailureBlocksUpstreamAndSettlementFailureKeepsCompletedResult() async throws {
        let setup = try await setup()
        let counter = UsageCallCounter()
        let provider = MeteredProvider(upstream: UsageFixtureProvider(counter: counter),
            meter: SpendMeter(ledger: setup.ledger, pricing: pricing, capUSD: 1), meetingID: setup.meeting.id)
        let request = CompletionRequest(model: "synthetic", messages: [.user("Synthetic input")], purpose: .generation, maxTokens: 100)
        try await setup.database.dbWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_admission BEFORE INSERT ON usage_attempts BEGIN SELECT RAISE(ABORT,'synthetic admission failure'); END")
        }
        await #expect(throws: (any Error).self) { try await provider.complete(request, as: UsageFixtureReply.self) }
        #expect(await counter.count == 0)
        try await setup.database.dbWriter.write { db in
            try db.execute(sql: "DROP TRIGGER fail_admission; CREATE TRIGGER fail_booking BEFORE INSERT ON spend_ledger BEGIN SELECT RAISE(ABORT,'synthetic settlement failure'); END")
        }
        #expect(try await provider.complete(request, as: UsageFixtureReply.self).value == "complete")
        #expect(await counter.count == 1)
        #expect(try await setup.ledger.allEntries().isEmpty)
        #expect(try await setup.store.uncertainUSD(meetingID: setup.meeting.id) > 0)
    }

    @Test func finalContextFenceRefusesProviderAndConservativelyRetainsPotentialDispatch() async throws {
        let setup = try await setup()
        let counter = UsageCallCounter()
        let provider = MeteredProvider(upstream: UsageFixtureProvider(counter: counter),
            meter: SpendMeter(ledger: setup.ledger, pricing: pricing, capUSD: 1), meetingID: setup.meeting.id,
            beforeDispatch: { false })
        let request = CompletionRequest(model: "synthetic", messages: [.user("Synthetic input")], purpose: .generation, maxTokens: 100)
        await #expect(throws: CancellationError.self) { try await provider.complete(request, as: UsageFixtureReply.self) }
        #expect(await counter.count == 0)
        #expect(try await setup.store.uncertainUSD(meetingID: setup.meeting.id) > 0)
    }

    @Test func failedDurableDispatchMarkerPreventsProviderAndReleasesPreparedHold() async throws {
        let setup = try await setup()
        let counter = UsageCallCounter()
        let provider = MeteredProvider(upstream: UsageFixtureProvider(counter: counter),
            meter: SpendMeter(ledger: setup.ledger, pricing: pricing, capUSD: 1), meetingID: setup.meeting.id)
        try await setup.database.dbWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_dispatch BEFORE UPDATE OF state ON usage_attempts WHEN NEW.state='dispatching' BEGIN SELECT RAISE(ABORT,'synthetic dispatch marker failure'); END")
        }
        let request = CompletionRequest(model: "synthetic", messages: [.user("Synthetic input")], purpose: .generation, maxTokens: 100)
        await #expect(throws: (any Error).self) { try await provider.complete(request, as: UsageFixtureReply.self) }
        #expect(await counter.count == 0)
        #expect(try await setup.store.commitmentUSD(meetingID: setup.meeting.id) == 0)
        let state = try await setup.database.dbWriter.read { db in try String.fetchOne(db, sql: "SELECT state FROM usage_attempts") }
        #expect(state == "cancelled")
    }

    @Test func copiedProviderChainsValidationWithoutDoubleAdmissionOrLosingOriginalFence() async throws {
        let setup = try await setup()
        let upstreamCalls = UsageCallCounter()
        let checks = UsageCallCounter()
        let original = MeteredProvider(upstream: UsageFixtureProvider(counter: upstreamCalls),
            meter: SpendMeter(ledger: setup.ledger, pricing: pricing, capUSD: 1), meetingID: setup.meeting.id,
            beforeDispatch: { await checks.increment(); return true })
        let fenced = original.requiringDispatchValidation { await checks.increment(); return false }
        let request = CompletionRequest(model: "synthetic", messages: [.user("Synthetic input")], purpose: .generation, maxTokens: 100)
        await #expect(throws: CancellationError.self) { try await fenced.complete(request, as: UsageFixtureReply.self) }
        #expect(await upstreamCalls.count == 0)
        #expect(await checks.count == 2)
        let admissions = try await setup.database.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_attempts") }
        #expect(admissions == 1)
    }

    @Test func unpricedBackgroundAndMissingOrEphemeralSourceCannotAdmit() async throws {
        let setup = try await setup()
        let value = try await event(setup)
        let unpriced = UsageAdmission(scope: .briefs,
            job: .init(id: value.id, revision: String(repeating: "a", count: 64), sourceRevision: value.revision),
            model: "unpriced", purpose: .brief, estimatedCostUSD: nil, meetingCapUSD: nil, at: now)
        await #expect(throws: DurableUsageError.unpricedBackgroundModel) { try await setup.store.admit(unpriced) }
        try await setup.database.dbWriter.write { db in
            try db.execute(sql: "UPDATE meetings SET ephemeral=1 WHERE id=?", arguments: [setup.meeting.id])
        }
        let memory = admission(setup, job: .init(id: setup.meeting.id.uuidString, revision: String(repeating: "b", count: 64)))
        await #expect(throws: DurableUsageError.sourceUnavailable) { try await setup.store.admit(memory) }
        let missing = UsageAdmission(scope: .meeting(UUID()), model: "synthetic", purpose: .generation,
                                     estimatedCostUSD: 0.01, meetingCapUSD: 1, at: now)
        await #expect(throws: DurableUsageError.sourceUnavailable) { try await setup.store.admit(missing) }
    }

    @Test func realInFlightMeetingDeletionCannotDestroyCompletedProviderResultOrResurrectReceipt() async throws {
        let setup = try await setup()
        let counter = UsageCallCounter()
        let upstream = UsageFixtureProvider(counter: counter, operation: {
            try await MeetingStore(database: setup.database).deleteMeeting(id: setup.meeting.id)
        })
        let provider = MeteredProvider(upstream: upstream, meter: SpendMeter(ledger: setup.ledger, pricing: pricing, capUSD: 1), meetingID: setup.meeting.id)
        let request = CompletionRequest(model: "synthetic", messages: [.user("Synthetic input")], purpose: .generation, maxTokens: 100)
        #expect(try await provider.complete(request, as: UsageFixtureReply.self).value == "complete")
        #expect(try await setup.ledger.allEntries().isEmpty)
        let rows = try await setup.database.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_attempts") }
        #expect(rows == 0)
    }
}
