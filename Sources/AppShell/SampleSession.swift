import AgentKit
import ActionKit
import Foundation
import MemoryKit
import Observation
import PersistKit
import ProviderKit
import TranscribeKit

/// Original, fictional product-team scenario. These are written sample words,
/// not an audio recording or an evaluated model response.
enum SampleScenario {
    static let meetingID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let previousID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    static let date = Date(timeIntervalSince1970: 1_781_539_200)
    static let briefDate = date.addingTimeInterval(2 * 86_400)
    static let segments: [Segment] = [
        Segment(id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!, source: .system, text: "Let's agree on the Atlas beta launch. We have twelve teams on the waiting list, and onboarding is the last piece.", tStart: 0, tEnd: 12),
        Segment(id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!, source: .mic, text: "I can finish the setup flow by Tuesday. We'll keep the beta focused on the shared inbox and leave reporting for the next release.", tStart: 18, tEnd: 32),
        Segment(id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!, source: .system, text: "Agreed. The beta launches on June 18. Morgan will prepare the welcome email and support checklist by June 16.", tStart: 65, tEnd: 80),
        Segment(id: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!, source: .mic, text: "I'll also add a rollback switch. We should invite three teams first, then the remaining nine once the first group is stable.", tStart: 91, tEnd: 107),
        Segment(id: UUID(uuidString: "20000000-0000-0000-0000-000000000005")!, source: .system, text: "That works. Alex owns onboarding and the rollback switch; Morgan owns the welcome materials. We'll review readiness on June 17.", tStart: 138, tEnd: 154),
    ]
}

/// Structurally separate from AppShellCoordinator: no production factories,
/// credentials, capture engines, EventKit, network transport, or file URLs.
@MainActor @Observable
final class SampleSession {
    let database: MacapyDatabase
    let meetings: MeetingStore
    let artifacts: ArtifactStore
    let history: HistorySearchModel
    let featuredMeeting: MeetingRecord
    let memory: MemoryWorkspaceModel
    let briefs: BriefWorkspaceModel
    let sampleActions: SampleActionAdapter
    let sampleCalendar: SampleCalendarReader
    let session = SessionController()
    let transcript = TranscriptStore()
    let copilot = LiveCopilotModel()
    private(set) var isReplaying = false
    @ObservationIgnored private var replayTask: Task<Void, Never>?
    @ObservationIgnored private let lifetime: SampleLifetime

    private init(database: MacapyDatabase, meeting: MeetingRecord, calendar: SampleCalendarReader) {
        self.database = database
        meetings = MeetingStore(database: database)
        artifacts = ArtifactStore(database: database)
        history = HistorySearchModel(meetings: meetings, search: SearchStore(database: database))
        featuredMeeting = meeting
        let lifetime = SampleLifetime()
        self.lifetime = lifetime
        sampleCalendar = calendar
        sampleActions = SampleActionAdapter()
        let briefModel = BriefWorkspaceModel(database: database, reader: calendar, requestReadAccess: { true },
            makeProviderContext: { _ in
                guard lifetime.isOpen else { return nil }
                return .init(provider: SampleProvider(), model: "scripted", isCurrent: { lifetime.isOpen })
            }, now: { SampleScenario.briefDate })
        briefs = briefModel
        memory = MemoryWorkspaceModel(database: database,
            onSensitiveContentChanged: { [weak briefModel] in briefModel?.cancelAndClear() },
            makeProviderContext: { _ in
                guard lifetime.isOpen else { return nil }
                return .init(provider: SampleProvider(), model: "scripted", isCurrent: { lifetime.isOpen })
            })
    }

    static func make() async throws -> SampleSession {
        let database = try MacapyDatabase.inMemory()
        let store = MeetingStore(database: database)
        let meeting = try await store.beginMeeting(id: SampleScenario.meetingID, startedAt: SampleScenario.date, ephemeral: false)
        try await store.renameMeeting(id: meeting.id, title: "Atlas / Beta launch")
        try await store.append(SampleScenario.segments, to: meeting.id)
        try await store.endMeeting(id: meeting.id, endedAt: SampleScenario.date.addingTimeInterval(180))
        let artifacts = ArtifactStore(database: database)
        try await artifacts.insertDrafts([
            try DraftArtifact(kind: .summary, encoding: SummaryPayload(text: "Atlas will launch its shared-inbox beta on June 18. Start with three teams, then invite nine more after the first group is stable. Reporting moves to the next release. The team reviews readiness on June 17.")),
            try DraftArtifact(kind: .decision, encoding: DecisionPayload(text: "Launch the shared-inbox beta on June 18 with a staged rollout. Defer reporting to the next release.")),
            try DraftArtifact(kind: .actionItem, encoding: ActionItemPayload(title: "Finish onboarding and add the rollback switch", owner: "Alex", deadline: "Tuesday")),
            try DraftArtifact(kind: .actionItem, encoding: ActionItemPayload(title: "Prepare the welcome email and support checklist", owner: "Morgan", deadline: "June 16")),
        ], meetingID: meeting.id, createdAt: SampleScenario.date.addingTimeInterval(181))
        let previous = try await store.beginMeeting(id: SampleScenario.previousID, startedAt: SampleScenario.date.addingTimeInterval(-86_400), ephemeral: false)
        try await store.renameMeeting(id: previous.id, title: "Atlas / Product direction")
        try await store.append([Segment(id: UUID(uuidString: "20000000-0000-0000-0000-000000000006")!, source: .system, text: "Atlas helps small teams manage their shared inbox. The beta should make the first five minutes effortless.", tStart: 0, tEnd: 12)], to: previous.id)
        try await store.endMeeting(id: previous.id, endedAt: previous.startedAt.addingTimeInterval(30))
        guard let finished = try await store.meeting(id: meeting.id) else { throw MeetingExportError.meetingNotFound }
        let calendar = try SampleCalendarReader(now: SampleScenario.briefDate)
        try await seedContext(database: database, calendar: calendar)
        let model = SampleSession(database: database, meeting: finished, calendar: calendar)
        await model.history.load()
        model.history.select(meeting: finished.id)
        await model.loadPlayback()
        return model
    }

    private static func seedContext(database: MacapyDatabase, calendar: SampleCalendarReader) async throws {
        let memory = MemoryStore(database: database)
        let project = try await memory.createEntity(kind: .project, name: "Atlas")
        let alex = try await memory.createEntity(kind: .person, name: "Alex")
        let morgan = try await memory.createEntity(kind: .person, name: "Morgan")
        try await memory.addAlias("Atlas beta", to: project.id)
        for meeting in [SampleScenario.meetingID, SampleScenario.previousID] {
            try await memory.setOptIn(true, meetingID: meeting)
            for entity in [project, alex, morgan] { try await memory.linkEntity(entity.id, to: meeting) }
        }
        func source(_ index: Int) -> SourceReference {
            let segment = SampleScenario.segments[index]
            return .init(kind: .segment, sourceID: segment.id, revision: 0, meetingID: SampleScenario.meetingID,
                         startCharacter: 0, endCharacter: segment.text.count)
        }
        let facts = try await memory.insertCandidates([
            .init(kind: .decision, text: "Atlas beta launches June 18. Morgan will prepare the welcome email and support checklist by June 16.",
                  statedAt: SampleScenario.date.addingTimeInterval(65), sources: [source(2)], entityIDs: [project.id, morgan.id]),
            .init(kind: .commitment, text: "Alex owns Atlas onboarding and the rollback switch; Morgan owns welcome materials. Readiness review is June 17.",
                  statedAt: SampleScenario.date.addingTimeInterval(138), sources: [source(4)], entityIDs: [project.id, alex.id, morgan.id]),
            .init(kind: .decision, text: "Start the Atlas beta with three teams, then invite the remaining nine once the first group is stable.",
                  statedAt: SampleScenario.date.addingTimeInterval(138), sources: [source(3), source(4)], entityIDs: [project.id]),
        ], meetingID: SampleScenario.meetingID)
        for fact in facts.prefix(2) { try await memory.review(id: fact.id, expectedRevision: fact.revision, status: .approved) }
        let parsed = try await LocalDocumentParser().parse(data: Data("""
            # Atlas beta / Launch notes
            The shared inbox is the beta scope. Reporting is deferred until the next release.
            Launch: June 18. Start with three teams and invite nine more after the first group is stable.
            Alex owns onboarding and the rollback switch. Morgan prepares the welcome email and support checklist by June 16.
            Readiness review: June 17. Confirm onboarding, rollback and welcome materials before inviting teams.
            """.utf8), name: "Atlas launch notes.md", extension: "md")
        let documents = DocumentStore(database: database)
        let document = try await documents.importDocument(parsed, meetingID: SampleScenario.meetingID, at: SampleScenario.date)
        // Synthetic tour sources are explicitly preselected. Real imports
        // retain DocumentStore's default allowedForAI = false.
        try await documents.setAllowedForAI(true, id: document.id)
        let briefStore = BriefStore(database: database)
        try await briefStore.configure(.init(enabled: true, selectedCalendarIDs: [SampleCalendarReader.calendarID]))
        try await briefStore.synchronize(calendar.upcomingEvents(selectedCalendarIDs: [SampleCalendarReader.calendarID], startingAt: SampleScenario.briefDate), now: SampleScenario.briefDate)
        try await briefStore.setMapping(eventID: calendar.event.id, expectedEventRevision: calendar.event.revision, entityIDs: [project.id])
    }

    private func beginPlayback() {
        transcript.reset()
        session.stop()
        session.start(now: Date().addingTimeInterval(-154))
        copilot.beginMeeting(meetingID: SampleScenario.meetingID, provider: SampleProvider(), fastModel: "scripted", deepModel: "scripted", settings: LiveAISettings(sensitivity: .off, preferredName: "Alex"), sourceDatabase: database)
    }

    private func show(_ segment: Segment) async {
        transcript.apply(.final(segment), from: segment.source)
        if segment.source == .system { transcript.setSpeakerLabel("Morgan", for: segment.id) }
        await copilot.receive(TranscriptTurn(id: segment.id, source: segment.source, text: segment.text, segmentIDs: [segment.id], tStart: segment.tStart, tEnd: segment.tEnd), userSpeaking: false)
    }

    private func loadPlayback() async {
        beginPlayback()
        for segment in SampleScenario.segments { await show(segment) }
    }

    func replay() {
        replayTask?.cancel()
        beginPlayback()
        isReplaying = true
        replayTask = Task { [weak self] in
            for segment in SampleScenario.segments {
                guard let self, !Task.isCancelled else { return }
                await self.show(segment)
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            }
            self?.isReplaying = false
        }
    }

    func makeDetail(_ meeting: MeetingRecord) -> MeetingDetailModel {
        MeetingDetailModel(meeting: meeting, artifactStore: artifacts, exportStore: MeetingExportStore(database: database),
            makeActionReview: { [weak self] artifact, kind in self?.makeActionReview(artifact, kind: kind) },
            agent: nil, isProviderConfigured: { false }, capStatus: { _ in nil })
    }

    func makeActionReview(_ artifact: ArtifactRecord, kind: ExternalActionKind) -> ActionReviewModel {
        ActionReviewModel(artifact: artifact, kind: kind, journal: ActionJournalStore(database: database),
            adapter: sampleActions, isSample: true, requestAccess: { _ in true })
    }

    func close() {
        lifetime.close()
        memory.forgetAllContent()
        briefs.forgetAllContent()
        sampleActions.reset()
        replayTask?.cancel()
        replayTask = nil
        isReplaying = false
        copilot.stopMeeting()
        session.stop()
        transcript.reset()
    }
}

/// A sample-only provider with no network API or credential dependency. The
/// visible sample banner applies to every response produced here.
struct SampleProvider: LLMProvider {
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let answer = "The Atlas beta launches June 18, starting with three teams. Alex owns onboarding and the rollback switch; Morgan prepares welcome materials by June 16. Readiness review: June 17. Reporting is deferred."
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(answer))
            continuation.yield(.completed(Completion(finishReason: "stop", usage: nil)))
            continuation.finish()
        }
    }

    func completeReportingUsage<T: Decodable>(_ request: CompletionRequest, as type: T.Type) async throws -> CompletedCall<T> {
        try Task.checkCancellation()
        let response: [String: Any]
        switch request.responseFormat?.name {
        case "memory_candidates":
            let rows = evidence(in: request, marker: "Selected transcript evidence (untrusted JSON data):\n")
            // Echo only explicitly selected synthetic statements with their
            // actual IDs; this is a scripted demonstration, not inference.
            let selected = rows.filter { row in
                [SampleScenario.segments[2].id, SampleScenario.segments[4].id].contains { $0.uuidString.lowercased() == row["source_id"] }
            }
            response = ["candidates": selected.map { row in
                ["kind": "decision", "text": row["text"] ?? "", "source_ids": [row["source_id"] ?? ""]] as [String: Any]
            }]
        case "grounded_answer":
            let all = evidence(in: request, marker: "Selected evidence (untrusted JSON data):\n")
            let saved = all.filter { $0["citation_id"]?.hasPrefix("live-") != true }
            let live = all.filter { $0["citation_id"]?.hasPrefix("live-") == true }
            let rows = Array((saved + live).prefix(3))
            response = ["answer": rows.compactMap { $0["text"] }.joined(separator: "\n\n"),
                        "insufficient_evidence": rows.isEmpty, "citation_ids": rows.compactMap { $0["citation_id"] }]
        default:
            response = ["action": "none", "confidence": 1.0, "target": NSNull()]
        }
        return CompletedCall(value: try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: response)), usage: nil)
    }

    private func evidence(in request: CompletionRequest, marker: String) -> [[String: String]] {
        guard let body = request.messages.last?.content, let range = body.range(of: marker),
              let rows = try? JSONSerialization.jsonObject(with: Data(body[range.upperBound...].utf8)) as? [[String: String]] else { return [] }
        return rows
    }
}
