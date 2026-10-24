import Foundation
import PersistKit
import Testing
import TranscribeKit

@testable import AppShell

@MainActor
struct CoordinatorLifecycleReadinessTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Coordinator did not reach the expected lifecycle state")
    }

    @Test func failedPersistentPreflightNeverStartsCaptureOrOpensDatabase() async {
        let counters = MeetingPipelineTests.Counters()
        let source = MeetingPipelineTests.FakeCaptureSource(source: .mic, counters: counters)
        let engine = MeetingPipelineTests.FakeSTTEngine(counters: counters)
        var databases = 0
        let coordinator = AppShellCoordinator(panel: MeetingPipelineTests.FakePanel(), installHotKey: false,
            makePipeline: { MeetingPipeline(engine: engine, sources: [source], store: $0) },
            makeDatabase: { databases += 1; return try MacapyDatabase.inMemory() },
            storagePreflight: { throw MeetingStoragePreflight.Failure.insufficientCapacity })
        coordinator.toggleSession()
        await coordinator.settleCaptureLifecycle()
        #expect(coordinator.session.failure == .storage)
        #expect(await counters.captureStarts == 0)
        #expect(databases == 0)
        #expect(!coordinator.setup.activity.sessionActive)
    }

    @Test func ephemeralMeetingBypassesPersistentPreflight() async {
        let counters = MeetingPipelineTests.Counters()
        let source = MeetingPipelineTests.FakeCaptureSource(source: .mic, counters: counters)
        let engine = MeetingPipelineTests.FakeSTTEngine(counters: counters)
        let coordinator = AppShellCoordinator(panel: MeetingPipelineTests.FakePanel(), installHotKey: false,
            makePipeline: { MeetingPipeline(engine: engine, sources: [source], store: $0) },
            makeDatabase: { try MacapyDatabase.inMemory() },
            storagePreflight: { Issue.record("Ephemeral capture must not run a disk-capacity probe"); throw MeetingStoragePreflight.Failure.unavailable })
        coordinator.ephemeralNextMeeting = true
        coordinator.toggleSession()
        await coordinator.settleCaptureLifecycle()
        #expect(coordinator.session.isCapturing)
        #expect(await counters.captureStarts == 1)
        coordinator.toggleSession()
        await coordinator.settleCaptureLifecycle()
    }

    @Test func sleepStopsRecordingAndCommitsTailWithoutAutomaticRestart() async throws {
        let counters = MeetingPipelineTests.Counters()
        let source = MeetingPipelineTests.FakeCaptureSource(source: .mic, counters: counters)
        let tail = Segment(id: UUID(), source: .mic, text: "Fictional sleep tail.", tStart: 0, tEnd: 1)
        let engine = MeetingPipelineTests.FakeSTTEngine(drain: [.mic: [.final(tail)]], counters: counters)
        let coordinator = AppShellCoordinator(panel: MeetingPipelineTests.FakePanel(), installHotKey: false,
            makePipeline: { MeetingPipeline(engine: engine, sources: [source], store: $0) },
            makeDatabase: { try MacapyDatabase.inMemory() })
        coordinator.toggleSession()
        await coordinator.settleCaptureLifecycle()
        coordinator.applicationLifecycle().receiveSleep()
        await coordinator.settleCaptureLifecycle()
        #expect(coordinator.session.failure == .systemSleep)
        #expect(!coordinator.session.isActive)
        #expect(await counters.captureStarts == 1)
        let meetings = try #require(coordinator.historyStore())
        let meeting = try #require(try await meetings.listMeetings().first)
        #expect(try await meetings.segments(for: meeting.id) == [tail])
    }

    @Test func quitAdmissionSynchronouslyBlocksNewCaptureAndWaitsForTail() async {
        let counters = MeetingPipelineTests.Counters()
        let source = MeetingPipelineTests.FakeCaptureSource(source: .mic, counters: counters)
        let engine = MeetingPipelineTests.FakeSTTEngine(counters: counters, drainDelayNanos: 50_000_000)
        let coordinator = AppShellCoordinator(panel: MeetingPipelineTests.FakePanel(), installHotKey: false,
            makePipeline: { MeetingPipeline(engine: engine, sources: [source], store: $0) },
            makeDatabase: { try MacapyDatabase.inMemory() })
        // No yield occurs between requesting quit and asking to start. This
        // catches admission guarded only inside an asynchronously started task.
        var replies: [Bool] = []
        coordinator.applicationLifecycle().requestTermination { replies.append($0) }
        coordinator.toggleSession()
        #expect(!coordinator.session.isActive)
        await waitUntil { replies == [true] }
        #expect(await counters.captureStarts == 0)

        coordinator.toggleSession()
        await coordinator.settleCaptureLifecycle()
        replies.removeAll()
        coordinator.applicationLifecycle().requestTermination { replies.append($0) }
        await waitUntil { coordinator.terminationInProgress }
        #expect(replies.isEmpty)
        coordinator.toggleSession()
        await waitUntil { replies == [true] }
        #expect(await counters.captureStarts == 1)
        #expect(!coordinator.terminationInProgress)
    }
}
