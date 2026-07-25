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
            SignalStripView(mode: session.isCapturing ? .live : .quiet)
            header
            transcript
            if session.isPaused {
                pausedNote
            }
            footer
        }
        .frame(width: 340, height: 380)
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
                            speaker: Self.speakerLabel(for: segment.source),
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
        Text("⌥⌘M to stop · ⌥⌘P to \(session.isPaused ? "resume" : "pause")")
            .font(UIType.small)
            .foregroundStyle(DesignTokens.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, DesignTokens.Space.s2)
            .overlay(alignment: .top) { Divider().overlay(DesignTokens.hairline) }
    }

    private static let bottomAnchor = "transcript-bottom"

    /// Deterministic order so `ForEach` identity is stable.
    private var volatileLines: [TranscriptStore.VolatileLine] {
        store.volatile
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map(\.value)
    }
}
