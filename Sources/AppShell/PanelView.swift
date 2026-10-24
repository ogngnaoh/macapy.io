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
        static let maximumCopilotSurfaceHeight: CGFloat = 164
        static let maximumAnswerViewportHeight: CGFloat = 96
        static let copilotCardHeight = maximumCopilotSurfaceHeight - 2 * DesignTokens.Space.s1
        static let maximumRollingSummaryLines = 3
    }

    enum LayoutRegion: Hashable { case transcript, copilot, answerViewport, answerContent, query, footer }

    /// Optional native-layout observation for offscreen regression checks.
    /// Production leaves this nil, so probes do not install geometry readers.
    var onLayout: ((LayoutRegion, CGRect) -> Void)? = nil

    /// Presentation values supplied by the shortcut preferences owner. Omitted
    /// actions keep their default labels, including the isolated sample.
    var shortcutLabels: [ShortcutAction: String] = [:]

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

    /// NSHostingView is outside the scene environment. The persistent menu
    /// bar label routes this notification through its scene-owned action.
    var onOpenSetup: () -> Void = {
        NotificationCenter.default.post(name: .macapyOpenSetup, object: nil)
    }
    @Environment(SessionController.self) private var session
    @Environment(TranscriptStore.self) private var store
    @Environment(LiveCopilotModel.self) private var copilot
    @FocusState private var copilotCardFocused: Bool
    @FocusState private var queryFieldFocused: Bool
    @State private var showingStorageDetails = false

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
            if session.isPreparing {
                preparationNotice
            } else if let failure = session.failure {
                failureNotice(failure)
            } else {
                if let warning = session.storageWarning ?? session.diarizationWarning {
                    storageWarningStrip(warning)
                } else {
                    rollingSummaryStrip
                }
                transcript
                copilotSurface
                queryBar
                if session.isPaused { pausedNote }
                footer
            }
        }
        .frame(width: Layout.panelWidth, height: Layout.panelHeight)
        .coordinateSpace(name: Self.layoutCoordinateSpace)
        .background(DesignTokens.surface)
        // The command lives at the panel container so Escape is handled when
        // focus is in either the query field or its Submit button.
        .onExitCommand { Self.handleExitCommand(copilot: copilot) }
        .onChange(of: copilot.askFocusRevision) { _, _ in
            queryFieldFocused = copilot.askFieldVisible
        }
        .popover(item: Binding(get: { copilot.sourcePicker }, set: { copilot.sourcePicker = $0 })) { picker in
            LiveAskSourcesView(model: picker)
        }
        .popover(item: Binding(get: { copilot.groundingPreview }, set: { copilot.groundingPreview = $0 })) { preview in
            LiveGroundingEvidenceView(title: preview.title, text: preview.text)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(session.statusTitle.lowercased())
                .font(MachineType.label())
                .foregroundStyle(session.isPaused ? DesignTokens.textSecondary : DesignTokens.text)
            Spacer()
            if let startedAt = session.startedAt {
                MeetingTimerText(startedAt: startedAt)
            }
        }
        .padding(.horizontal, DesignTokens.Space.s3)
        .padding(.vertical, DesignTokens.Space.s2)
        .overlay(alignment: .bottom) { Divider().overlay(DesignTokens.hairline) }
    }

    private func storageWarningStrip(_ warning: String) -> some View {
        Button { showingStorageDetails = true } label: {
            HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
                Image(systemName: "exclamationmark.triangle")
                    .accessibilityHidden(true)
                Text(warning)
                    .font(UIType.small)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(UIType.small)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(DesignTokens.statusWarning)
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, DesignTokens.Space.s2)
            .background(DesignTokens.statusWarningSurface)
        }
        .buttonStyle(.plain)
        .help(warning)
        .accessibilityLabel(warning)
        .accessibilityHint("Show the complete capture notice. Capture continues.")
        .popover(isPresented: $showingStorageDetails) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                Text("capture notice").font(UIType.bodySemibold)
                Text(warning).font(UIType.compactReading).lineSpacing(3)
            }
            .foregroundStyle(DesignTokens.text)
            .padding(DesignTokens.Space.s4)
            .frame(width: 300)
            .background(DesignTokens.surface)
        }
    }

    private var preparationNotice: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Spacer()
            ProgressView().controlSize(.small)
            Text("preparing your meeting")
                .font(UIType.heading)
                .foregroundStyle(DesignTokens.text)
            Text("checking local speech support and starting audio. capture has not begun yet.")
                .font(UIType.compactReading)
                .foregroundStyle(DesignTokens.textSecondary)
            Text("cancel from the menu bar or with \(shortcutLabel(.startStop)).")
                .font(UIType.small)
                .foregroundStyle(DesignTokens.textSecondary)
            Spacer()
        }
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failureNotice(_ failure: SessionFailure) -> some View {
        let interrupted = [SessionFailure.audioRoute, .captureInterrupted, .systemSleep, .transcription].contains(failure)
        let finishing = failure == .shutdownDelayed
        return VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Spacer()
            Image(systemName: "exclamationmark.square")
                .foregroundStyle(DesignTokens.statusWarning)
                .font(.system(size: 24))
                .accessibilityHidden(true)
            Text(finishing ? "still finishing" : (interrupted ? "recording stopped" : "let’s get you ready"))
                .font(UIType.heading)
                .foregroundStyle(DesignTokens.text)
            Text(failure.message)
                .font(UIType.compactReading)
                .lineSpacing(3)
                .foregroundStyle(DesignTokens.textSecondary)
            if !interrupted && !finishing {
                Button("open setup", action: onOpenSetup)
                    .buttonStyle(PrimaryButtonStyle())
            }
            Spacer()
        }
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.segments) { segment in
                        TranscriptLineView(
                            speaker: store.speakerLabels[segment.id]
                                ?? Self.speakerLabel(for: segment.source).lowercased(),
                            isYou: segment.source == .mic,
                            text: segment.text,
                            isVolatile: false
                        )
                        .id(segment.id)
                    }
                    ForEach(volatileLines, id: \.source) { line in
                        TranscriptLineView(
                            speaker: Self.speakerLabel(for: line.source).lowercased(),
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
        .modifier(LayoutProbe(region: .transcript, observe: onLayout))
    }

    @ViewBuilder
    private var rollingSummaryStrip: some View {
        if let summary = copilot.rollingSummaryText {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Text("so far")
                    .font(MachineType.label())
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
        Text("capture is paused. nothing is being heard.")
            .font(UIType.small)
            .foregroundStyle(DesignTokens.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Space.s2)
            .overlay(alignment: .top) { Divider().overlay(DesignTokens.hairline) }
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Button("catch up") { copilot.requestCatchUp() }
                .buttonStyle(.plain)
                .font(UIType.small)
                .foregroundStyle(copilot.canCatchUp ? DesignTokens.text : DesignTokens.textTertiary)
                .disabled(!copilot.canCatchUp)
                .accessibilityLabel("Catch up on the last 90 seconds")
                .accessibilityHint(shortcutHint(.catchUp))
            Button("ask") { copilot.requestAsk() }
                .buttonStyle(.plain)
                .font(UIType.small)
                .foregroundStyle(copilot.canAsk ? DesignTokens.text : DesignTokens.textTertiary)
                .disabled(!copilot.canAsk)
                .accessibilityLabel("Ask about this meeting")
                .accessibilityHint(shortcutHint(.ask))
            Spacer()
            if copilot.askFieldVisible, copilot.sourceLookupAvailable {
                Button("add sources…") { copilot.openSources() }.buttonStyle(.plain).font(UIType.small)
                    .foregroundStyle(DesignTokens.accent).disabled(!copilot.canOpenSources)
                    .help("Review selected history and documents before sending")
            } else {
                Text(copilot.askFieldVisible ? "meeting only" : "\(shortcutLabel(.startStop)) · \(shortcutLabel(.pauseResume))")
                    .font(UIType.small).foregroundStyle(DesignTokens.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, DesignTokens.Space.s2)
            .overlay(alignment: .top) { Divider().overlay(DesignTokens.hairline) }
            .modifier(LayoutProbe(region: .footer, observe: onLayout))
    }

    @ViewBuilder
    private var copilotSurface: some View {
        if let card = copilot.card {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                HStack {
                    Text(cardTitle(card))
                        .font(MachineType.label())
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(2)
                    Spacer()
                    if !card.evidence.isEmpty {
                        Menu("sources") {
                            ForEach(card.evidence) { evidence in
                                Button(evidence.title) { Task { await copilot.previewGrounding(evidence) } }
                            }
                        }.menuStyle(.borderlessButton).fixedSize().font(UIType.small)
                    }
                    Button("dismiss") { copilot.dismissCard() }
                        .buttonStyle(.plain)
                        .font(UIType.small)
                        .accessibilityLabel("Dismiss copilot card")
                        .accessibilityHint(shortcutHint(.dismiss))
                }
                if card.text.isEmpty && card.isStreaming {
                    Text("thinking…")
                        .font(UIType.body)
                        .foregroundStyle(DesignTokens.textSecondary)
                } else {
                    ScrollView(.vertical) {
                        streamingAnswer(card)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .modifier(LayoutProbe(region: .answerContent, observe: onLayout))
                    }
                    // A max-only ScrollView can accept a zero-height proposal
                    // when the transcript consumes the available VStack space.
                    // Reserve a readable viewport; long answers scroll inside it.
                    .frame(height: Layout.maximumAnswerViewportHeight)
                    .modifier(LayoutProbe(region: .answerViewport, observe: onLayout))
                    .textSelection(.enabled)
                    .accessibilityLabel(card.text)
                }
            }
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, DesignTokens.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Layout.copilotCardHeight, alignment: .top)
            .background(DesignTokens.sunken)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusCard))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.radiusCard)
                    .stroke(DesignTokens.hairlineStrong, lineWidth: 1)
            }
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, DesignTokens.Space.s1)
            .frame(height: Layout.maximumCopilotSurfaceHeight)
            .modifier(LayoutProbe(region: .copilot, observe: onLayout))
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
                    "ask about this meeting",
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
                            queryFieldFocused ? DesignTokens.accent : DesignTokens.hairlineStrong,
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
            .modifier(LayoutProbe(region: .query, observe: onLayout))
        }
    }

    private var availabilityMessage: String? {
        switch copilot.availability {
        case .disabled: "ai features are off. capture continues."
        case .setupRequired: "add your DeepSeek key in settings to use the copilot."
        case .paused(let message): message
        case .idle, .ready, .working: nil
        }
    }

    private func shortcutLabel(_ action: ShortcutAction) -> String {
        shortcutLabels[action] ?? ShortcutBinding(letter: action.defaultLetter).display
    }

    private func shortcutHint(_ action: ShortcutAction) -> String {
        if shortcutLabels[action] == nil {
            return "Keyboard shortcut Option Command \(action.defaultLetter)"
        }
        return "Keyboard shortcut \(shortcutLabel(action))"
    }

    private func cardTitle(_ card: LiveCopilotCard) -> String {
        switch card.kind {
        case .query(let question): "you asked · \(question)"
        case .action(.suggestAnswer): "suggested answer"
        case .action(.flagCommitment): "commitment"
        case .action(.catchUp): "catch up"
        }
    }

    private func streamingAnswer(_ card: LiveCopilotCard) -> some View {
        let fragments = Self.streamingFragments(for: card.text, isStreaming: card.isStreaming)
        let settled = Text(verbatim: fragments.settled)
            .foregroundColor(DesignTokens.text)
        let volatile = Text(verbatim: fragments.volatile)
            .foregroundColor(DesignTokens.textSecondary)
            .underline(pattern: .dot, color: DesignTokens.textTertiary)
        return Text("\(settled)\(volatile)")
            .font(UIType.compactReading)
            .lineSpacing(3)
    }

    private static let bottomAnchor = "transcript-bottom"
    nonisolated private static let layoutCoordinateSpace = "macapy-meeting-panel"

    private struct LayoutProbe: ViewModifier {
        let region: LayoutRegion
        let observe: ((LayoutRegion, CGRect) -> Void)?

        @ViewBuilder func body(content: Content) -> some View {
            if let observe {
                content.onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .named(PanelView.layoutCoordinateSpace))
                } action: { frame in
                    observe(region, frame)
                }
            } else {
                content
            }
        }
    }

    /// Deterministic order so `ForEach` identity is stable.
    private var volatileLines: [TranscriptStore.VolatileLine] {
        store.volatile
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map(\.value)
    }
}
