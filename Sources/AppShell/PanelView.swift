import AgentKit
import CaptureKit
import SwiftUI
import TranscribeKit

/// The floating panel, reskinned to the approved "Quiet instrument" system
/// (slice-01): signal strip on the top edge, mono state header with meeting
/// timer, bottom-anchored caption-style transcript with attribution gutters.
/// Volatile lines carry slate + dotted baseline and settle to ink.
struct PanelView: View {
    static let dismissShortcutAccessibilityHint = "Keyboard shortcut Option Command D"

    /// Fixed-panel layout contract. The response body scrolls inside its
    /// bounded moment card, so a maximum-length requested answer remains
    /// reachable without collapsing the live transcript out of the panel.
    enum Layout {
        static let panelWidth: CGFloat = 340
        static let panelHeight: CGFloat = 470
        static let minimumTranscriptHeight: CGFloat = 96
        static let maximumCopilotSurfaceHeight: CGFloat = 174
        static let maximumAnswerViewportHeight: CGFloat = 112
        static let maximumRollingSummaryLines = 3
    }

    struct StreamingFragments: Equatable {
        let settled: String
        let volatile: String
    }

    /// Keep only the unfinished tail volatile while tokens are arriving. Once
    /// the provider reports `stop`, the same text settles to ordinary ink.
    static func streamingFragments(
        for text: String,
        isStreaming: Bool,
        volatileCharacterLimit: Int = 48
    ) -> StreamingFragments {
        guard isStreaming, !text.isEmpty, volatileCharacterLimit > 0 else {
            return StreamingFragments(settled: text, volatile: "")
        }
        let count = min(text.count, volatileCharacterLimit)
        let split = text.index(text.endIndex, offsetBy: -count)
        return StreamingFragments(
            settled: String(text[..<split]),
            volatile: String(text[split...])
        )
    }

    static func rollingSummaryAccessibilityLabel(_ summary: String) -> String {
        "So far in this meeting: \(summary)"
    }

    @MainActor
    static func handleExitCommand(copilot: LiveCopilotModel) {
        copilot.dismissCard()
    }

    @Environment(SessionController.self) private var session
    @Environment(TranscriptStore.self) private var store
    @Environment(LiveCopilotModel.self) private var copilot
    @FocusState private var copilotCardFocused: Bool
    @FocusState private var queryFieldFocused: Bool

    /// Panel speaker label: mic is the user ("You"); system-audio is the
    /// meeting's other participants ("Them").
    static func speakerLabel(for source: AudioSource) -> String {
        switch source {
        case .mic: return "You"
        case .system: return "Them"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SignalStripView(mode: session.isCapturing ? .live : .quiet, meter: session.signalMeter)
            header
            rollingSummaryStrip
            transcript
            copilotSurface
            queryBar
            if session.isPaused {
                pausedNote
            }
            footer
        }
        .frame(width: Layout.panelWidth, height: Layout.panelHeight)
        .background(DesignTokens.surface)
        // The command lives at the panel container so Escape is handled when
        // focus is in either the query field or its Submit button.
        .onExitCommand { Self.handleExitCommand(copilot: copilot) }
        .onChange(of: copilot.askFocusRevision) { _, _ in
            queryFieldFocused = copilot.askFieldVisible
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(session.isPaused ? "Paused" : "Capturing")
                .font(MachineType.label())
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(session.isPaused ? DesignTokens.textSecondary : DesignTokens.live)
            Spacer()
            if let startedAt = session.startedAt {
                MeetingTimerText(startedAt: startedAt)
            }
        }
        .padding(.horizontal, DesignTokens.Space.s3)
        .padding(.vertical, DesignTokens.Space.s2)
        .overlay(alignment: .bottom) { Divider().overlay(DesignTokens.hairline) }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.segments) { segment in
                        TranscriptLineView(
                            speaker: store.speakerLabels[segment.id]
                                ?? Self.speakerLabel(for: segment.source),
                            isYou: segment.source == .mic,
                            text: segment.text,
                            isVolatile: false
                        )
                        .id(segment.id)
                    }
                    ForEach(volatileLines, id: \.source) { line in
                        TranscriptLineView(
                            speaker: Self.speakerLabel(for: line.source),
                            isYou: line.source == .mic,
                            text: line.text,
                            isVolatile: true
                        )
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, DesignTokens.Space.s2)
            }
            .onChange(of: store.segments.count) { _, _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: volatileLines.map(\.text)) { _, _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        .frame(minHeight: Layout.minimumTranscriptHeight)
        .layoutPriority(1)
    }

    @ViewBuilder
    private var rollingSummaryStrip: some View {
        if let summary = copilot.rollingSummaryText {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Text("So far")
                    .font(MachineType.label())
                    .textCase(.uppercase)
                    .tracking(0.7)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text(summary)
                    .font(UIType.small)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(Layout.maximumRollingSummaryLines)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, DesignTokens.Space.s1)
            .overlay(alignment: .bottom) { Divider().overlay(DesignTokens.hairline) }
            // Ignore child labels and announce the visible strip exactly once.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.rollingSummaryAccessibilityLabel(summary))
        }
    }

    private var pausedNote: some View {
        Text("Capture is stopped. Nothing is being heard.")
            .font(UIType.small)
            .foregroundStyle(DesignTokens.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Space.s2)
            .overlay(alignment: .top) { Divider().overlay(DesignTokens.hairline) }
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Button("Catch up") { copilot.requestCatchUp() }
                .buttonStyle(.plain)
                .font(UIType.small)
                .foregroundStyle(copilot.canCatchUp ? DesignTokens.text : DesignTokens.textTertiary)
                .disabled(!copilot.canCatchUp)
                .accessibilityLabel("Catch up on the last 90 seconds")
                .accessibilityHint("Keyboard shortcut Option Command C")
            Button("Ask") { copilot.requestAsk() }
                .buttonStyle(.plain)
                .font(UIType.small)
                .foregroundStyle(copilot.canAsk ? DesignTokens.text : DesignTokens.textTertiary)
                .disabled(!copilot.canAsk)
                .accessibilityLabel("Ask about this meeting")
                .accessibilityHint("Keyboard shortcut Option Command K")
            Spacer()
            Text(copilot.askFieldVisible ? "Meeting only" : "⌥⌘M · ⌥⌘P")
                .font(UIType.small)
                .foregroundStyle(DesignTokens.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, DesignTokens.Space.s2)
            .overlay(alignment: .top) { Divider().overlay(DesignTokens.hairline) }
    }

    @ViewBuilder
    private var copilotSurface: some View {
        if let card = copilot.card {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                HStack {
                    Text(cardTitle(card))
                        .font(MachineType.label())
                        .tracking(0.7)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") { copilot.dismissCard() }
                        .buttonStyle(.plain)
                        .font(UIType.small)
                        .accessibilityLabel("Dismiss copilot card")
                        .accessibilityHint(Self.dismissShortcutAccessibilityHint)
                }
                if card.text.isEmpty && card.isStreaming {
                    Text("Thinking…")
                        .font(UIType.body)
                        .foregroundStyle(DesignTokens.textSecondary)
                } else {
                    ScrollView(.vertical) {
                        streamingAnswer(card)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: Layout.maximumAnswerViewportHeight)
                    .textSelection(.enabled)
                    .accessibilityLabel(card.text)
                }
            }
            .padding(DesignTokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.raised)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusCard))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.radiusCard)
                    .stroke(DesignTokens.hairlineStrong, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.10), radius: 7, y: 4)
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, DesignTokens.Space.s2)
            .frame(maxHeight: Layout.maximumCopilotSurfaceHeight)
            .focusable()
            .focused($copilotCardFocused)
            .onHover { copilot.setCardHovered($0) }
            .onChange(of: copilotCardFocused) { _, focused in
                copilot.setCardFocused(focused)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Copilot \(cardTitle(card))")
        } else if let message = availabilityMessage {
            Text(message)
                .font(UIType.small)
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Space.s3)
                .padding(.vertical, DesignTokens.Space.s2)
                .overlay(alignment: .top) { Divider().overlay(DesignTokens.hairline) }
                .accessibilityLabel(message)
        }
    }

    @ViewBuilder
    private var queryBar: some View {
        if copilot.askFieldVisible {
            HStack(spacing: DesignTokens.Space.s2) {
                TextField(
                    "Ask about this meeting",
                    text: Binding(
                        get: { copilot.queryText },
                        set: { copilot.queryText = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .font(UIType.body)
                .padding(.horizontal, DesignTokens.Space.s2)
                .padding(.vertical, 5)
                .background(DesignTokens.sunken)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusControl))
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.radiusControl)
                        .stroke(
                            queryFieldFocused ? DesignTokens.signal : DesignTokens.hairline,
                            lineWidth: queryFieldFocused ? 2 : 1
                        )
                }
                .focused($queryFieldFocused)
                .onSubmit { Task { await copilot.submitAsk() } }
                .accessibilityLabel("Ask about this meeting")
                .accessibilityHint(
                    "Type a question grounded only in this meeting, then press Return"
                )
                Button("⏎") { Task { await copilot.submitAsk() } }
                    .buttonStyle(.plain)
                    .font(UIType.small)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .disabled(!copilot.canSubmitAsk)
                    .accessibilityLabel("Submit meeting question")
                    .accessibilityHint("Returns one answer using only this meeting")
            }
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, DesignTokens.Space.s2)
            .overlay(alignment: .top) { Divider().overlay(DesignTokens.hairline) }
            .accessibilityElement(children: .contain)
        }
    }

    private var availabilityMessage: String? {
        switch copilot.availability {
        case .disabled: "AI features are off. Capture is unaffected."
        case .setupRequired: "Add your DeepSeek key in Settings to use the copilot."
        case .paused(let message): message
        case .idle, .ready, .working: nil
        }
    }

    private func cardTitle(_ card: LiveCopilotCard) -> String {
        switch card.kind {
        case .query(let question): "You asked · \(question)"
        case .action(.suggestAnswer): "Suggested answer"
        case .action(.flagCommitment): "Commitment"
        case .action(.catchUp): "Catch up"
        }
    }

    private func streamingAnswer(_ card: LiveCopilotCard) -> Text {
        let fragments = Self.streamingFragments(for: card.text, isStreaming: card.isStreaming)
        let settled = Text(verbatim: fragments.settled)
            .foregroundColor(DesignTokens.text)
        let volatile = Text(verbatim: fragments.volatile)
            .foregroundColor(DesignTokens.textSecondary)
            .underline(pattern: .dot, color: DesignTokens.textTertiary)
        return Text("\(settled)\(volatile)")
            .font(UIType.body)
    }

    private static let bottomAnchor = "transcript-bottom"

    /// Deterministic order so `ForEach` identity is stable.
    private var volatileLines: [TranscriptStore.VolatileLine] {
        store.volatile
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map(\.value)
    }
}
