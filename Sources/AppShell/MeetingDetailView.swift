import PersistKit
import SwiftUI
import TranscribeKit

/// Meeting detail (design/05-meeting-detail.html): transcript replay on the
/// left, artifacts pane on the right — drafts under review, or the pending /
/// setup / cap-halt states when there are no rows yet.
struct MeetingDetailView: View {
    let store: MeetingStore
    let meeting: MeetingRecord
    /// `nil` model ⇒ the pane shows its unavailable state (previews, or a
    /// database that failed to open).
    let makeModel: @MainActor (MeetingRecord) -> MeetingDetailModel?

    @State private var segments: [AttributedSegment] = []
    @State private var transcriptError: String?
    @State private var model: MeetingDetailModel?

    var body: some View {
        HStack(spacing: 0) {
            transcriptPane
                .frame(maxWidth: .infinity)
            Divider().overlay(DesignTokens.hairline)
            ArtifactsPane(model: model)
                .frame(minWidth: 260, idealWidth: 330, maxWidth: 400)
        }
        .navigationTitle(meeting.title)
        .task(id: meeting.id) {
            await loadTranscript()
            let built = makeModel(meeting)
            model = built
            await built?.load()
        }
    }

    private var transcriptPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(segments, id: \.segment.id) { attributed in
                    TranscriptLineView(
                        speaker: attributed.speakerLabel
                            ?? PanelView.speakerLabel(for: attributed.segment.source),
                        isYou: attributed.segment.source == .mic,
                        text: attributed.segment.text,
                        isVolatile: false
                    )
                }
            }
            .padding(.vertical, DesignTokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if segments.isEmpty {
                if let transcriptError {
                    EmptyStateView(title: "Couldn't load transcript", message: transcriptError)
                } else {
                    EmptyStateView(title: "No transcript", message: "This meeting has no captured lines.")
                }
            }
        }
    }

    private func loadTranscript() async {
        do {
            segments = try await store.attributedSegments(for: meeting.id)
        } catch {
            transcriptError = error.localizedDescription
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
                EmptyView()
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
                    format: "AI stopped at this meeting's $%.2f cap ($%.2f spent). The transcript is complete and safe.",
                    capUSD, spentUSD))
            case .generating:
                HStack(spacing: DesignTokens.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text("Drafting artifacts…")
                        .font(UIType.small)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                .accessibilityElement(children: .combine)
            case .failed(let message):
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    PaneNote(text: message)
                    generateButton(model: model, title: "Try again")
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
            SectionHead(title: "Artifacts")
            PaneNote(text: "Artifacts weren't generated for this meeting yet. The transcript is complete and safe.")
            generateButton(model: model, title: "Generate artifacts")
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

/// The pane's review body: Summary / Decisions / Action items, to the mockup's
/// section anatomy.
private struct ReviewSections: View {
    let model: MeetingDetailModel

    var body: some View {
        if !model.summaries.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                SectionHead(
                    title: "Summary",
                    chip: model.summaries.first.map { chip(for: $0) },
                    draftedIn: model.lastDraftedInSeconds
                )
                ForEach(model.summaries) { summary in
                    ArtifactCard {
                        Text(summary.payload(as: SummaryPayload.self)?.text ?? "")
                            .font(UIType.body)
                            .lineSpacing(3)
                            .foregroundStyle(DesignTokens.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if !model.decisions.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                SectionHead(title: "Decisions · \(model.decisions.count)")
                ForEach(model.decisions) { decision in
                    ArtifactCard {
                        Text(decision.payload(as: DecisionPayload.self)?.text ?? "")
                            .font(UIType.body)
                            .lineSpacing(3)
                            .foregroundStyle(DesignTokens.text)
                            .fixedSize(horizontal: false, vertical: true)
                        ReviewActions(model: model, artifact: decision, kindLabel: "decision")
                    }
                }
            }
        }
        if !model.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                SectionHead(title: "Action items · \(model.actionItems.count)")
                ForEach(model.actionItems) { item in
                    let payload = item.payload(as: ActionItemPayload.self)
                    ArtifactCard {
                        Text(payload?.title ?? "")
                            .font(UIType.body)
                            .lineSpacing(3)
                            .foregroundStyle(DesignTokens.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.metaLine(for: payload))
                            .font(MachineType.label())
                            .foregroundStyle(DesignTokens.textTertiary)
                        ReviewActions(model: model, artifact: item, kindLabel: "action item")
                    }
                }
            }
        }
    }

    private func chip(for artifact: ArtifactRecord) -> Chip {
        switch artifact.artifactStatus {
        case .approved: Chip(text: "Approved", style: .approved)
        case .rejected: Chip(text: "Rejected", style: .rejected)
        default: Chip(text: "Draft", style: .quiet)
        }
    }

    /// "Owner · You — due Thursday" / "No owner stated — no deadline stated",
    /// the mockup's meta line, from whatever the meeting actually stated.
    static func metaLine(for payload: ActionItemPayload?) -> String {
        let owner = payload?.owner.map { "Owner · \($0)" } ?? "No owner stated"
        let deadline = payload?.deadline.map { "due \($0)" } ?? "no deadline stated"
        return "\(owner) — \(deadline)"
    }
}

/// Per-item Approve/Reject while drafted; the settled chip afterwards
/// (FR-009: the flip is the whole effect in M2).
private struct ReviewActions: View {
    let model: MeetingDetailModel
    let artifact: ArtifactRecord
    let kindLabel: String

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            switch artifact.artifactStatus {
            case .approved:
                Chip(text: "Approved", style: .approved)
            case .rejected:
                Chip(text: "Rejected", style: .rejected)
            default:
                Button("Approve") {
                    Task { await model.approve(artifact.id) }
                }
                .controlSize(.small)
                .accessibilityLabel("Approve \(kindLabel)")
                Button("Reject") {
                    Task { await model.reject(artifact.id) }
                }
                .controlSize(.small)
                .accessibilityLabel("Reject \(kindLabel)")
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Pane furniture

/// `.art-head` — mono section label, optional status chip, optional G3
/// readout pushed to the trailing edge.
private struct SectionHead: View {
    let title: String
    var chip: Chip?
    var draftedIn: Double?

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Text(title)
                .font(MachineType.label())
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(DesignTokens.textSecondary)
            if let chip { chip }
            if let draftedIn {
                Spacer(minLength: DesignTokens.Space.s2)
                Text("drafted in \(Int(draftedIn.rounded()))s")
                    .font(MachineType.label())
                    .foregroundStyle(DesignTokens.textTertiary)
                    .accessibilityLabel("Drafted in \(Int(draftedIn.rounded())) seconds")
            }
        }
    }
}

/// `.art-item` — one raised card.
private struct ArtifactCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            content
        }
        .padding(.horizontal, DesignTokens.Space.s3)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.raised)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radiusCard)
                .stroke(DesignTokens.hairline)
        )
    }
}

/// `.pending-note` — the dashed quiet notice.
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
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.radiusCard)
                    .stroke(DesignTokens.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }
}

/// `.btn.primary` — the amber button; meeting detail's "Generate artifacts"
/// is the first surface that needs one in SwiftUI.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(UIType.bodySemibold)
            .foregroundStyle(DesignTokens.textOnSignal)
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, 5)
            .background(DesignTokens.signal.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusControl))
    }
}
