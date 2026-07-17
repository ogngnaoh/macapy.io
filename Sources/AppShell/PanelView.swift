import SwiftUI
import TranscribeKit

/// Functional-minimal live transcript (milestone non-goal: no visual design
/// investment until the dedicated frontend design session). Finalized segments
/// render solid; the trailing per-source volatile lines render secondary. No
/// You/Them labels yet — that arrives with the second source in slice 3.
struct PanelView: View {
    @Environment(SessionController.self) private var session
    @Environment(TranscriptStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.segments) { segment in
                            Text(segment.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(segment.id)
                        }
                        ForEach(volatileLines, id: \.source) { line in
                            Text(line.text)
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
