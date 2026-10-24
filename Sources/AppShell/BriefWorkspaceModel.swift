import ActionKit
import AgentKit
import Foundation
import MemoryKit
import Observation
import PersistKit
import ProviderKit

@MainActor
@Observable
final class BriefWorkspaceModel {
    private(set) var preferences = BriefPreferences()
    private(set) var calendars: [CalendarSourceSnapshot] = []
    private(set) var events: [BriefEvent] = []
    private(set) var entities: [MemoryEntity] = []
    private(set) var selectedID: String?
    private(set) var snapshot: BriefSnapshot?
    private(set) var sourcePreview: String?
    private(set) var message: String?
    private(set) var isWorking = false
    private(set) var workingAutomatically = false
    var includeEventTitleForAI = false
    var selectedCitationIDs: Set<String> = []
    private(set) var budget: BackgroundUsageSummary?

    @ObservationIgnored private let store: BriefStore
    @ObservationIgnored private let memory: MemoryStore
    @ObservationIgnored private let usage: BackgroundUsageStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let reader: any CalendarEventReading
    @ObservationIgnored private let requestReadAccess: @MainActor () async throws -> Bool
    @ObservationIgnored private let isMeetingActive: @MainActor () -> Bool
    @ObservationIgnored private let onSensitiveContentChanged: @MainActor () -> Void
    @ObservationIgnored private let makeProviderContext: @Sendable (BriefSnapshot) async throws -> MemoryProviderContext?
    @ObservationIgnored private let makeAutomaticProviderContext: @Sendable (BriefSnapshot) async throws -> MemoryProviderContext?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var mutations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lifecycleRevision: UInt64 = 0

    init(database: MacapyDatabase, reader: any CalendarEventReading,
         requestReadAccess: @escaping @MainActor () async throws -> Bool,
         isMeetingActive: @escaping @MainActor () -> Bool = { false },
         onSensitiveContentChanged: @escaping @MainActor () -> Void = {},
         makeProviderContext: @escaping @Sendable (BriefSnapshot) async throws -> MemoryProviderContext? = { _ in nil },
         makeAutomaticProviderContext: @escaping @Sendable (BriefSnapshot) async throws -> MemoryProviderContext? = { _ in nil },
         now: @escaping @Sendable () -> Date = { Date() }) {
        store = BriefStore(database: database); memory = MemoryStore(database: database); usage = BackgroundUsageStore(database: database)
        self.now = now
        self.reader = reader; self.requestReadAccess = requestReadAccess
        self.isMeetingActive = isMeetingActive; self.onSensitiveContentChanged = onSensitiveContentChanged
        self.makeProviderContext = makeProviderContext
        self.makeAutomaticProviderContext = makeAutomaticProviderContext
    }

    var selectedEvent: BriefEvent? { events.first { $0.id == selectedID } }
    var workDeferred: Bool { isMeetingActive() }

    func start() async {
        let token = revision
        let lifecycle = lifecycleRevision
        do { preferences = try await store.preferences() }
        catch { message = "Brief settings could not be read."; return }
        guard token == revision, !Task.isCancelled else { return }
        await refresh()
        guard !Task.isCancelled, lifecycle == lifecycleRevision else { return }
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                if !self.isWorking { await self.refresh() }
            }
        }
    }

    func setEnabled(_ enabled: Bool) async {
        await mutate { await self.updateEnabled(enabled) }
    }

    private func updateEnabled(_ enabled: Bool) async {
        guard !isMeetingActive() else { return }
        cancelAndClear()
        let token = revision
        do {
            if enabled, !(try await requestReadAccess()) {
                message = "Calendar read access was not granted. Local history and capture remain available."; return
            }
            guard token == revision, !Task.isCancelled, !isMeetingActive() else { return }
            preferences = .init(enabled: enabled, selectedCalendarIDs: preferences.selectedCalendarIDs,
                                automaticAIEnabled: preferences.automaticAIEnabled)
            try await store.configure(preferences)
            guard token == revision, !Task.isCancelled else { return }
            await refresh()
        } catch { message = "Brief settings could not be saved. No calendar content was sent." }
    }

    func setCalendar(_ id: String, selected: Bool) async {
        await mutate { await self.updateCalendar(id, selected: selected) }
    }

    private func updateCalendar(_ id: String, selected: Bool) async {
        guard !isMeetingActive(), calendars.contains(where: { $0.id == id }) else { return }
        cancelAndClear()
        let token = revision
        var ids = preferences.selectedCalendarIDs
        if selected { ids.insert(id) } else { ids.remove(id) }
        do {
            let updated = BriefPreferences(enabled: preferences.enabled, selectedCalendarIDs: ids,
                                           automaticAIEnabled: preferences.automaticAIEnabled)
            try await store.configure(updated)
            guard token == revision, !Task.isCancelled else { return }
            preferences = updated
            await refresh()
        } catch { message = "The calendar selection could not be saved." }
    }

    func setAutomaticAI(_ enabled: Bool) async {
        await mutate {
            guard !self.isMeetingActive(), self.preferences.enabled else { return }
            self.cancelAndClear()
            let token = self.revision
            do {
                let updated = BriefPreferences(enabled: true, selectedCalendarIDs: self.preferences.selectedCalendarIDs,
                                               automaticAIEnabled: enabled)
                try await self.store.configure(updated)
                guard token == self.revision, !Task.isCancelled else { return }
                self.preferences = updated
                await self.refresh()
            } catch { self.message = "Automatic brief preferences could not be saved." }
        }
    }

    func refresh() async {
        await mutate { await self.refreshOwned() }
    }

    private func refreshOwned() async {
        guard !isMeetingActive() else { return }
        guard preferences.enabled else { calendars = []; events = []; snapshot = nil; return }
        // A refresh invalidates visible calendar-derived text immediately.
        cancelAndClear()
        let token = revision
        budget = try? await usage.summary(now: now())
        guard token == revision, !isMeetingActive() else { return }
        calendars = reader.readableCalendars()
        let read = reader.upcomingEvents(selectedCalendarIDs: preferences.selectedCalendarIDs, startingAt: now())
        do {
            try await store.synchronize(read, now: now())
            let freshEvents = try await store.events(now: now())
            let freshEntities = try await memory.entities()
            guard token == revision, !isMeetingActive() else { return }
            events = freshEvents.filter { $0.event.endDate > now() }
            entities = freshEntities
            if !events.contains(where: { $0.id == selectedID }) { selectedID = events.first?.id }
            switch read.state {
            case .readAccessRequired:
                events = []; message = "Calendar access was revoked. Cached event details and briefs have been removed."
            case .noCalendarsSelected: message = "Choose which calendars macapy may read."
            case .ready:
                message = read.isTruncated ? "Only the first upcoming events are shown. Refresh after narrowing your calendar selection." : nil
                if !read.unavailableCalendarIDs.isEmpty { message = "A selected calendar is unavailable. Its cached events were removed; choose an available calendar." }
            default: message = "Upcoming events could not be read. No AI work was started."
            }
            await buildLocalBrief()
            guard token == revision, !Task.isCancelled else { return }
            scheduleAutomaticSummaries()
        } catch { guard token == revision else { return }; message = "Briefs could not be refreshed." }
    }

    func select(_ id: String) async {
        cancelAndClear(); selectedID = id; await buildLocalBrief()
    }

    func setEntity(_ id: UUID, selected: Bool) async {
        await mutate { await self.updateEntity(id, selected: selected) }
    }

    private func updateEntity(_ id: UUID, selected: Bool) async {
        guard let event = selectedEvent, !isMeetingActive() else { return }
        cancelAndClear()
        let token = revision
        var ids = event.entityIDs
        if selected { ids.insert(id) } else { ids.remove(id) }
        do {
            try await store.setMapping(eventID: event.id, expectedEventRevision: event.event.revision, entityIDs: ids)
            let fresh = try await store.events(now: now())
            guard token == revision, !Task.isCancelled else { return }
            events = fresh
            await buildLocalBrief()
        } catch { message = "This event changed. Refresh and choose its associations again." }
    }

    private func request(for event: BriefEvent) -> RetrievalRequest {
        let names = entities.filter { event.entityIDs.contains($0.id) }.map(\.name)
        return .init(query: ([event.event.title] + names).joined(separator: " "), entityIDs: event.entityIDs,
                     asOf: now(), maxExcerpts: 8, maxCharacters: 8_000)
    }

    private func buildLocalBrief() async {
        guard let event = selectedEvent, !isMeetingActive() else { return }
        let token = revision
        do {
            let request = request(for: event)
            let context = try await memory.retrieve(request)
            guard token == revision, selectedID == event.id, !isMeetingActive(),
                  try await memory.validate(context, for: request) else { return }
            let text = context.isEmpty
                ? (event.entityIDs.isEmpty ? "Associate a person or project to find relevant reviewed history." : "No matching reviewed evidence is available for these associations.")
                : context.excerpts.map { "• \($0.text)" }.joined(separator: "\n\n")
            let local = BriefSnapshot(event: event.event, mappingRevision: event.mappingRevision, context: context,
                text: String(text.prefix(8_000)), citationIDs: context.excerpts.map(\.citationID), mode: .local, generatedAt: now())
            if let cached = try await store.snapshot(eventID: event.id, now: now()), cached.mode == .ai,
               cached.event.revision == event.event.revision, cached.mappingRevision == event.mappingRevision,
               try await memory.validate(cached.context, for: request) {
                guard token == revision, !isMeetingActive() else { return }
                snapshot = cached; selectedCitationIDs = Set(cached.context.excerpts.map(\.citationID))
                return
            }
            try await store.save(local, now: now())
            guard token == revision, !isMeetingActive() else { return }
            snapshot = local
            selectedCitationIDs = Set(local.context.excerpts.map(\.citationID))
        } catch { guard token == revision else { return }; message = "Source context changed. Refresh before using this brief." }
    }

    func generateSummary() {
        guard !isWorking, !isMeetingActive(), let current = snapshot,
              let event = selectedEvent else { return }
        let selected = ContextBundle(excerpts: current.context.excerpts.filter { selectedCitationIDs.contains($0.citationID) })
        guard !selected.isEmpty else { return }
        let original = BriefSnapshot(event: current.event, mappingRevision: current.mappingRevision, context: selected,
            text: current.text, citationIDs: selected.excerpts.map(\.citationID), mode: .local, generatedAt: now())
        let token = revision
        let retrieval = request(for: event)
        let includeTitle = includeEventTitleForAI
        let taskID = UUID()
        isWorking = true; message = nil
        generationTask = Task { [weak self] in
            guard let self else { return }
            defer { generations[taskID] = nil; if revision == token { isWorking = false; generationTask = nil } }
            do {
                guard try await memory.validate(original.context, for: retrieval),
                      let baseProvider = try await makeProviderContext(original) else {
                    if revision == token { message = "AI synthesis is unavailable. The local brief remains usable." }; return
                }
                let provider = baseProvider.withValidation { [memory, store] in
                    guard (try? await store.isCurrent(eventID: original.id, eventRevision: original.event.revision,
                                                      mappingRevision: original.mappingRevision)) == true else { return false }
                    return (try? await memory.validate(original.context, for: retrieval)) == true
                }
                guard revision == token, !isMeetingActive(), !Task.isCancelled else { return }
                let question = includeTitle
                    ? "Prepare a concise pre-meeting brief for the event titled: \(original.event.title). Summarize relevant decisions, open commitments, and unresolved questions."
                    : "Prepare a concise pre-meeting brief from the selected evidence. Summarize relevant decisions, open commitments, and unresolved questions."
                let answer = try await GroundedAnswerGenerator().answer(question: question, context: original.context, provider: provider,
                    purpose: .brief, additionalContextSources: includeTitle ? [.selectedCalendarFields] : [])
                guard revision == token, !isMeetingActive(), !Task.isCancelled,
                      try await memory.validate(original.context, for: retrieval), await provider.isCurrent() else { return }
                guard !answer.insufficientEvidence else { message = answer.text; return }
                let generated = BriefSnapshot(event: original.event, mappingRevision: original.mappingRevision, context: original.context,
                    text: answer.text, citationIDs: answer.citationIDs, mode: .ai, generatedAt: now())
                try await store.save(generated, now: now())
                guard revision == token, !isMeetingActive(), !Task.isCancelled else { return }
                snapshot = generated
                budget = try? await usage.summary(now: now())
            } catch is CancellationError {
                // Local context remains available; no retry is automatic.
            } catch {
                if revision == token { message = "AI synthesis could not finish. The local source-linked brief remains available; no automatic retry was started." }
            }
        }
        generations[taskID] = generationTask
    }

    /// One serial owner, after calendar refresh, with a separate explicit
    /// opt-in. Durable admission remains authoritative across app restarts.
    private func scheduleAutomaticSummaries() {
        guard preferences.automaticAIEnabled, !isMeetingActive(), !isWorking else { return }
        let candidates = events.filter { !$0.entityIDs.isEmpty }
        guard !candidates.isEmpty else { return }
        let token = revision, taskID = UUID()
        isWorking = true; workingAutomatically = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                generations[taskID] = nil
                if revision == token { isWorking = false; workingAutomatically = false }
            }
            for event in candidates {
                guard revision == token, preferences.automaticAIEnabled, !isMeetingActive(), !Task.isCancelled else { return }
                do {
                    let currentBudget = try await usage.summary(now: now())
                    budget = currentBudget
                    guard currentBudget.automaticCount < BriefUsagePolicy.maximumAutomaticGenerations,
                          currentBudget.committedUSD < BriefUsagePolicy.dailyCapUSD else { return }
                    let retrieval = request(for: event)
                    let context = try await memory.retrieve(retrieval)
                    guard !context.isEmpty else { continue }
                    let input = BriefSnapshot(event: event.event, mappingRevision: event.mappingRevision, context: context,
                        text: "", citationIDs: context.excerpts.map(\.citationID), mode: .local, generatedAt: now())
                    if let cached = try await store.snapshot(eventID: event.id, now: now()), cached.mode == .ai,
                       cached.generationRevision == input.generationRevision { continue }
                    guard revision == token, !Task.isCancelled,
                          let base = try await makeAutomaticProviderContext(input) else { return }
                    let provider = base.withValidation { [weak self, memory, store] in
                        guard await self?.automaticIsCurrent(token) == true,
                              (try? await store.isCurrent(eventID: input.id, eventRevision: input.event.revision,
                                                        mappingRevision: input.mappingRevision)) == true else { return false }
                        return (try? await memory.validate(context, for: retrieval)) == true
                    }
                    let answer = try await GroundedAnswerGenerator().answer(
                        question: "Prepare a concise pre-meeting brief from the selected evidence. Summarize relevant decisions, open commitments, and unresolved questions.",
                        context: context, provider: provider, purpose: .brief)
                    guard automaticIsCurrent(token), await provider.isCurrent(), !Task.isCancelled else { return }
                    guard !answer.insufficientEvidence else { continue }
                    let result = BriefSnapshot(event: event.event, mappingRevision: event.mappingRevision, context: context,
                        text: answer.text, citationIDs: answer.citationIDs, mode: .ai, generatedAt: now())
                    try await store.save(result, now: now())
                    guard automaticIsCurrent(token) else { return }
                    if selectedID == event.id {
                        snapshot = result; selectedCitationIDs = Set(context.excerpts.map(\.citationID))
                    }
                    budget = try? await usage.summary(now: now())
                } catch is CancellationError { return }
                catch {
                    // No retry loop. Duplicate/debounced revisions and exhausted
                    // budgets remain denied by the durable store on later refresh.
                    guard automaticIsCurrent(token) else { return }
                }
            }
        }
        generations[taskID] = task
    }

    private func automaticIsCurrent(_ token: UInt64) -> Bool {
        revision == token && preferences.enabled && preferences.automaticAIEnabled && !isMeetingActive()
    }

    func waitForOperations() async {
        for task in Array(generations.values) { await task.value }
        for task in Array(mutations.values) { await task.value }
    }

    func preview(_ source: SourceReference) async {
        let token = revision
        do {
            let text = try await memory.sourcePreview(source)
            if token == revision { sourcePreview = text ?? "This source was removed or changed." }
        } catch { if token == revision { sourcePreview = "This source could not be opened." } }
    }

    func cancelAndClear() {
        revision &+= 1; generationTask?.cancel(); generationTask = nil; isWorking = false
        workingAutomatically = false
        generations.values.forEach { $0.cancel() }
        snapshot = nil; sourcePreview = nil; selectedCitationIDs = []
        onSensitiveContentChanged()
    }

    func stop() {
        lifecycleRevision &+= 1
        monitorTask?.cancel(); monitorTask = nil
        cancelAndClear()
    }

    private func mutate(_ operation: @escaping @MainActor () async -> Void) async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        let task = Task { await operation() }
        mutations[id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        mutations[id] = nil
    }

    func cancelAndDrain() async {
        let owned = Array(generations.values)
        stop()
        let pending = Array(mutations.values)
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
        for task in owned { await task.value }
    }

    func forgetAllContent() {
        stop()
        preferences = .init(); calendars = []; events = []; entities = []; selectedID = nil
        includeEventTitleForAI = false; message = nil
    }
}
