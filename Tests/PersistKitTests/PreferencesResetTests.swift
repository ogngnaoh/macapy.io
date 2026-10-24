import Foundation
import GRDB
import ProviderKit
import Testing
@testable import PersistKit

struct PreferencesResetTests {
    @Test func contentRefusalPreservesSettingsAndCountersThenExplicitResetClearsThem() async throws {
        let database = try MacapyDatabase.inMemory()
        let settings = SettingsStore(database: database)
        let meetings = MeetingStore(database: database)
        let reset = PreferencesResetStore(database: database)
        try await settings.set("retained", forKey: "fixture.preference")
        _ = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        try await database.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO usage_budget_clock(id,latestDay) VALUES(1,123)")
        }
        await #expect(throws: PreferencesResetError.contentRemains) { try await reset.reset() }
        #expect(try await settings.value(forKey: "fixture.preference") == "retained")
        #expect(try await database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_budget_clock") } == 1)
        try await meetings.deleteAllUserData()
        try await reset.reset()
        #expect(try await settings.value(forKey: "fixture.preference") == nil)
        #expect(try await database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_budget_clock") } == 0)
        let live = try await settings.liveAISettings()
        #expect(live.preferredName == nil && !live.usesSystemPreferredName)
        try await reset.reset() // Idempotent after a cross-namespace retry.
    }

    @Test func standalonePeopleAndDocumentsAreContentEvenWithNoMeetings() async throws {
        let database = try MacapyDatabase.inMemory()
        let reset = PreferencesResetStore(database: database)
        try await database.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO memory_entities(id,kind,name) VALUES(?,?,?)", arguments: [UUID(), "person", "Fictional person"])
        }
        await #expect(throws: PreferencesResetError.contentRemains) { try await reset.requireNoContent() }
    }
}
