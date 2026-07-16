import SwiftUI

/// Functional-minimal panel content (milestone non-goal: no visual design
/// investment until the dedicated frontend design session). The live
/// transcript replaces this in slice 2.
struct PanelView: View {
    @Environment(SessionController.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("macapy")
                .font(.headline)

            switch session.state {
            case .idle:
                Text("Idle")
                    .foregroundStyle(.secondary)
            case .capturing(let startedAt):
                Label("Capturing", systemImage: "waveform")
                Text("Started \(startedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("⌥⌘M to stop")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(width: 320, height: 160, alignment: .topLeading)
    }
}
