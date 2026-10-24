import Foundation
import PersistKit
import ProviderKit
import Testing
@testable import AppShell

@MainActor struct CoordinatorPreferencesResetTests {
    @MainActor private final class PlatformResetState {
        var shouldFail = true
    }

    @Test func resetRequiresContentDeletionAndOnlyTouchesInjectedNamespaces() async throws {
        let database = try MacapyDatabase.inMemory()
        let credentials = InMemoryCredentialStore(keys: ["fixture": "fake-key", "old-profile": "fake-old-key"])
        let settings = SettingsStore(database: database)
        try await settings.set("retained", forKey: "fixture")
        var loginResets = 0
        let coordinator = AppShellCoordinator(panel: MeetingPipelineTests.FakePanel(), installHotKey: false,
            makeDatabase: { database }, credentials: credentials, resetLaunchPreference: { loginResets += 1 })
        let meetings = try #require(coordinator.historyStore())
        _ = try await meetings.beginMeeting(startedAt: Date(), ephemeral: false)
        #expect(await coordinator.resetRetainedPreferences() == .requiresContentDeletion)
        #expect(loginResets == 0)
        #expect(try credentials.key(for: "fixture") == "fake-key")
        #expect(await coordinator.deleteAllMeetingData())
        #expect(await coordinator.resetRetainedPreferences() == .completed)
        #expect(loginResets == 1)
        #expect(try credentials.key(for: "fixture") == nil && credentials.key(for: "old-profile") == nil)
        #expect(try await settings.value(forKey: "fixture") == nil)
        #expect(!coordinator.setup.isComplete && !coordinator.contentDeletionInProgress)
        #expect(coordinator.shortcuts.manager.activeConfiguration == nil)
    }

    @Test func downloadRefusesAndPartialPlatformFailureIsRetryable() async throws {
        enum FakeFailure: Error { case refused }
        let database = try MacapyDatabase.inMemory()
        let credentials = InMemoryCredentialStore(keys: ["fixture": "fake-key"])
        let settings = SettingsStore(database: database)
        try await settings.set("retained", forKey: "fixture")
        let platformReset = PlatformResetState()
        let coordinator = AppShellCoordinator(panel: MeetingPipelineTests.FakePanel(), installHotKey: false,
            makeDatabase: { database }, credentials: credentials, resetLaunchPreference: {
                if platformReset.shouldFail { throw FakeFailure.refused }
            })
        let lease = try #require(coordinator.setup.activity.beginDownload())
        #expect(await coordinator.resetRetainedPreferences() == .busy)
        #expect(try credentials.key(for: "fixture") != nil)
        coordinator.setup.activity.endDownload(lease)
        #expect(await coordinator.resetRetainedPreferences() == .failed)
        #expect(try await settings.value(forKey: "fixture") == "retained")
        #expect(!coordinator.contentDeletionInProgress)
        platformReset.shouldFail = false
        #expect(await coordinator.resetRetainedPreferences() == .completed)
    }
}
