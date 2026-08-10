import AgentKit
import CaptureKit
import SwiftUI
import TranscribeKit

/// The floating panel, reskinned to the approved "Quiet instrument" system
/// (slice-01): signal strip on the top edge, mono state header with meeting
/// timer, bottom-anchored caption-style transcript with attribution gutters.
/// Volatile lines carry slate + dotted baseline and settle to ink.
struct PanelView: View {
    @Environment(SessionController.self) private var session
    @Environment(TranscriptStore.self) private var store
    @Environment(LiveCopilotModel.self) private var copilot
    @FocusState private var copilotCardFocused: Bool

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
            transcript
            copilotSurface
            if session.isPaused {
                pausedNote
            }
            footer
        }
        .frame(width: 340, height: 470)
        .background(DesignTokens.surface)
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
                .foregroundStyle(DesignTokens.text)
                .disabled(copilot.availability == .disabled || copilot.availability == .setupRequired)
                .accessibilityLabel("Ask about this meeting")
                .accessibilityHint("Keyboard shortcut Option Command K")
            Spacer()
            Text("⌥⌘M · ⌥⌘P")
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
                    Text(cardTitle(card.action))
                        .font(MachineType.label())
                        .textCase(.uppercase)
                        .tracking(0.7)
                        .foregroundStyle(DesignTokens.textSecondary)
                    Spacer()
                    Button("Dismiss") { copilot.dismissCard() }
                        .buttonStyle(.plain)
                        .font(UIType.small)
                        .accessibilityLabel("Dismiss copilot card")
                }
                Text(card.text.isEmpty && card.isStreaming ? "Thinking…" : card.text)
                    .font(UIType.body)
                    .foregroundStyle(DesignTokens.text)
                    .textSelection(.enabled)
            }
            .padding(DesignTokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.raised)
            .overlay(alignment: .top) { Divider().overlay(DesignTokens.hairline) }
            .focusable()
            .focused($copilotCardFocused)
            .onHover { copilot.setCardInteractionActive($0) }
            .onChange(of: copilotCardFocused) { _, focused in
                copilot.setCardInteractionActive(focused)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Copilot \(cardTitle(card.action))")
        } else if copilot.askPlaceholderVisible {
            HStack {
                Text("Ask is ready for the meeting-grounded query field in the next slice.")
                    .font(UIType.small)
                    .foregroundStyle(DesignTokens.textSecondary)
                Spacer()
                Button("Dismiss") { copilot.dismissCard() }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss Ask placeholder")
            }
            .padding(DesignTokens.Space.s3)
            .overlay(alignment: .top) { Divider().overlay(DesignTokens.hairline) }
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

    private var availabilityMessage: String? {
        switch copilot.availability {
        case .disabled: "AI features are off. Capture is unaffected."
        case .setupRequired: "Add your DeepSeek key in Settings to use the copilot."
        case .paused(let message): message
        case .idle, .ready, .working: nil
        }
    }

    private func cardTitle(_ action: CopilotAction) -> String {
        switch action {
        case .suggestAnswer: "Suggested answer"
        case .flagCommitment: "Commitment"
        case .catchUp: "Catch up"
        }
    }

    private static let bottomAnchor = "transcript-bottom"

    /// Deterministic order so `ForEach` identity is stable.
    private var volatileLines: [TranscriptStore.VolatileLine] {
        store.volatile
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map(\.value)
    }
}
