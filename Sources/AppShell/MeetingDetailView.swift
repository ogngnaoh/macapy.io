import AppKit
import ActionKit
import PersistKit
import SwiftUI
import TranscribeKit
import UniformTypeIdentifiers

/// Meeting detail (docs/design/05-meeting-detail.html): header bar (click-to-edit
/// title, meta line, Delete…), transcript replay with minute dividers on the
/// left, artifacts pane on the right — drafts under review, or the pending /
/// setup / cap-halt states when there are no rows yet.
struct MeetingDetailView: View {
    let store: MeetingStore
    let meeting: MeetingRecord
    /// `nil` model ⇒ the pane shows its unavailable state (previews, or a
    /// database that failed to open).
    let makeModel: @MainActor (MeetingRecord) -> MeetingDetailModel?
    /// Passage deep-link (slice-05 doc decision 5): scroll to this segment
    /// and wash it in `signalSoft` briefly, then report it consumed.
    var targetSegmentID: UUID?
    var onTargetConsumed: () -> Void = {}
    /// Rename commit; false (empty title) reverts the editor. `nil` disables
    /// editing (previews).
    var onRename: ((String) async -> Bool)?
    /// Per-meeting delete (slice-05 doc decision 7); the button is hidden
    /// while the meeting is active, and absent when no closure is wired.
    var onDelete: (() async -> Void)?

    @State private var segments: [AttributedSegment] = []
    @State private var transcriptError: String?
    @State private var model: MeetingDetailModel?
    @State private var highlightedSegmentID: UUID?
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var confirmingDelete = false
    @State private var showingExport = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if meeting.status == MeetingRecord.interruptedStatus {
                Label("Recovered committed transcript after an interrupted session. Audio and unsaved words cannot be recovered.",
                      systemImage: "exclamationmark.triangle")
                    .font(UIType.small)
                    .foregroundStyle(DesignTokens.statusWarning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Space.s3)
                    .background(DesignTokens.statusWarningSurface)
            }
            HStack(spacing: 0) {
                transcriptPane
                    .frame(maxWidth: .infinity)
                Divider().overlay(DesignTokens.hairline)
                ArtifactsPane(model: model)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 430)
            }
        }
        .background(DesignTokens.bg)
        .sheet(isPresented: $showingExport) {
            if let model { MeetingExportSheet(model: model) }
        }
        .task(id: meeting.id) {
            await loadTranscript()
            let built = makeModel(meeting)
            model = built
            await built?.load()
        }
    }

    // MARK: - Header (the mockup's titlebar row)

    private var headerBar: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                if isEditingTitle {
                    TextField("meeting title", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(DesignTokens.text)
                        .focused($titleFocused)
                        .onSubmit { Task { await commitRename() } }
                        .onExitCommand { isEditingTitle = false }
                        .onChange(of: titleFocused) { _, focused in
                            if !focused && isEditingTitle { Task { await commitRename() } }
                        }
                } else {
                    Button {
                        guard onRename != nil else { return }
                        titleDraft = meeting.title
                        isEditingTitle = true
                        titleFocused = true
                    } label: {
                        Text(meeting.title)
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(DesignTokens.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(onRename == nil)
                    .accessibilityLabel("Meeting title: \(meeting.title). Click to rename")
                }
                Text(HistoryRowFormat.detailMetaLine(startedAt: meeting.startedAt, endedAt: meeting.endedAt))
                    .font(UIType.small)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            Spacer(minLength: 0)
            if meeting.hasEnded, let model {
                Button("copy / export…") { showingExport = true }
                    .buttonStyle(SubtleButtonStyle()).disabled(model.isExporting)
            }
            if meeting.hasEnded, onDelete != nil {
                Menu {
                    Button("delete meeting…", role: .destructive) { confirmingDelete = true }
                } label: { Image(systemName: "ellipsis").frame(width: 25, height: 25) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Meeting actions")
            }
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 25)
        .background(DesignTokens.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairline).frame(height: 1) }
        .confirmationDialog(
            "Delete “\(meeting.title)”?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("delete meeting", role: .destructive) {
                Task { await onDelete?() }
            }
        } message: {
            Text("its transcript, artifacts, and spend records are removed from this mac. this can't be undone.")
        }
    }

    private func commitRename() async {
        isEditingTitle = false
        guard let onRename else { return }
        // An empty title is rejected downstream; the editor simply reverts
        // (check 5's UI half — nothing is stored).
        _ = await onRename(titleDraft)
    }

    // MARK: - Transcript

    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(TranscriptRows.build(segments: segments)) { row in
                        transcriptRow(row)
                    }
                }
                .padding(.vertical, DesignTokens.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: targetSegmentID) { _, target in
                scrollToTarget(target, proxy: proxy)
            }
            .onChange(of: segments.isEmpty) { _, isEmpty in
                if !isEmpty {
                    scrollToTarget(targetSegmentID, proxy: proxy)
                }
            }
        }
        .overlay {
            if segments.isEmpty {
                if let transcriptError {
                    EmptyStateView(title: "couldn't load transcript", message: transcriptError)
                } else {
                    EmptyStateView(title: "no transcript", message: "This meeting has no captured lines.")
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ row: TranscriptRows.Row) -> some View {
        switch row {
        case .minuteMark(let minute):
            Text(TranscriptRows.timestampLabel(minute: minute))
                .font(MachineType.number(11))
                .foregroundStyle(DesignTokens.textTertiary)
                .padding(.horizontal, DesignTokens.Space.s3)
                .padding(.top, 6)
                .padding(.bottom, 2)
                .accessibilityLabel("Minute \(TranscriptRows.timestampLabel(minute: minute))")
        case .line(let attributed):
            TranscriptLineView(
                speaker: attributed.speakerLabel
                    ?? PanelView.speakerLabel(for: attributed.segment.source),
                isYou: attributed.segment.source == .mic,
                text: attributed.segment.text,
                isVolatile: false
            )
            .background(
                highlightedSegmentID == attributed.segment.id ? DesignTokens.signalSoft : .clear
            )
            .id(attributed.segment.id)
        }
    }

    /// The shipped PanelView scroll mechanism (`ScrollViewReader` + `.id()`),
    /// pointed at the deep-link target, plus the brief `signalSoft` wash.
    private func scrollToTarget(_ target: UUID?, proxy: ScrollViewProxy) {
        guard let target, segments.contains(where: { $0.segment.id == target }) else { return }
        proxy.scrollTo(target, anchor: .center)
        highlightedSegmentID = target
        onTargetConsumed()
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if highlightedSegmentID == target {
                withAnimation(.easeOut(duration: 0.4)) { highlightedSegmentID = nil }
            }
        }
    }

    private func loadTranscript() async {
        do {
            segments = try await store.attributedSegments(for: meeting.id)
        } catch {
            transcriptError = "The transcript could not be opened. Reopen this meeting and try again."
        }
    }
}

// MARK: - Artifacts pane

private struct ArtifactsPane: View {
    let model: MeetingDetailModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                content
            }
            .padding(DesignTokens.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.surface)
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            switch model.state {
            case .loading:
                ProgressView("loading meeting output…")
                    .font(UIType.small)
            case .review:
                ReviewSections(model: model)
            case .meetingInProgress:
                PaneNote(text: "Artifacts are drafted when the meeting ends.")
            case .pending:
                pendingNote(model: model)
            case .needsProvider:
                PaneNote(text: "Add a provider in Settings to draft a summary, decisions, and action items from this meeting.")
            case .halted(let spentUSD, let capUSD):
                PaneNote(text: String(
                    format: "ai stopped at this meeting's $%.2f cap ($%.2f spent). The transcript is complete and safe.",
                    capUSD, spentUSD))
            case .generating:
                HStack(spacing: DesignTokens.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text("drafting artifacts…")
                        .font(UIType.small)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                .accessibilityElement(children: .combine)
            case .failed(let message):
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    PaneNote(text: message)
                    generateButton(model: model, title: "try again")
                }
            case .unavailable:
                PaneNote(text: "Artifacts are unavailable — the meeting database couldn't be opened.")
            }
        } else {
            PaneNote(text: "Artifacts are unavailable — the meeting database couldn't be opened.")
        }
    }

    private func pendingNote(model: MeetingDetailModel) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            SectionHead(title: "artifacts")
            PaneNote(text: "Artifacts weren't generated for this meeting yet. The transcript is complete and safe.")
            generateButton(model: model, title: "generate output")
        }
    }

    private func generateButton(model: MeetingDetailModel, title: String) -> some View {
        Button(title) {
            Task { await model.generate() }
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityHint("Drafts a summary, decisions, and action items from the transcript")
    }
}

/// Generated content remains editable and reviewable. Completion is a
/// separate local task state; review never dispatches an external action.
private struct ReviewSections: View {
    let model: MeetingDetailModel
    @State private var editing: ArtifactRecord?
    @State private var actionReview: ActionReviewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            Text("review the draft")
                .font(UIType.heading)
                .foregroundStyle(DesignTokens.text)
            FormNote("corrections stay on this mac. reviewing an item does not complete a task or create a Calendar entry.")
            if let error = model.operationError {
                Text(error).font(UIType.small).foregroundStyle(DesignTokens.statusRejected)
            } else if let notice = model.operationNotice {
                Text(notice).font(UIType.small).foregroundStyle(DesignTokens.statusApproved)
            }
            if !model.summaries.isEmpty {
                artifactSection("summary", rows: model.summaries)
            }
            if !model.decisions.isEmpty {
                artifactSection("decisions · \(model.decisions.count)", rows: model.decisions)
            }
            if !model.actionItems.isEmpty {
                artifactSection("action items · \(model.actionItems.count)", rows: model.actionItems)
            }
        }
        .sheet(item: $editing) { artifact in
            ArtifactEditorSheet(model: model, artifact: artifact)
        }
        .sheet(item: $actionReview) { review in ActionReviewSheet(model: review) }
    }

    private func artifactSection(_ title: String, rows: [ArtifactRecord]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            SectionHead(title: title)
            ForEach(rows) { artifact in
                ArtifactCard {
                    Text(ArtifactPresentation.text(artifact))
                        .font(UIType.reading)
                        .lineSpacing(4)
                        .foregroundStyle(DesignTokens.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if artifact.artifactKind == .actionItem {
                        Text(ArtifactPresentation.metaLine(artifact.payload(as: ActionItemPayload.self)))
                            .font(UIType.small)
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                    if artifact.isUserEdited {
                        Text("edited locally")
                            .font(UIType.small)
                            .tracking(DesignTokens.tracking)
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                    HStack(spacing: DesignTokens.Space.s3) {
                        Button("edit") {
                            model.clearOperationFeedback()
                            editing = artifact
                        }
                        Button("copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ArtifactPresentation.copyText(artifact), forType: .string)
                            model.didCopyExport()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(UIType.small)
                    .textCase(nil)
                    .foregroundStyle(DesignTokens.accent)
                    ReviewActions(model: model, artifact: artifact)
                    if artifact.artifactKind == .actionItem, artifact.artifactStatus != .rejected,
                       let makeActionReview = model.makeActionReview {
                        HStack {
                            Button("Calendar…") { actionReview = makeActionReview(artifact, .calendarEvent) }
                            Button("reminder…") { actionReview = makeActionReview(artifact, .reminder) }
                        }
                        .buttonStyle(SubtleButtonStyle())
                        .accessibilityHint("Review one new item before allowing macapy to create it")
                    }
                }
            }
        }
    }
}

/// Pure content projection shared by displayed text, the editor and copy.
/// Missing owner/deadline values remain explicitly unstated.
enum ArtifactPresentation {
    static func text(_ artifact: ArtifactRecord) -> String {
        switch artifact.artifactKind {
        case .summary: artifact.payload(as: SummaryPayload.self)?.text ?? ""
        case .decision: artifact.payload(as: DecisionPayload.self)?.text ?? ""
        case .actionItem: artifact.payload(as: ActionItemPayload.self)?.title ?? ""
        case nil: "This output is not supported by this version of macapy."
        }
    }

    static func metaLine(_ payload: ActionItemPayload?) -> String {
        let owner = payload?.owner.map { "Owner · \($0)" } ?? "No owner stated"
        let deadline = payload?.deadline.map { "Due · \($0)" } ?? "No deadline stated"
        return "\(owner) · \(deadline)"
    }

    static func copyText(_ artifact: ArtifactRecord) -> String {
        guard artifact.artifactKind == .actionItem else { return text(artifact) }
        return "\(text(artifact))\n\(metaLine(artifact.payload(as: ActionItemPayload.self)))\nStatus · \(artifact.isComplete ? "Complete" : "Open")"
    }

    static func edit(_ kind: ArtifactKind?, text: String, owner: String, deadline: String) -> ArtifactEdit? {
        switch kind {
        case .summary: .summary(text)
        case .decision: .decision(text)
        case .actionItem: .actionItem(title: text, owner: optional(owner), deadline: optional(deadline))
        case nil: nil
        }
    }

    private static func optional(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct ReviewActions: View {
    let model: MeetingDetailModel
    let artifact: ArtifactRecord

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack(spacing: DesignTokens.Space.s2) {
                switch artifact.artifactStatus {
                case .approved: Chip(text: "reviewed", style: .approved)
                case .rejected: Chip(text: "rejected", style: .rejected)
                default: Chip(text: "draft", style: .quiet)
                }
                Spacer(minLength: 0)
                if artifact.artifactStatus != .approved {
                    Button("review") { Task { await model.approve(artifact.id) } }
                        .accessibilityLabel("Mark this item reviewed")
                }
                if artifact.artifactStatus != .rejected {
                    Button("reject") { Task { await model.reject(artifact.id) } }
                        .accessibilityLabel("Reject this draft")
                }
            }
            .buttonStyle(.plain)
            .font(UIType.small)
            .foregroundStyle(DesignTokens.accent)
            if artifact.artifactKind == .actionItem {
                Button {
                    Task { await model.setCompletion(!artifact.isComplete, id: artifact.id) }
                } label: {
                    Label(artifact.isComplete ? "completed · reopen" : "mark complete",
                          systemImage: artifact.isComplete ? "checkmark.square" : "square")
                }
                .buttonStyle(.plain)
                .font(UIType.small)
                .foregroundStyle(artifact.isComplete ? DesignTokens.statusApproved : DesignTokens.textSecondary)
                .accessibilityLabel(artifact.isComplete ? "Reopen action item" : "Mark action item complete")
            }
        }
        .padding(.top, DesignTokens.Space.s1)
    }
}

private struct ArtifactEditorSheet: View {
    let model: MeetingDetailModel
    /// Snapshot revision is retained even if a background refresh changes rows.
    let artifact: ArtifactRecord
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var owner: String
    @State private var deadline: String
    @State private var isSaving = false

    init(model: MeetingDetailModel, artifact: ArtifactRecord) {
        self.model = model
        self.artifact = artifact
        _text = State(initialValue: ArtifactPresentation.text(artifact))
        _owner = State(initialValue: artifact.payload(as: ActionItemPayload.self)?.owner ?? "")
        _deadline = State(initialValue: artifact.payload(as: ActionItemPayload.self)?.deadline ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Text("correct this draft")
                .font(UIType.heading)
            FormNote("saving returns the item to draft so you can review the corrected version. task completion stays separate.")
            TextEditor(text: $text)
                .font(UIType.reading)
                .scrollContentBackground(.hidden)
                .padding(DesignTokens.Space.s2)
                .frame(height: 150)
                .background(DesignTokens.sunken)
                .overlay(Rectangle().stroke(DesignTokens.hairlineStrong))
                .accessibilityLabel(artifact.artifactKind == .actionItem ? "Action title" : "Draft text")
            if artifact.artifactKind == .actionItem {
                editorField("owner (optional)", text: $owner)
                editorField("deadline as stated (optional)", text: $deadline)
                FormNote("leave a field empty when the meeting did not state it. a deadline is saved as text; it does not schedule anything.")
            }
            if let error = model.operationError {
                Text(error).font(UIType.small).foregroundStyle(DesignTokens.statusRejected)
            }
            HStack {
                Button("cancel") { dismiss() }
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Spacer()
                Button(isSaving ? "saving…" : "save correction") {
                    guard let content = ArtifactPresentation.edit(artifact.artifactKind, text: text, owner: owner, deadline: deadline) else { return }
                    isSaving = true
                    Task {
                        let saved = await model.edit(artifact.id, expectedRevision: artifact.revision, content: content)
                        isSaving = false
                        if saved { dismiss() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 500)
        .background(DesignTokens.bg)
        .interactiveDismissDisabled(isSaving)
    }

    private func editorField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            Text(label).font(UIType.small).foregroundStyle(DesignTokens.textSecondary)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .padding(DesignTokens.Space.s2)
                .background(DesignTokens.sunken)
                .overlay(Rectangle().stroke(DesignTokens.hairlineStrong))
        }
    }
}

private struct MeetingExportSheet: View {
    let model: MeetingDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: MeetingExportSelection = .all
    @State private var format: MeetingExportFormat = .markdown
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Text("take the useful parts with you")
                .font(UIType.heading)
            FormNote("choose exactly what to copy or save. exports contain text and review status, never audio, credentials, or diagnostics.")
            Picker("content", selection: $selection) {
                Text("entire meeting").tag(MeetingExportSelection.all)
                Text("transcript only").tag(MeetingExportSelection.transcript)
                Text("summary only").tag(MeetingExportSelection.summary)
                Text("action items only").tag(MeetingExportSelection.actionItems)
            }
            Picker("format", selection: $format) {
                Text("Markdown (.md)").tag(MeetingExportFormat.markdown)
                Text("plain text (.txt)").tag(MeetingExportFormat.text)
                Text("structured JSON (.json)").tag(MeetingExportFormat.json)
            }
            if let error = model.operationError {
                Text(error).font(UIType.small).foregroundStyle(DesignTokens.statusRejected)
            } else if let notice = model.operationNotice {
                Text(notice).font(UIType.small).foregroundStyle(DesignTokens.statusApproved)
            }
            HStack {
                Button("done") { dismiss() }
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("copy") { prepare(save: false) }
                    .buttonStyle(SubtleButtonStyle())
                Button(isWorking ? "preparing…" : "save file…") { prepare(save: true) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .disabled(isWorking)
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 500)
        .background(DesignTokens.bg)
        .interactiveDismissDisabled(isWorking)
        .onAppear { model.clearOperationFeedback() }
    }

    private func prepare(save: Bool) {
        guard !isWorking else { return }
        isWorking = true
        let requestedFormat = format
        let requestedSelection = selection
        Task {
            defer { isWorking = false }
            guard let data = await model.exportData(format: requestedFormat, selection: requestedSelection) else { return }
            if save {
                let panel = NSSavePanel()
                panel.title = "Export meeting"
                panel.nameFieldStringValue = "macapy-\(model.meeting.id.uuidString.lowercased()).\(requestedFormat.fileExtension)"
                panel.allowedContentTypes = [UTType(filenameExtension: requestedFormat.fileExtension) ?? .plainText]
                panel.canCreateDirectories = true
                guard await panel.begin() == .OK, let destination = panel.url else { return }
                model.saveExport(data, to: destination)
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
                model.didCopyExport()
            }
        }
    }
}

// MARK: - Pane furniture

// SectionHead moved to Design/SearchComponents.swift in slice 5 — the search
// results' group headers share it.

/// Open output row; hairlines separate drafts without nesting cards.
private struct ArtifactCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            content
        }
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.hairlineStrong).frame(height: 1)
        }
    }
}

/// Quiet inline notice for unavailable or pending output.
private struct PaneNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(UIType.small)
            .foregroundStyle(DesignTokens.textSecondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.sunken)
    }
}
