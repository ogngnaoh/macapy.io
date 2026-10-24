import ActionKit
import AgentKit
import Foundation
import PersistKit
import ProviderKit
import Testing
@testable import AppShell

@MainActor private final class BriefTestReader: CalendarEventReading {
    var reads = 0
    var state: CalendarReadState = .ready
    let event: CalendarEventSnapshot
    init() throws {
        let now = Date()
        event = try .init(calendarID: "work", calendarItemID: "synthetic", title: "Cedar review",
                          startDate: now.addingTimeInterval(3600), endDate: now.addingTimeInterval(5400),
                          timeZoneIdentifier: "UTC", isAllDay: false)
    }
    func readableCalendars() -> [CalendarSourceSnapshot] { [.init(id: "work", title: "Synthetic work")] }
    func upcomingEvents(selectedCalendarIDs: Set<String>, startingAt: Date) -> UpcomingCalendarEvents {
        reads += 1
        return .init(state: state, events: state == .ready && selectedCalendarIDs.contains("work") ? [event] : [],
                     windowStart: startingAt, windowEnd: startingAt.addingTimeInterval(86400))
    }
}

@MainActor struct BriefWorkspaceModelTests {
    @Test func automaticSynthesisNeedsSeparateOptInAndNeverIncludesEventMetadata() async throws {
        let sample = try await SampleSession.make()
        defer { sample.close() }
        let reader = sample.sampleCalendar, recorder = BriefRecordingProvider()
        let model = BriefWorkspaceModel(database: sample.database, reader: reader, requestReadAccess: { true },
            makeAutomaticProviderContext: { _ in .init(provider: recorder, model: "scripted", isCurrent: { true }) },
            now: { SampleScenario.briefDate })
        defer { model.stop() }
        await model.start(); await model.waitForOperations()
        #expect(recorder.requests.isEmpty)
        #expect(!model.preferences.automaticAIEnabled)
        await model.setAutomaticAI(true); await model.waitForOperations()
        #expect(recorder.requests.count == 1)
        let request = try #require(recorder.requests.first)
        #expect(request.purpose == .brief)
        #expect(!request.contextSources.contains(.selectedCalendarFields))
        #expect(!request.messages.map(\.content).joined().contains(reader.event.title))
        #expect(model.snapshot?.mode == .ai)
        await model.refresh(); await model.waitForOperations()
        #expect(recorder.requests.count == 1) // Cached same source revision.
        await model.setAutomaticAI(false)
        #expect(!(try await BriefStore(database: sample.database).preferences()).automaticAIEnabled)
    }

    @Test func captureAndDeleteDrainFenceAutomaticLateReplies() async throws {
        let sample = try await SampleSession.make()
        defer { sample.close() }
        let gate = BriefReplyGate(), recorder = BriefRecordingProvider(gate: gate)
        let reader = sample.sampleCalendar
        var active = false
        let model = BriefWorkspaceModel(database: sample.database, reader: reader, requestReadAccess: { true },
            isMeetingActive: { active }, makeAutomaticProviderContext: { _ in
                .init(provider: recorder, model: "scripted", isCurrent: { true })
            }, now: { SampleScenario.briefDate })
        await model.start(); await model.setAutomaticAI(true)
        #expect(await gate.waitForCall())
        active = true
        model.cancelAndClear()
        let drain = Task { await model.cancelAndDrain() }
        await gate.release(); await drain.value
        model.forgetAllContent()
        #expect(model.snapshot == nil && model.events.isEmpty && !model.isWorking)
        #expect(recorder.requests.count == 1)
        #expect(try await BriefStore(database: sample.database).snapshot(eventID: reader.event.id, now: SampleScenario.briefDate)?.mode != .ai)
    }
    @Test func disabledAndActiveMeetingDoNotReadOrPromptAndEnablementIsExplicit() async throws {
        let database = try MacapyDatabase.inMemory(), reader = try BriefTestReader()
        var prompts = 0, active = false
        let model = BriefWorkspaceModel(database: database, reader: reader,
            requestReadAccess: { prompts += 1; return true }, isMeetingActive: { active })
        defer { model.stop() }
        await model.start()
        #expect(prompts == 0 && reader.reads == 0)
        await model.setEnabled(true)
        #expect(prompts == 1)
        await model.setCalendar("work", selected: true)
        #expect(model.events.count == 1)
        #expect(model.snapshot?.text.contains("Associate") == true)
        #expect(model.snapshot?.mode == .local)
        let before = reader.reads
        active = true
        await model.refresh()
        #expect(reader.reads == before)
        model.generateSummary()
        #expect(!model.isWorking)
        active = false
        reader.state = .readAccessRequired
        await model.refresh()
        #expect(model.events.isEmpty && model.snapshot == nil)
        #expect(model.message?.contains("revoked") == true)
    }

    @Test func deniedPermissionAndForgetNeverLeaveVisibleCalendarContent() async throws {
        let database = try MacapyDatabase.inMemory(), reader = try BriefTestReader()
        let denied = BriefWorkspaceModel(database: database, reader: reader, requestReadAccess: { false })
        await denied.setEnabled(true)
        #expect(!denied.preferences.enabled && reader.reads == 0)
        #expect(denied.message?.contains("not granted") == true)
        let model = BriefWorkspaceModel(database: database, reader: reader, requestReadAccess: { true })
        await model.setEnabled(true); await model.setCalendar("work", selected: true)
        #expect(model.snapshot != nil)
        model.forgetAllContent()
        #expect(model.events.isEmpty && model.calendars.isEmpty && model.entities.isEmpty)
        #expect(model.snapshot == nil && model.selectedID == nil && model.sourcePreview == nil)
        let before = reader.reads
        await model.refresh()
        #expect(reader.reads == before)
    }
}

private actor BriefReplyGate {
    private var called = false
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func enter() async {
        called = true
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForCall() async -> Bool {
        for _ in 0..<500 {
            if called { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return called
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}

private final class BriefRecordingProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CompletionRequest] = []
    let gate: BriefReplyGate?
    var requests: [CompletionRequest] { lock.withLock { recorded } }
    init(gate: BriefReplyGate? = nil) { self.gate = gate }
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> { SampleProvider().stream(request) }
    func completeReportingUsage<T: Decodable>(_ request: CompletionRequest, as type: T.Type) async throws -> CompletedCall<T> {
        lock.withLock { recorded.append(request) }
        await gate?.enter()
        return try await SampleProvider().completeReportingUsage(request, as: type)
    }
}
