import Foundation
import ProviderKit
import Testing

@testable import PersistKit

/// Acceptance check 6, database half: ledger rows round-trip through schema v2,
/// per-meeting totals are correct, and deleting a meeting takes its spend rows
/// with it (milestone exit criterion 5's cascade).
struct SpendLedgerStoreTests {

    private func entry(
        meetingID: UUID?,
        cost: Double?,
        purpose: Purpose = .generation,
        at: Date = Date(timeIntervalSinceReferenceDate: 0),
        model: String = "deepseek-reasoner"
    ) -> SpendEntry {
        SpendEntry(
            id: UUID(),
            meetingID: meetingID,
            model: model,
            usage: TokenUsage(promptTokens: 1_000, cachedTokens: 400, completionTokens: 200),
            estCostUSD: cost,
            purpose: purpose,
            at: at
        )
    }

    @Test func recordedEntryRoundTripsWithEveryField() async throws {
        let database = try MacapyDatabase.inMemory()
        let store = MeetingStore(database: database)
        let ledger = SpendLedgerStore(database: database)
        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)

        let written = entry(meetingID: meeting.id, cost: 0.0123, purpose: .artifact)
        try await ledger.record(written)

        let entries = try await ledger.entries(meetingID: meeting.id)
        #expect(entries.count == 1)
        let read = try #require(entries.first)
        #expect(read.id == written.id)
        #expect(read.model == "deepseek-reasoner")
        #expect(read.usage == TokenUsage(promptTokens: 1_000, cachedTokens: 400, completionTokens: 200))
        #expect(read.estCostUSD == 0.0123)
        #expect(read.purpose == .artifact)
    }

    @Test func totalCostSumsOnlyThatMeetingsRows() async throws {
        let database = try MacapyDatabase.inMemory()
        let store = MeetingStore(database: database)
        let ledger = SpendLedgerStore(database: database)
        let mine = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        let theirs = try await store.beginMeeting(startedAt: Date(), ephemeral: false)

        try await ledger.record(entry(meetingID: mine.id, cost: 0.10))
        try await ledger.record(entry(meetingID: mine.id, cost: 0.05))
        try await ledger.record(entry(meetingID: theirs.id, cost: 9.99))

        let total = try await ledger.totalCostUSD(meetingID: mine.id)
        #expect(abs(total - 0.15) < 1e-9)
    }

    @Test func rowsWithUnknownCostContributeNothingButAreStillStored() async throws {
        let database = try MacapyDatabase.inMemory()
        let store = MeetingStore(database: database)
        let ledger = SpendLedgerStore(database: database)
        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)

        try await ledger.record(entry(meetingID: meeting.id, cost: 0.25))
        try await ledger.record(entry(meetingID: meeting.id, cost: nil, model: "some-unpriced-model"))

        let total = try await ledger.totalCostUSD(meetingID: meeting.id)
        let entries = try await ledger.entries(meetingID: meeting.id)
        #expect(abs(total - 0.25) < 1e-9)
        #expect(entries.count == 2, "an unpriced call is still a call the user made")
        #expect(entries.contains { $0.estCostUSD == nil })
    }

    @Test func deletingAMeetingCascadesToItsSpendRows() async throws {
        let database = try MacapyDatabase.inMemory()
        let store = MeetingStore(database: database)
        let ledger = SpendLedgerStore(database: database)
        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        try await ledger.record(entry(meetingID: meeting.id, cost: 0.10))

        try await store.deleteMeeting(id: meeting.id)

        let entries = try await ledger.entries(meetingID: meeting.id)
        #expect(entries.isEmpty)
    }

    @Test func entriesComeBackOldestFirst() async throws {
        let database = try MacapyDatabase.inMemory()
        let store = MeetingStore(database: database)
        let ledger = SpendLedgerStore(database: database)
        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)

        let later = entry(meetingID: meeting.id, cost: 0.02, at: Date(timeIntervalSinceReferenceDate: 100))
        let earlier = entry(meetingID: meeting.id, cost: 0.01, at: Date(timeIntervalSinceReferenceDate: 50))
        try await ledger.record(later)
        try await ledger.record(earlier)

        let entries = try await ledger.entries(meetingID: meeting.id)
        #expect(entries.map(\.id) == [earlier.id, later.id])
    }

    @Test func aCallOutsideAMeetingIsStillRecorded() async throws {
        // The Providers screen's "test connection" spends real money before any
        // meeting exists; it must show up in the ledger.
        let database = try MacapyDatabase.inMemory()
        let ledger = SpendLedgerStore(database: database)

        try await ledger.record(entry(meetingID: nil, cost: 0.001))

        let all = try await ledger.allEntries()
        #expect(all.count == 1)
        #expect(all.first?.meetingID == nil)
    }

    @Test func schemaV2LeavesTheV1TablesWorking() async throws {
        // Migrations are additive and forward-only (SPEC §9): adding the ledger
        // must not disturb meetings/segments.
        let database = try MacapyDatabase.inMemory()
        let store = MeetingStore(database: database)

        let meeting = try await store.beginMeeting(startedAt: Date(), ephemeral: false)
        try await store.endMeeting(id: meeting.id, endedAt: Date())

        #expect(try await store.listMeetings().count == 1)
    }
}
