import Foundation
import PersistKit
import Testing
import TranscribeKit

@testable import AppShell

/// Slice-5 check 14: the type-to-confirm gate — `canDelete` only on the
/// exact token, `confirm()` invokes deletion exactly once, and the
/// coordinator refuses while capturing.
@MainActor
struct DeleteEverythingTests {

    @Test(arguments: ["", "delete", "DELETE ", " DELETE", "DELET", "DELETEE", "Delete", "delete\n"])
    func nearMissEntriesNeverEnableDeletion(entry: String) {
        let model = DeleteEverythingModel(performDelete: { true })
        model.entry = entry
        #expect(!model.canDelete)
    }

    @Test func exactTokenEnablesDeletion() {
        let model = DeleteEverythingModel(performDelete: { true })
        model.entry = "DELETE"
        #expect(model.canDelete)
    }

    @Test func confirmInvokesDeletionExactlyOnce() async {
        // Counter is MainActor state; the closure runs on the MainActor model.
        final class Count { var value = 0 }
        let count = Count()
        let model = DeleteEverythingModel(performDelete: {
            count.value += 1
            return true
        })
        model.entry = "DELETE"

        await model.confirm()
        await model.confirm()  // double-click / repeat: must not re-fire
        model.entry = "DELETE"
        await model.confirm()

        #expect(count.value == 1)
        #expect(model.didComplete)
        #expect(!model.didFail)
    }

    @Test func confirmWithoutTheTokenInvokesNothing() async {
        final class Count { var value = 0 }
        let count = Count()
        let model = DeleteEverythingModel(performDelete: {
            count.value += 1
            return true
        })
        model.entry = "delete"

        await model.confirm()

        #expect(count.value == 0)
        #expect(!model.didComplete)
    }

    @Test func refusedDeletionSurfacesFailureAndAllowsRetry() async {
        final class Gate { var allow = false; var calls = 0 }
        let gate = Gate()
        let model = DeleteEverythingModel(performDelete: {
            gate.calls += 1
            return gate.allow
        })
        model.entry = "DELETE"

        await model.confirm()
        #expect(model.didFail)
        #expect(!model.didComplete)

        // The meeting stopped; the same sheet may retry.
        gate.allow = true
        await model.confirm()
        #expect(gate.calls == 2)
        #expect(model.didComplete)
        #expect(!model.didFail)
    }

    // MARK: - Coordinator guard

    private final class NoopPanel: PanelPresenting {
        func show(session: SessionController, store: TranscriptStore, copilot: LiveCopilotModel) {}
        func hide() {}
    }

    @Test func coordinatorRefusesDeleteEverythingWhileCapturing() async throws {
        let coordinator = AppShellCoordinator(
            panel: NoopPanel(), installHotKey: false,
            makeDatabase: { try MacapyDatabase.inMemory() })
        // Seed a meeting so a permitted deletion has something to prove with.
        let store = try #require(coordinator.historyStore())
        try await store.beginMeeting(startedAt: Date(), ephemeral: false)

        // Session capturing (state only — no pipeline needed for the guard).
        #expect(coordinator.session.start())
        #expect(await coordinator.deleteAllMeetingData() == false)
        #expect(try await store.meetingSummaries().count == 1)

        // Stopped ⇒ deletion runs and the data is gone.
        #expect(coordinator.session.stop())
        #expect(await coordinator.deleteAllMeetingData() == true)
        #expect(try await store.meetingSummaries().isEmpty)
    }
}
