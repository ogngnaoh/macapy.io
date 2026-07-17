import CaptureKit
import SwiftUI
import TranscribeKit

/// Functional-minimal live transcript (milestone non-goal: no visual design
/// investment until the dedicated frontend design session). Finalized segments
/// render solid; the trailing per-source volatile lines render italic-secondary.
/// Each line is prefixed with a bold You/Them speaker label derived from its
/// source (slice 3).
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
        VStack(alignment: .leading, spacing: 8) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.segments) { segment in
                            labeledLine(source: segment.source, text: segment.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(segment.id)
                        }
                        ForEach(volatileLines, id: \.source) { line in
                            // Italic + secondary: color alone is too subtle against
                            // the panel background to read as "not yet final".
                            labeledLine(source: line.source, text: line.text)
                                .italic()
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.callout)
                }
                .onChange(of: store.segments.count) { _, _ in
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
                .onChange(of: volatileLines.map(\.text)) { _, _ in
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }

            Text("⌥⌘M to stop")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(width: 320, height: 160, alignment: .topLeading)
    }

    /// A transcript line: a bold You/Them prefix + the text, as one inline
    /// `Text`. Volatile styling (italic/secondary) is applied by the caller on
    /// the whole composed line.
    private func labeledLine(source: AudioSource, text: String) -> Text {
        var label = AttributedString("\(Self.speakerLabel(for: source)) ")
        label.inlinePresentationIntent = .stronglyEmphasized
        return Text(label + AttributedString(text))
    }

    private static let bottomAnchor = "transcript-bottom"

    /// Deterministic order so `ForEach` identity is stable.
    private var volatileLines: [TranscriptStore.VolatileLine] {
        store.volatile
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map(\.value)
    }

    @ViewBuilder
    private var header: some View {
        switch session.state {
        case .idle:
            Text("Idle")
                .font(.headline)
                .foregroundStyle(.secondary)
        case .capturing:
            Label("Capturing", systemImage: "waveform")
                .font(.headline)
        }
    }
}
