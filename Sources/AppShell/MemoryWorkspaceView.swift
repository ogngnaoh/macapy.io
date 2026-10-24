import AppKit
import MemoryKit
import PersistKit
import SwiftUI
import UniformTypeIdentifiers

/// Flat native surfaces, restrained color, generous reading space, and direct
/// source links follow the stored Acne-inspired system shared by History.
struct MemoryWorkspaceView: View {
    @Bindable var model: MemoryWorkspaceModel
    var isEmbedded = false
    @State private var tab = WorkspaceTab.review
    @State private var editingFact: MemoryFact?
    @State private var managingEntity: MemoryEntity?
    @State private var addingEntity = false
    @State private var pendingDelete: PendingDelete?
    @State private var showingFilters = false

    private enum WorkspaceTab: String, CaseIterable { case review = "review", documents = "documents", ask = "ask" }
    private enum PendingDelete: Identifiable {
        case fact(MemoryFact), document(DocumentRecord), entity(MemoryEntity), memory
        var id: String {
            switch self { case .fact(let value): value.id.uuidString; case .document(let value): value.id.uuidString
            case .entity(let value): value.id.uuidString; case .memory: "memory" }
        }
        var title: String {
            switch self { case .fact: "Delete this memory?"; case .document(let doc): "Remove “\(doc.name)” from every meeting?"
            case .entity(let entity): "Delete “\(entity.name)” and its aliases?"; case .memory: "Turn off memory for this meeting?" }
        }
        var message: String {
            switch self {
            case .fact: "The fact and its source links will be removed. Its original meeting stays in History."
            case .document: "The local text snapshot, chunks, vectors, and dependent memory are removed. The original file is unchanged."
            case .entity: "Meeting associations and aliases are removed. Source-linked facts remain available without this association."
            case .memory: "All memory candidates and reviewed facts for this meeting will be removed. Its transcript and artifacts remain in History."
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 235)
            Rectangle().fill(DesignTokens.hairlineStrong).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header
                navigation
                feedback
                if model.selectedMeeting == nil {
                    EmptyStateView(title: "start with a saved meeting", message: "Completed meetings appear here. Ephemeral sessions do not enter memory.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DesignTokens.Space.s5) {
                            switch tab {
                            case .review: reviewContent
                            case .documents: documentContent
                            case .ask: askContent
                            }
                        }
                        .padding(DesignTokens.Space.s5)
                        .frame(maxWidth: 1050, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(minWidth: 960, idealWidth: 1120, minHeight: isEmbedded ? 440 : 650, idealHeight: isEmbedded ? 560 : 760)
        .background(DesignTokens.bg)
        .foregroundStyle(DesignTokens.text)
        .task { await model.load() }
        .onDisappear { model.cancelAndClear(notifySensitiveChange: false) }
        .sheet(item: $model.sourcePreview) { source in WorkspaceSourceSheet(source: source) }
        .sheet(item: $editingFact) { fact in WorkspaceFactEditor(model: model, fact: fact) }
        .sheet(item: $managingEntity) { entity in WorkspaceEntityManager(model: model, original: entity) }
        .sheet(isPresented: $addingEntity) { WorkspaceEntityCreator(model: model) }
        .sheet(isPresented: $showingFilters) { WorkspaceSourceFilters(model: model) }
        .confirmationDialog(pendingDelete?.title ?? "Remove item?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("remove", role: .destructive) {
                    guard let pendingDelete else { return }
                    Task {
                        switch pendingDelete {
                        case .fact(let fact): await model.delete(fact)
                        case .document(let document): await model.deleteDocument(document.id)
                        case .entity(let entity): await model.deleteEntity(entity.id)
                        case .memory: await model.setOptIn(false)
                        }
                        self.pendingDelete = nil
                    }
                }
            } message: { Text(pendingDelete?.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("saved meetings").font(UIType.bodySemibold)
                .padding(.horizontal, 20).padding(.vertical, 25)
            Rectangle().fill(DesignTokens.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.meetings) { meeting in
                        Button { Task { await model.selectMeeting(meeting.id) } } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(meeting.title).font(UIType.bodySemibold).lineLimit(2)
                                Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day().year())
                                    .font(UIType.small).foregroundStyle(DesignTokens.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DesignTokens.Space.s4)
                            .background(model.selectedMeetingID == meeting.id ? DesignTokens.bg : .clear)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(model.selectedMeetingID == meeting.id ? DesignTokens.text : .clear).frame(width: 3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(model.selectedMeetingID == meeting.id ? "Selected" : "")
                        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairline).frame(height: 1) }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("saved on this mac\nnothing remembered automatically")
                .font(UIType.small).foregroundStyle(DesignTokens.textSecondary).lineSpacing(4)
                .padding(DesignTokens.Space.s4)
        }
        .background(DesignTokens.sunken)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.s3) {
            VStack(alignment: .leading, spacing: 8) {
                Text("memory & sources").font(.system(size: 28, weight: .regular))
                Text(model.selectedMeeting?.title ?? "your source-linked library")
                    .font(UIType.reading).foregroundStyle(DesignTokens.textSecondary).lineLimit(2)
            }
            Spacer()
            Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(SubtleButtonStyle()).help("Refresh local sources").accessibilityLabel("Refresh local sources")
        }
        .padding(DesignTokens.Space.s5)
    }

    private var navigation: some View {
        HStack(spacing: DesignTokens.Space.s5) {
            ForEach(WorkspaceTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Text(item.rawValue).font(UIType.bodySemibold)
                        .foregroundStyle(tab == item ? DesignTokens.text : DesignTokens.textSecondary)
                        .padding(.vertical, DesignTokens.Space.s3)
                        .overlay(alignment: .bottom) { Rectangle().fill(tab == item ? DesignTokens.text : .clear).frame(height: 2) }
                }
                .buttonStyle(.plain)
                .accessibilityValue(tab == item ? "Selected" : "")
            }
            Spacer()
            Text("\(model.facts.filter { $0.status == .approved }.count) reviewed · \(model.documents.count) document\(model.documents.count == 1 ? "" : "s")")
                .font(UIType.small).foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(.horizontal, DesignTokens.Space.s5)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairline).frame(height: 1) }
    }

    @ViewBuilder private var feedback: some View {
        if let error = model.errorMessage {
            Text(error).font(UIType.compactReading).foregroundStyle(DesignTokens.statusRejected)
                .frame(maxWidth: .infinity, alignment: .leading).padding(DesignTokens.Space.s3)
                .background(DesignTokens.statusRejectedSurface).accessibilityLabel("Error: \(error)")
        } else if let notice = model.notice {
            Text(notice).font(UIType.compactReading).foregroundStyle(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(DesignTokens.Space.s3).background(DesignTokens.cream)
        }
        if let message = model.busyMessage {
            HStack { ProgressView().controlSize(.small); Text(message).font(UIType.small); Spacer()
                Button("cancel") { model.cancelAndClear() }.buttonStyle(SubtleButtonStyle()) }
                .padding(DesignTokens.Space.s3).background(DesignTokens.sunken)
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("keep what matters.").font(UIType.heading)
                    FormNote("review a source before you remember it. only approved facts enter future context.")
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 15) {
                    Toggle("memory on", isOn: Binding(get: { model.isOptedIn }, set: { enabled in
                        if enabled { Task { await model.setOptIn(true) } } else { pendingDelete = .memory }
                    })).toggleStyle(.checkbox).font(UIType.body).fixedSize()
                    if model.isOptedIn {
                        Button("review excerpts") { Task { await model.prepareExtraction() } }
                            .buttonStyle(SubtleButtonStyle()).disabled(model.isWorking)
                    }
                }
            }
            DisclosureGroup {
                associations
            } label: {
                HStack(spacing: 15) {
                    Text("people & projects").font(UIType.bodySemibold)
                    Text(model.linkedEntities.isEmpty ? "none linked" : model.linkedEntities.map(\.name).joined(separator: " · "))
                        .font(UIType.small).foregroundStyle(DesignTokens.textSecondary).lineLimit(1)
                }
            }
            .padding(.vertical, 15)
            .overlay(alignment: .top) { Rectangle().fill(DesignTokens.hairline).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairline).frame(height: 1) }
            if model.isOptedIn {
                if !model.extractionPreview.isEmpty { extractionReview }
                if model.facts.isEmpty {
                    workspaceNote("no memory yet", "review transcript excerpts first. ai proposes candidates; you choose what becomes reusable context.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.facts) { fact in
                            WorkspaceFactRow(fact: fact,
                                approve: { Task { await model.review(fact, status: .approved) } },
                                reject: { Task { await model.review(fact, status: .rejected) } },
                                edit: { editingFact = fact }, supersede: { Task { await model.supersede(fact) } },
                                delete: { pendingDelete = .fact(fact) }, complete: { Task { await model.complete(fact, complete: fact.completedAt == nil) } },
                                source: { ref in Task { await model.showSource(ref) } })
                        }
                    }
                }
            } else {
                workspaceNote("memory is off for this meeting", "enable it to extract and review source-linked candidates. documents and local search remain available.")
            }
        }
    }

    private var associations: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            HStack {
                Text("people & projects").font(MachineType.label())
                Spacer()
                Menu("link existing") {
                    ForEach(model.entities.filter { entity in !model.linkedEntities.contains { $0.id == entity.id } }) { entity in
                        Button("\(entity.name) · \(entity.kind.rawValue)") { Task { await model.linkEntity(entity.id) } }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
                Button("new…") { addingEntity = true }.buttonStyle(SubtleButtonStyle())
            }
            if model.linkedEntities.isEmpty { FormNote("link people or projects explicitly. speaker voices are never matched across meetings.") }
            ForEach(model.linkedEntities) { entity in
                HStack {
                    Text(entity.kind == .person ? "person" : "project").font(MachineType.label()).foregroundStyle(DesignTokens.textSecondary).frame(width: 65, alignment: .leading)
                    Text(entity.name).font(UIType.compactReading)
                    Spacer()
                    Button("names & aliases…") { managingEntity = entity }.buttonStyle(SubtleButtonStyle())
                    Menu {
                        Button("unlink from this meeting") { Task { await model.unlinkEntity(entity.id) } }
                        Button("delete person / project…", role: .destructive) { pendingDelete = .entity(entity) }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 25)
                }.padding(.vertical, 7)
            }
        }
        .padding(.top, 15)
    }

    private var extractionReview: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Text("review before sending").font(UIType.heading)
            FormNote("\(model.extractionPreview.count) excerpts starting at segment \(model.extractionStart + 1) of \(model.extractionTotalSegments). Each excerpt is at most 1,000 characters. Only checked text is sent; the transcript stays unchanged.")
            ForEach(model.extractionPreview) { item in
                Toggle(isOn: selection(item.id, in: $model.selectedEvidenceIDs)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.label).font(MachineType.label()).foregroundStyle(DesignTokens.textSecondary)
                        Text(verbatim: item.text).font(UIType.compactReading).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.checkbox).disabled(model.isWorking)
                Divider()
            }
            HStack {
                Text("\(model.selectedExtractionCharacters) characters selected").font(UIType.small).foregroundStyle(DesignTokens.textSecondary)
                Spacer()
                if let next = model.extractionNextOffset {
                    Button("next excerpts") { Task { await model.prepareExtraction(startingAt: next) } }.buttonStyle(SubtleButtonStyle())
                }
                Button("send selected & extract") { model.sendExtraction() }.buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isWorking || model.selectedEvidenceIDs.isEmpty)
            }
            FormNote("uses this meeting’s configured provider and remaining spend cap. generated candidates still require your review.")
        }
        .padding(20).background(DesignTokens.sunken).overlay(Rectangle().stroke(DesignTokens.hairlineStrong, lineWidth: 1))
    }

    private var documentContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("bring the relevant context").font(UIType.heading)
                    FormNote("import text, Markdown, or text-PDF. macapy keeps an extracted text snapshot on this mac. your original file is unchanged.")
                }
                Spacer()
                Button("import document…") { chooseDocument() }.buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isWorking || model.isCaptureActive)
            }
            FormNote("10 MiB per file · 200 PDF pages · 1 million extracted characters · lexical retrieval. reimport explicitly to refresh a changed file.")
            if model.isCaptureActive { workspaceNote("Indexing paused.", "Finish the current capture before importing or refreshing documents.") }
            if model.documents.isEmpty { workspaceNote("No attached documents.", "A product brief, agenda, or project note gives your meeting a useful reference point.") }
            ForEach(model.documents) { document in
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Button(document.name) { Task { await model.showDocument(document) } }.buttonStyle(.plain).font(UIType.reading)
                            Text("Revision \(document.revision) · updated \(document.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(UIType.small).foregroundStyle(DesignTokens.textSecondary)
                        }
                        Spacer()
                        Toggle("allow in ai context", isOn: Binding(get: { document.allowedForAI }, set: { allowed in Task { await model.setDocumentConsent(allowed, id: document.id) } }))
                            .toggleStyle(.switch).font(UIType.small)
                    }
                    HStack {
                        Button("read snapshot") { Task { await model.showDocument(document) } }.buttonStyle(SubtleButtonStyle())
                        Button("reimport…") { chooseDocument(replacing: document) }.buttonStyle(SubtleButtonStyle()).disabled(model.isCaptureActive)
                        Spacer()
                        Button("detach") { Task { await model.detachDocument(document.id) } }.buttonStyle(SubtleButtonStyle())
                        Button("remove everywhere…") { pendingDelete = .document(document) }.buttonStyle(SubtleButtonStyle())
                    }
                }
                .padding(.vertical, DesignTokens.Space.s4)
                .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairlineStrong).frame(height: 1) }
            }
            let available = model.documentLibrary.filter { doc in !model.documents.contains { $0.id == doc.id } }
            if !available.isEmpty {
                Menu("attach an existing snapshot") {
                    ForEach(available) { doc in Button(doc.name) { Task { await model.attachDocument(doc.id) } } }
                }.fixedSize()
            }
            FormNote("detaching the final meeting attachment deletes the local snapshot and its index. exported files and your original document remain under your control.")
        }
    }

    private var askContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            Text("ask with evidence").font(UIType.heading)
            FormNote("search selected sources locally first. review exactly which excerpts may leave your mac before asking ai for an answer.")
            HStack {
                TextField("what did we decide about the launch?", text: $model.query)
                    .textFieldStyle(.plain).font(UIType.reading).padding(12)
                    .overlay(Rectangle().stroke(DesignTokens.hairlineStrong, lineWidth: 1))
                    .onSubmit { model.search() }
                Button("find sources") { model.search() }.buttonStyle(PrimaryButtonStyle()).disabled(model.isWorking)
            }
            HStack {
                Button("sources & dates…") { showingFilters = true }.buttonStyle(SubtleButtonStyle())
                Text("\(model.queryMeetingIDs.count) meeting\(model.queryMeetingIDs.count == 1 ? "" : "s") · \(model.queryDocumentIDs.count) document\(model.queryDocumentIDs.count == 1 ? "" : "s")")
                    .font(UIType.small).foregroundStyle(DesignTokens.textSecondary)
                Spacer()
                Chip(text: "local lexical search")
            }
            if let answer = model.answer {
                VStack(alignment: .leading, spacing: 12) {
                    Text(answer.insufficientEvidence ? "not enough evidence" : "answer from your sources").font(UIType.heading)
                    Text(verbatim: answer.text).font(UIType.reading).lineSpacing(5).textSelection(.enabled)
                    ForEach(answer.citationIDs, id: \.self) { id in
                        if let excerpt = model.contextPreview?.excerpts.first(where: { $0.citationID == id }), let source = excerpt.sources.first {
                            Button("↗ \(excerpt.title)") { Task { await model.showSource(source, title: excerpt.title) } }
                                .buttonStyle(.plain).foregroundStyle(DesignTokens.accent).font(UIType.small)
                        }
                    }
                }.padding(DesignTokens.Space.s4).background(DesignTokens.cream)
            }
            if let context = model.contextPreview, !context.excerpts.isEmpty {
                HStack {
                    Text("review selected evidence").font(MachineType.label())
                    Spacer()
                    Button("send selected & ask ai") { model.sendQuestion() }.buttonStyle(PrimaryButtonStyle()).disabled(!model.canSendAnswer)
                }
                FormNote("\(model.selectedExcerptCount) excerpts selected. uses this meeting’s provider and remaining cap. search again after changing the question or filters.")
                ForEach(context.excerpts) { excerpt in
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: selection(excerpt.citationID, in: $model.selectedCitationIDs)) {
                            Text(excerpt.title).font(UIType.bodySemibold)
                        }.toggleStyle(.checkbox).disabled(model.isWorking)
                        Text(verbatim: excerpt.text).font(UIType.compactReading).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text(excerpt.factID == nil ? "document excerpt" : "reviewed memory").font(MachineType.label()).foregroundStyle(DesignTokens.textSecondary)
                            Spacer()
                            ForEach(Array(excerpt.sources.enumerated()), id: \.offset) { index, source in
                                Button("source \(index + 1) ↗") { Task { await model.showSource(source, title: excerpt.title) } }
                                    .buttonStyle(.plain).foregroundStyle(DesignTokens.accent).font(UIType.small)
                            }
                        }
                    }
                    .padding(DesignTokens.Space.s4).overlay(Rectangle().stroke(DesignTokens.hairlineStrong, lineWidth: 1))
                }
            }
        }
        .onChange(of: model.selectedCitationIDs) { _, _ in model.clearAnswer() }
    }

    private func chooseDocument(replacing document: DocumentRecord? = nil) {
        Task {
            let panel = NSOpenPanel(); panel.title = document == nil ? "Import local document" : "Reimport local document"
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.plainText, .pdf, UTType(filenameExtension: "md") ?? .text, UTType(filenameExtension: "markdown") ?? .text]
            guard await panel.begin() == .OK, let url = panel.url else { return }
            model.importDocument(url: url, replacing: document)
        }
    }
    private func workspaceNote(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(UIType.reading); FormNote(text) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(DesignTokens.Space.s4).background(DesignTokens.sunken)
    }
    private func selection(_ id: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { selected in
            if selected { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }
}

private struct WorkspaceFactRow: View {
    let fact: MemoryFact
    let approve: () -> Void, reject: () -> Void, edit: () -> Void, supersede: () -> Void, delete: () -> Void, complete: () -> Void
    let source: (SourceReference) -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(fact.kind == .commitment ? "action" : fact.kind.rawValue)
                    .font(UIType.small).foregroundStyle(DesignTokens.textSecondary)
                Chip(text: fact.status == .approved ? "reviewed" : fact.status.rawValue)
            }
            .frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: fact.text).font(UIType.reading).lineSpacing(4)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 15) {
                    ForEach(Array(fact.sources.enumerated()), id: \.offset) { index, ref in
                        Button("source \(index + 1) ↗") { source(ref) }
                            .buttonStyle(.plain).foregroundStyle(DesignTokens.accent).font(UIType.small)
                    }
                    Spacer(minLength: 0)
                    Text(fact.statedAt, format: .dateTime.month(.abbreviated).day().year())
                        .font(UIType.small).foregroundStyle(DesignTokens.textSecondary)
                }
                if fact.status != .superseded && fact.status != .approved {
                    HStack(spacing: 10) {
                        if fact.status != .rejected { Button("reject", action: reject).buttonStyle(SubtleButtonStyle()) }
                        Button("approve memory", action: approve).buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 15) {
                Menu {
                    if fact.status != .superseded {
                        Button("edit…", action: edit)
                        Button("mark superseded", action: supersede)
                        if fact.status == .approved { Button("reject", action: reject) }
                    }
                    Button("delete…", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis").frame(width: 25, height: 20) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Memory actions")
                if fact.kind == .commitment && fact.status != .superseded {
                    Button(fact.completedAt == nil ? "mark done" : "reopen", action: complete)
                        .buttonStyle(SubtleButtonStyle()).fixedSize()
                }
            }
        }
        .padding(.vertical, 20)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairline).frame(height: 1) }
    }
}

private struct WorkspaceSourceSheet: View {
    let source: MemoryWorkspaceModel.SourcePreview
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(source.title).font(UIType.heading); Spacer(); Button("done") { dismiss() }.buttonStyle(SubtleButtonStyle()).keyboardShortcut(.cancelAction) }
            FormNote("current local source · read only")
            ScrollView { Text(verbatim: source.text).font(UIType.reading).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(30).frame(width: 640, height: 550).background(DesignTokens.bg)
    }
}

private struct WorkspaceFactEditor: View {
    @Bindable var model: MemoryWorkspaceModel
    let fact: MemoryFact
    @State private var text = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("correct this memory").font(UIType.heading)
            FormNote("source evidence stays attached. saving returns this fact to pending review. if someone changed it while this editor was open, your correction will not overwrite their change.")
            TextEditor(text: $text).font(UIType.reading).frame(height: 160).padding(8).overlay(Rectangle().stroke(DesignTokens.hairlineStrong, lineWidth: 1))
            if let error = model.errorMessage { Text(error).font(UIType.small).foregroundStyle(DesignTokens.statusRejected) }
            HStack { Button("cancel") { dismiss() }.buttonStyle(SubtleButtonStyle()).keyboardShortcut(.cancelAction); Spacer()
                Button(saving ? "saving…" : "save correction") { Task { saving = true; if await model.edit(fact, text: text) { dismiss() }; saving = false } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(30).frame(width: 550).background(DesignTokens.bg).onAppear { text = fact.text }
    }
}

private struct WorkspaceEntityCreator: View {
    @Bindable var model: MemoryWorkspaceModel
    @State private var name = ""
    @State private var kind = MemoryEntityKind.project
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("add a connection").font(UIType.heading)
            Picker("kind", selection: $kind) { Text("project").tag(MemoryEntityKind.project); Text("person").tag(MemoryEntityKind.person) }.pickerStyle(.segmented)
            TextField("name", text: $name).textFieldStyle(.plain).padding(10).overlay(Rectangle().stroke(DesignTokens.hairlineStrong))
            FormNote("this explicitly links the name to the selected meeting. macapy does not infer that two speakers are the same person.")
            if let error = model.errorMessage { Text(error).font(UIType.small).foregroundStyle(DesignTokens.statusRejected) }
            HStack { Button("cancel") { dismiss() }.buttonStyle(SubtleButtonStyle()); Spacer()
                Button("create & link") { Task { saving = true; if await model.createEntity(name: name, kind: kind) { dismiss() }; saving = false } }.buttonStyle(PrimaryButtonStyle()).disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(30).frame(width: 460).background(DesignTokens.bg)
    }
}

private struct WorkspaceEntityManager: View {
    @Bindable var model: MemoryWorkspaceModel
    let original: MemoryEntity
    @State private var alias = ""
    @State private var mergeTarget: UUID?
    @State private var confirmingMerge = false
    @Environment(\.dismiss) private var dismiss
    private var entity: MemoryEntity { model.entities.first { $0.id == original.id } ?? original }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(entity.name).font(UIType.heading)
            FormNote("Confirmed aliases help you find this \(entity.kind.rawValue). Names belonging to another entry are never merged automatically.")
            ForEach(entity.aliases, id: \.self) { name in
                HStack { Text(name).font(UIType.compactReading); Spacer()
                    if name != entity.name { Button("remove alias") { Task { await model.removeAlias(name, from: entity.id) } }.buttonStyle(SubtleButtonStyle()) } }
            }
            HStack { TextField("another name", text: $alias).textFieldStyle(.plain).padding(10).overlay(Rectangle().stroke(DesignTokens.hairlineStrong))
                Button("add alias") { Task { if await model.addAlias(alias, to: entity.id) { alias = "" } } }.buttonStyle(SubtleButtonStyle()).disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            Divider()
            Picker("merge into", selection: $mergeTarget) {
                Text("choose explicitly…").tag(UUID?.none)
                ForEach(model.entities.filter { $0.kind == entity.kind && $0.id != entity.id }) { target in Text(target.name).tag(Optional(target.id)) }
            }
            Button("review merge…") { confirmingMerge = true }.buttonStyle(SubtleButtonStyle()).disabled(mergeTarget == nil)
            if let error = model.errorMessage { Text(error).font(UIType.small).foregroundStyle(DesignTokens.statusRejected) }
            HStack { Spacer(); Button("done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.cancelAction) }
        }.padding(30).frame(width: 520).background(DesignTokens.bg)
        .confirmationDialog("Merge \(entity.name) into the selected entry?", isPresented: $confirmingMerge, titleVisibility: .visible) {
            Button("merge names and associations") { guard let mergeTarget else { return }; Task { if await model.mergeEntity(entity.id, into: mergeTarget) { dismiss() } } }
        } message: { Text("aliases and meeting associations will transfer to the selected entry. original fact provenance remains attached. this is an explicit identity decision.") }
    }
}

private struct WorkspaceSourceFilters: View {
    @Bindable var model: MemoryWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("choose the evidence boundary").font(UIType.heading)
            FormNote("only reviewed memory and allowed document snapshots from these meetings are searched. no matches means an honest empty result.")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("meetings").font(MachineType.label())
                    ForEach(model.meetings) { meeting in Toggle(meeting.title, isOn: selection(meeting.id, in: $model.queryMeetingIDs)).toggleStyle(.checkbox) }
                    Divider().padding(.vertical, 8)
                    Text("document snapshots").font(MachineType.label())
                    ForEach(model.documentLibrary.filter(\.allowedForAI)) { document in Toggle(document.name, isOn: selection(document.id, in: $model.queryDocumentIDs)).toggleStyle(.checkbox) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 250)
            Picker("person or project", selection: $model.queryEntityID) {
                Text("any linked connection").tag(UUID?.none)
                ForEach(model.entities) { entity in Text(entity.name).tag(Optional(entity.id)) }
            }
            Toggle("only evidence stated / imported on or before", isOn: $model.useAsOfDate).toggleStyle(.checkbox)
            if model.useAsOfDate { DatePicker("as of", selection: $model.asOfDate, displayedComponents: [.date, .hourAndMinute]) }
            HStack { Spacer(); Button("done · search to apply") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.cancelAction) }
        }.padding(30).frame(width: 560).background(DesignTokens.bg)
    }
    private func selection(_ id: UUID, in values: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { selected in
            if selected { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }
}
