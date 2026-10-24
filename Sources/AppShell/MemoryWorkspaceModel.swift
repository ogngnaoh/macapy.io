import AgentKit
import Foundation
import MemoryKit
import Observation
import PersistKit
import ProviderKit

@MainActor @Observable
final class MemoryWorkspaceModel {
    struct SourcePreview: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    private(set) var meetings: [MeetingRecord] = []
    private(set) var selectedMeetingID: UUID?
    private(set) var facts: [MemoryFact] = []
    private(set) var entities: [MemoryEntity] = []
    private(set) var linkedEntities: [MemoryEntity] = []
    private(set) var documents: [DocumentRecord] = []
    private(set) var documentLibrary: [DocumentRecord] = []
    private(set) var isOptedIn = false
    private(set) var isLoading = false
    private(set) var busyMessage: String?
    private(set) var errorMessage: String?
    private(set) var notice: String?
    var sourcePreview: SourcePreview?

    var query = ""
    var queryMeetingIDs: Set<UUID> = []
    var queryDocumentIDs: Set<UUID> = []
    var queryEntityID: UUID?
    var useAsOfDate = false
    var asOfDate = Date()
    private(set) var contextPreview: ContextBundle?
    var selectedCitationIDs: Set<String> = []
    private(set) var answer: GroundedAnswer?
    private(set) var previewQuestion = ""

    private(set) var extractionPreview: [MemoryEvidence] = []
    var selectedEvidenceIDs: Set<String> = []
    private(set) var extractionTotalSegments = 0
    private(set) var extractionStart = 0
    private(set) var extractionNextOffset: Int?

    @ObservationIgnored private let meetingsStore: MeetingStore
    @ObservationIgnored private let memory: MemoryStore
    @ObservationIgnored private let docs: DocumentStore
    @ObservationIgnored private let parser = LocalDocumentParser()
    @ObservationIgnored private let isMeetingActive: @MainActor () -> Bool
    @ObservationIgnored private let onSensitiveContentChanged: @MainActor () -> Void
    @ObservationIgnored private let makeProviderContext: @Sendable (UUID) async throws -> MemoryProviderContext?
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var mutations: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var previewRequest: RetrievalRequest?

    init(database: MacapyDatabase,
         isMeetingActive: @escaping @MainActor () -> Bool = { false },
         onSensitiveContentChanged: @escaping @MainActor () -> Void = {},
         makeProviderContext: @escaping @Sendable (UUID) async throws -> MemoryProviderContext? = { _ in nil }) {
        meetingsStore = MeetingStore(database: database); memory = MemoryStore(database: database)
        docs = DocumentStore(database: database); self.isMeetingActive = isMeetingActive
        self.onSensitiveContentChanged = onSensitiveContentChanged; self.makeProviderContext = makeProviderContext
    }

    var selectedMeeting: MeetingRecord? { meetings.first { $0.id == selectedMeetingID } }
    var isWorking: Bool { busyMessage != nil }
    var isCaptureActive: Bool { isMeetingActive() }
    var canSendAnswer: Bool {
        !isWorking && selectedMeetingID != nil && !selectedCitationIDs.isEmpty
            && previewRequest.map { queryMatches($0, question: previewQuestion) } == true
    }
    var selectedExcerptCount: Int { selectedCitationIDs.count }
    var selectedExtractionCharacters: Int { extractionPreview.filter { selectedEvidenceIDs.contains($0.id) }.reduce(0) { $0 + $1.text.count } }

    func load() async {
        let version = epoch
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await meetingsStore.listMeetings().filter { $0.hasEnded && !$0.ephemeral }
            guard version == epoch else { return }
            meetings = rows
            let previous = selectedMeetingID
            if !meetings.contains(where: { $0.id == selectedMeetingID }) { selectedMeetingID = meetings.first?.id }
            if queryMeetingIDs.isEmpty, let selectedMeetingID { queryMeetingIDs = [selectedMeetingID] }
            try await refreshSelection(selectAssociatedDocuments: previous != selectedMeetingID)
        } catch { if epoch == version { report(error) } }
    }

    func selectMeeting(_ id: UUID?) async {
        cancelAndClear()
        selectedMeetingID = id
        queryMeetingIDs = Set(id.map { [$0] } ?? [])
        queryDocumentIDs = []
        do { try await refreshSelection(selectAssociatedDocuments: true) } catch { report(error) }
    }

    private func refreshSelection(selectAssociatedDocuments: Bool = false) async throws {
        let version = epoch, id = selectedMeetingID
        let allEntities = try await memory.entities()
        let allDocuments = try await docs.documents()
        var selectedFacts: [MemoryFact] = [], selectedDocuments: [DocumentRecord] = []
        var selectedEntities: [MemoryEntity] = [], optedIn = false
        if let id {
            selectedFacts = try await memory.facts(meetingID: id)
            selectedDocuments = try await docs.documents(meetingID: id)
            selectedEntities = try await memory.entities(meetingID: id)
            optedIn = try await memory.isOptedIn(meetingID: id)
        }
        guard version == epoch, id == selectedMeetingID else { return }
        entities = allEntities; documentLibrary = allDocuments
        facts = selectedFacts; documents = selectedDocuments; linkedEntities = selectedEntities; isOptedIn = optedIn
        queryDocumentIDs.formIntersection(Set(documentLibrary.filter(\.allowedForAI).map(\.id)))
        if selectAssociatedDocuments { queryDocumentIDs = Set(documents.filter(\.allowedForAI).map(\.id)) }
    }

    func setOptIn(_ enabled: Bool) async {
        guard let id = selectedMeetingID else { return }
        let changed = await mutate { try await self.memory.setOptIn(enabled, meetingID: id) }
        if changed { notice = enabled ? "Memory is enabled for this meeting. Extract candidates, then review what you want to keep." : "This meeting’s memory candidates and facts were removed." }
    }

    func review(_ fact: MemoryFact, status: MemoryReviewStatus) async {
        await mutate { try await self.memory.review(id: fact.id, expectedRevision: fact.revision, status: status) }
    }
    func edit(_ fact: MemoryFact, text: String) async -> Bool {
        await mutate { _ = try await self.memory.edit(id: fact.id, expectedRevision: fact.revision, text: text) }
    }
    func supersede(_ fact: MemoryFact) async {
        await mutate { try await self.memory.supersede(id: fact.id, expectedRevision: fact.revision) }
    }
    func delete(_ fact: MemoryFact) async {
        await mutate { try await self.memory.deleteFact(id: fact.id) }
    }
    func complete(_ fact: MemoryFact, complete: Bool) async {
        await mutate { try await self.memory.setCompletion(complete, id: fact.id, expectedRevision: fact.revision) }
    }
    func createEntity(name: String, kind: MemoryEntityKind) async -> Bool {
        guard let meetingID = selectedMeetingID else { return false }
        return await mutate {
            let entity = try await self.memory.createEntity(kind: kind, name: name)
            try await self.memory.linkEntity(entity.id, to: meetingID)
        }
    }
    func linkEntity(_ id: UUID) async {
        guard let meetingID = selectedMeetingID else { return }
        await mutate { try await self.memory.linkEntity(id, to: meetingID) }
    }
    func unlinkEntity(_ id: UUID) async {
        guard let meetingID = selectedMeetingID else { return }
        await mutate { try await self.memory.unlinkEntity(id, from: meetingID) }
    }
    func addAlias(_ name: String, to id: UUID) async -> Bool {
        await mutate { try await self.memory.addAlias(name, to: id) }
    }
    func removeAlias(_ name: String, from id: UUID) async {
        await mutate { try await self.memory.removeAlias(name, from: id) }
    }
    func mergeEntity(_ source: UUID, into destination: UUID) async -> Bool {
        await mutate { try await self.memory.mergeEntity(source, into: destination) }
    }
    func deleteEntity(_ id: UUID) async {
        await mutate { try await self.memory.deleteEntity(id: id) }
    }

    func importDocument(url: URL, replacing existing: DocumentRecord? = nil) {
        guard let meetingID = selectedMeetingID else { return }
        guard !isMeetingActive() else { errorMessage = "Document indexing is paused while a meeting is capturing."; return }
        startWork("Reading document locally…") { version in
            let parsed = try await self.parser.parse(url: url)
            try self.requireCurrent(version)
            guard !self.isMeetingActive() else { throw MemoryStoreError.indexingPaused }
            await self.docs.setIndexingPaused(false)
            if let existing {
                _ = try await self.docs.reimport(parsed, id: existing.id, expectedRevision: existing.revision)
            } else {
                _ = try await self.docs.importDocument(parsed, meetingID: meetingID)
            }
            try self.requireCurrent(version)
            try await self.refreshSelection()
            self.notice = "Document saved as a local text snapshot. Choose whether it may be included in AI context."
        }
    }
    func attachDocument(_ id: UUID) async {
        guard let meetingID = selectedMeetingID else { return }
        await mutate { try await self.docs.attach(id: id, to: meetingID) }
    }
    func setDocumentConsent(_ allowed: Bool, id: UUID) async {
        await mutate { try await self.docs.setAllowedForAI(allowed, id: id) }
    }
    func detachDocument(_ id: UUID) async {
        guard let meetingID = selectedMeetingID else { return }
        await mutate { try await self.docs.detach(id: id, from: meetingID) }
    }
    func deleteDocument(_ id: UUID) async {
        await mutate { try await self.docs.remove(id: id) }
    }
    func showDocument(_ document: DocumentRecord) async {
        let version = epoch
        do {
            let text = try await docs.snapshotText(id: document.id)
            try requireCurrent(version)
            sourcePreview = .init(title: document.name, text: text)
        } catch { if epoch == version { report(error) } }
    }
    func showSource(_ source: SourceReference, title: String = "Source evidence") async {
        let version = epoch
        do {
            let text = try await memory.sourcePreview(source)
            try requireCurrent(version)
            guard let text else {
                errorMessage = "This source changed or was removed. Refresh the workspace to see current evidence."; return
            }
            sourcePreview = .init(title: title, text: text)
        } catch { if epoch == version { report(error) } }
    }

    func prepareExtraction(startingAt offset: Int = 0) async {
        guard let meeting = selectedMeeting, isOptedIn, offset >= 0 else { return }
        cancelAndClear()
        let version = epoch
        do {
            let segments = try await meetingsStore.attributedSegments(for: meeting.id)
            try requireCurrent(version)
            extractionStart = offset; extractionTotalSegments = segments.count
            var remaining = 8_000, next = offset
            for segment in segments.dropFirst(offset) {
                guard remaining > 0, extractionPreview.count < 32 else { break }
                let text = String(segment.segment.text.prefix(min(1_000, remaining)))
                next += 1
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                remaining -= text.count
                extractionPreview.append(.init(
                    label: "\(segment.speakerLabel ?? (segment.segment.source == .mic ? "You" : "Them")) · \(Int(segment.segment.tStart))s",
                    text: text, source: .init(kind: .segment, sourceID: segment.segment.id, revision: 0,
                                            meetingID: meeting.id, startCharacter: 0, endCharacter: text.count),
                    statedAt: meeting.startedAt.addingTimeInterval(segment.segment.tStart)))
            }
            extractionNextOffset = next < segments.count ? next : nil
            selectedEvidenceIDs = Set(extractionPreview.map(\.id))
            if extractionPreview.isEmpty { notice = "This meeting has no transcript excerpts to extract from." }
        } catch { if epoch == version { report(error) } }
    }

    func sendExtraction() {
        guard let meeting = selectedMeeting, isOptedIn else { return }
        let evidence = extractionPreview.filter { selectedEvidenceIDs.contains($0.id) }
        guard !evidence.isEmpty else { return }
        let entities = linkedEntities.map(\.id)
        startWork("Extracting reviewable candidates…", clearPreviews: false) { version in
            guard try await self.memory.isOptedIn(meetingID: meeting.id) else { throw MemoryStoreError.notOptedIn }
            for item in evidence {
                guard try await self.memory.sourcePreview(item.source) == item.text else { throw MemoryGenerationError.staleContext }
            }
            let context = try await self.makeProviderContext(meeting.id)
            try self.requireCurrent(version)
            guard let context else {
                self.notice = "AI is unavailable right now. Check AI settings or finish the active meeting. Local documents and reviewed memory remain available."; return
            }
            let provider = context.withValidation { [memory = self.memory, weak self] in
                guard await self?.isCurrentVersion(version) == true else { return false }
                do {
                    guard try await memory.isOptedIn(meetingID: meeting.id) else { return false }
                    for item in evidence { guard try await memory.sourcePreview(item.source) == item.text else { return false } }
                    return await self?.isCurrentVersion(version) == true
                } catch { return false }
            }
            try self.requireCurrent(version)
            let candidates = try await MemoryExtractor().extract(evidence: evidence, statedAt: meeting.startedAt, entityIDs: entities, context: provider)
            try self.requireCurrent(version)
            guard await provider.isCurrent() else { throw MemoryGenerationError.staleContext }
            _ = try await self.memory.insertCandidates(candidates, meetingID: meeting.id)
            try self.requireCurrent(version)
            try await self.refreshSelection()
            self.extractionPreview = []; self.selectedEvidenceIDs = []
            self.notice = candidates.isEmpty ? "No supported memory candidates were found in those excerpts." : "\(candidates.count) candidate\(candidates.count == 1 ? "" : "s") ready for your review. Nothing has been approved automatically."
        }
    }

    func search() {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { errorMessage = "Enter a question or a few search words."; return }
        let request = RetrievalRequest(query: question, allowedMeetingIDs: queryMeetingIDs,
                                       allowedDocumentIDs: queryDocumentIDs,
                                       entityIDs: queryEntityID.map { [$0] }, asOf: useAsOfDate ? asOfDate : nil)
        startWork("Finding local sources…") { version in
            let bundle = try await self.memory.retrieve(request)
            try self.requireCurrent(version)
            self.contextPreview = bundle; self.previewRequest = request; self.previewQuestion = question
            self.selectedCitationIDs = Set(bundle.excerpts.map(\.citationID))
            if bundle.isEmpty { self.answer = .insufficient }
        }
    }

    func sendQuestion() {
        guard canSendAnswer, let meetingID = selectedMeetingID, let preview = contextPreview, let request = previewRequest else { return }
        let bundle = ContextBundle(excerpts: preview.excerpts.filter { selectedCitationIDs.contains($0.citationID) })
        let question = previewQuestion
        startWork("Answering from selected evidence…", clearPreviews: false) { version in
            guard try await self.memory.validate(bundle, for: request) else { throw MemoryGenerationError.staleContext }
            let context = try await self.makeProviderContext(meetingID)
            try self.requireCurrent(version)
            guard let context else {
                self.notice = "AI is unavailable right now. Check AI settings or finish the active meeting. You can still read the local evidence below."; return
            }
            let provider = context.withValidation { [memory = self.memory, weak self] in
                guard await self?.isCurrentVersion(version) == true else { return false }
                return (try? await memory.validate(bundle, for: request)) == true
            }
            try self.requireCurrent(version)
            let answer = try await GroundedAnswerGenerator().answer(question: question, context: bundle, provider: provider)
            try self.requireCurrent(version)
            guard await provider.isCurrent(), try await self.memory.validate(bundle, for: request) else { throw MemoryGenerationError.staleContext }
            try self.requireCurrent(version)
            guard self.queryMatches(request, question: question) else { throw MemoryGenerationError.staleContext }
            self.answer = answer
        }
    }

    /// Root calls this on AI-off, provider replacement, source deletion, or
    /// window closure. Keep task handles until their terminal cleanup drains.
    func cancelAndClear(notifySensitiveChange: Bool = true) {
        epoch &+= 1
        for task in operations.values { task.cancel() }
        for task in mutations.values { task.cancel() }
        busyMessage = nil
        clearPreviews()
        if notifySensitiveChange { onSensitiveContentChanged() }
    }
    /// Privacy deletion is stronger than AI cancellation: discard every local
    /// content snapshot immediately, including open navigation and filters.
    func forgetAllContent() {
        cancelAndClear()
        meetings = []; selectedMeetingID = nil; facts = []; entities = []; linkedEntities = []
        documents = []; documentLibrary = []; isOptedIn = false; isLoading = false
        query = ""; queryMeetingIDs = []; queryDocumentIDs = []; queryEntityID = nil
        useAsOfDate = false; asOfDate = Date()
        extractionTotalSegments = 0; extractionStart = 0; extractionNextOffset = nil
    }
    func cancelAndDrain() async {
        cancelAndClear()
        let tasks = Array(operations.values)
        for task in tasks { await task.value }
        let pendingMutations = Array(mutations.values)
        for task in pendingMutations { _ = await task.value }
    }
    func waitForOperations() async {
        let tasks = Array(operations.values)
        for task in tasks { await task.value }
    }
    func clearAnswer() { answer = nil }
    private func queryMatches(_ request: RetrievalRequest, question: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines) == question
            && request.allowedMeetingIDs == queryMeetingIDs
            && request.allowedDocumentIDs == queryDocumentIDs
            && request.entityIDs == queryEntityID.map { Set([$0]) }
            && request.asOf == (useAsOfDate ? asOfDate : nil)
    }
    private func clearPreviews() {
        answer = nil; contextPreview = nil; previewRequest = nil; previewQuestion = ""
        selectedCitationIDs = []; extractionPreview = []; selectedEvidenceIDs = []
        sourcePreview = nil; errorMessage = nil; notice = nil
    }
    private func requireCurrent(_ version: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == version else { throw MemoryGenerationError.staleContext }
    }
    private func isCurrentVersion(_ version: UInt64) -> Bool { epoch == version && !Task.isCancelled }
    private func startWork(_ message: String, clearPreviews: Bool = true,
                           operation: @escaping @MainActor (UInt64) async throws -> Void) {
        guard !isWorking else { return }
        if clearPreviews { cancelAndClear() }
        else { errorMessage = nil; notice = nil; answer = nil }
        let version = epoch, id = UUID()
        busyMessage = message
        operations[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.operations[id] = nil
                if self.epoch == version { self.busyMessage = nil }
            }
            do { try await operation(version) }
            catch is CancellationError {}
            catch { if self.epoch == version { self.report(error) } }
        }
    }
    @discardableResult
    private func mutate(_ operation: @escaping @MainActor () async throws -> Void) async -> Bool {
        cancelAndClear()
        let version = epoch, id = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            defer { self.mutations[id] = nil }
            do {
                try self.requireCurrent(version)
                try await operation()
                try self.requireCurrent(version)
                try await self.refreshSelection()
                try self.requireCurrent(version)
                return true
            } catch is CancellationError { return false }
            catch { if self.epoch == version { self.report(error) }; return false }
        }
        mutations[id] = task
        return await task.value
    }
    private func report(_ error: any Error) {
        if let error = error as? MemoryStoreError {
            switch error {
            case .aliasCollision: errorMessage = "That name already belongs to another person or project. Choose it from the list, or explicitly merge the two."
            case .revisionConflict: errorMessage = "This item changed while it was open. Refresh it and review your correction before trying again."
            case .notOptedIn: errorMessage = "Enable memory for this meeting before extracting candidates."
            case .indexingPaused: errorMessage = "Document indexing is paused while a meeting is capturing. Try again after it ends."
            case .ineligibleMeeting: errorMessage = "Choose a completed, saved meeting. Ephemeral and active meetings do not enter memory."
            case .capacityExceeded: errorMessage = "This import exceeds the local document limit. Use a smaller document or remove an unused snapshot."
            case .invalidContent: errorMessage = "Check the text and try again. Names and memory entries cannot be blank."
            case .invalidSource, .notFound: errorMessage = "The source changed or was removed. Refresh the workspace and try again."
            case .incompatibleEntity: errorMessage = "Only two people or two projects can be merged."
            }
        } else if let error = error as? DocumentParseError {
            switch error {
            case .encryptedPDF: errorMessage = "Choose an unencrypted PDF. Password-protected files are not imported."
            case .noExtractableText: errorMessage = "No text could be extracted. Scanned PDFs need a text layer before import."
            case .corruptPDF: errorMessage = "This PDF could not be read. Try another copy."
            case .invalidEncoding: errorMessage = "Save the text document as UTF-8 before importing it."
            case .oversizedFile: errorMessage = "Choose a document smaller than 10 MiB."
            case .tooManyPages: errorMessage = "PDF imports are limited to 200 pages."
            case .tooMuchText: errorMessage = "This document exceeds one million extracted characters."
            case .unsupportedFormat, .notLocalFile: errorMessage = "Choose a local UTF-8 text, Markdown, or text-PDF file."
            }
        } else if let error = error as? ProviderError {
            if case .capReached = error { errorMessage = error.userMessage }
            else { errorMessage = "AI could not complete this request. Check provider settings and try again; your local sources are unchanged." }
        } else if error is MemoryGenerationError {
            errorMessage = "The answer or its evidence could not be verified. Refresh the sources and try again."
        } else { errorMessage = "The change could not be completed. Try again." }
    }
}
