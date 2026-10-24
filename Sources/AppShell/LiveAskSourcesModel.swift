import AgentKit
import Foundation
import MemoryKit
import Observation
import PersistKit

@MainActor @Observable final class LiveAskSourcesModel: Identifiable {
    let id = UUID()
    let question: String
    let recentTranscript: [LiveTranscriptEvidence]
    private(set) var meetings: [MeetingRecord] = []
    private(set) var documents: [DocumentRecord] = []
    private(set) var entities: [MemoryEntity] = []
    private(set) var results: ContextBundle?
    private(set) var isSearching = false
    private(set) var message: String?
    private(set) var sourcePreview: String?
    var selectedMeetingIDs: Set<UUID> = [] { didSet { resetResults() } }
    var selectedDocumentIDs: Set<UUID> = [] { didSet { resetResults() } }
    var selectedEntityID: UUID? { didSet { resetResults() } }
    var useAsOf = false { didSet { resetResults() } }
    var asOf = Date() { didSet { resetResults() } }
    var selectedExternalIDs: Set<String> = []
    var selectedTranscriptIDs: Set<String>
    @ObservationIgnored private let meetingsStore: MeetingStore
    @ObservationIgnored private let documentsStore: DocumentStore
    @ObservationIgnored private let memory: MemoryStore
    @ObservationIgnored private let onSend: @MainActor (LiveQueryGrounding) async -> Bool
    @ObservationIgnored private var request: RetrievalRequest?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var revision: UInt64 = 0

    init(database: MacapyDatabase, question: String, recentTranscript: [LiveTranscriptEvidence],
         onSend: @escaping @MainActor (LiveQueryGrounding) async -> Bool) {
        self.question = question; self.recentTranscript = recentTranscript
        selectedTranscriptIDs = Set(recentTranscript.map(\.id))
        meetingsStore = MeetingStore(database: database); documentsStore = DocumentStore(database: database)
        memory = MemoryStore(database: database); self.onSend = onSend
    }
    var canSend: Bool { !isSearching && (!selectedTranscriptIDs.isEmpty || !selectedExternalIDs.isEmpty) }
    var selectedCharacters: Int {
        recentTranscript.filter { selectedTranscriptIDs.contains($0.id) }.reduce(0) { $0 + $1.text.count }
            + (results?.excerpts.filter { selectedExternalIDs.contains($0.citationID) }.reduce(0) { $0 + $1.text.count } ?? 0)
    }

    func load() async {
        let token = revision
        do {
            let rows = try await meetingsStore.listMeetings().filter { $0.hasEnded && !$0.ephemeral }
            let docs = try await documentsStore.documents().filter(\.allowedForAI)
            let names = try await memory.entities()
            guard revision == token, !Task.isCancelled else { return }
            meetings = rows; documents = docs; entities = names
        } catch { if revision == token { message = "Saved sources could not be read. Meeting-only Ask is still available." } }
    }
    func search() {
        resetResults()
        let token = revision
        let request = RetrievalRequest(query: question, allowedMeetingIDs: selectedMeetingIDs,
            allowedDocumentIDs: selectedDocumentIDs, entityIDs: selectedEntityID.map { [$0] },
            asOf: useAsOf ? asOf : nil, maxExcerpts: 4, maxCharacters: 4_000)
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            defer { if revision == token { isSearching = false; searchTask = nil } }
            do {
                let context = try await memory.retrieve(request)
                try Task.checkCancellation()
                guard revision == token else { return }
                results = context; self.request = request
                selectedExternalIDs = Set(context.excerpts.map(\.citationID))
                if context.isEmpty { message = "No matching reviewed or allowed sources. You can use the recent transcript alone." }
            } catch is CancellationError {} catch { if revision == token { message = "Local source lookup failed. Meeting-only Ask remains available." } }
        }
    }
    func waitForSearch() async { await searchTask?.value }
    func preview(_ source: SourceReference) async {
        let token = revision
        do {
            let text = try await memory.sourcePreview(source)
            if revision == token { sourcePreview = text ?? "This source changed or was removed." }
        } catch { if revision == token { sourcePreview = "This source is no longer available." } }
    }
    func send() async -> Bool {
        guard canSend else { return false }
        let token = revision
        let external = ContextBundle(excerpts: results?.excerpts.filter { selectedExternalIDs.contains($0.citationID) } ?? [])
        let recent = recentTranscript.filter { selectedTranscriptIDs.contains($0.id) }
        let request = self.request
        let memory = memory
        let validate: @Sendable () async -> Bool = {
            if external.isEmpty { return true }
            guard let request else { return false }
            return (try? await memory.validate(external, for: request)) == true
        }
        do {
            guard await validate(), token == revision, !Task.isCancelled else {
                if token == revision { message = "A source changed. Find sources again before sending." }; return false
            }
            let selection = try LiveQueryGrounding(external: external, recentTranscript: recent, validateExternal: validate)
            return await onSend(selection)
        } catch { message = "This selection could not be verified. Refresh the sources before sending."; return false }
    }
    func cancel() {
        resetResults(); meetings = []; documents = []; entities = []; sourcePreview = nil
    }
    private func resetResults() {
        revision &+= 1; searchTask?.cancel(); searchTask = nil; isSearching = false
        results = nil; request = nil; selectedExternalIDs = []; sourcePreview = nil; message = nil
    }
}
