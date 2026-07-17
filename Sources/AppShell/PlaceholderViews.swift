import SwiftUI
import TranscribeKit

// HistoryPlaceholderView is gone — HistoryView.swift (slice 4) is the real
// past-meetings list + read-only transcript detail.

struct SettingsPlaceholderView: View {
    let coordinator: AppShellCoordinator

    var body: some View {
        Form {
            Section("Settings") {
                Text("Full settings arrive with the provider layer (M2).")
                    .foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                DiagnosticsSectionView(coordinator: coordinator)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 260)
    }
}

/// Minimal live-session latency diagnostics (slice-05 doc decision 7 — SPEC
/// §8 seed; the full diagnostics panel is M2+). Polls the current meeting's
/// `LatencyRecorder`, if any, on a short timer: `LatencyRecorder` is a plain
/// lock-protected class, not `@Observable`, so polling is the simplest
/// correct way to surface fresh numbers here without adding an
/// observation-bridging layer for one section.
struct DiagnosticsSectionView: View {
    let coordinator: AppShellCoordinator

    @State private var report: LatencyReport?

    var body: some View {
        Group {
            if let report, coordinator.session.isCapturing || coordinator.session.isPaused {
                VStack(alignment: .leading, spacing: 4) {
                    statLine("Volatile", report.volatile)
                    statLine("Final", report.final)
                }
                .font(.system(.callout, design: .monospaced))
            } else {
                Text("No active meeting.")
                    .foregroundStyle(.secondary)
            }
        }
        .task { await pollLoop() }
    }

    private func statLine(_ label: String, _ stats: LatencyReport.Stats) -> some View {
        Text(
            "\(label): \(stats.count) events — p50 \(formatMs(stats.p50Ms))"
                + " / p95 \(formatMs(stats.p95Ms)) / max \(formatMs(stats.maxMs))"
        )
    }

    private func formatMs(_ ms: Double) -> String {
        String(format: "%.0fms", ms)
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            report = coordinator.currentRecorder?.report()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
