import SwiftUI
import TranscribeKit

// HistoryPlaceholderView is gone — HistoryView.swift (slice 4) is the real
// past-meetings list + read-only transcript detail.

struct SettingsPlaceholderView: View {
    let coordinator: AppShellCoordinator

    var body: some View {
        // Native grouped Form on purpose — Settings keeps system window
        // furniture (slice-01 Notes); the M2 provider slice builds the real
        // tabbed screens to the approved design.
        Form {
            Section("Settings") {
                Text("Providers, spend, and diagnostics arrive with M2's provider layer.")
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            Section("Diagnostics") {
                DiagnosticsSectionView(coordinator: coordinator)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 260)
    }
}

/// The diagnostics stat-grid to design/06 (slice 4): latency percentiles from
/// the recorder, memory footprint, and the fan-out drop counter, with reserved
/// tiles for Artifacts G3 and STT errors (their wiring is M3 debt). Polls on a
/// short timer: the sources are plain lock-protected classes, not
/// `@Observable`, so polling is the simplest correct way to surface fresh
/// numbers without an observation-bridging layer.
struct DiagnosticsSectionView: View {
    let coordinator: AppShellCoordinator

    @State private var report: LatencyReport?
    @State private var memoryBytes: UInt64?
    @State private var droppedChunks: Int?

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10, alignment: .topLeading), count: 3)

    var body: some View {
        Group {
            if let report, coordinator.session.isCapturing || coordinator.session.isPaused {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    LazyVGrid(columns: Self.columns, spacing: 10) {
                        StatTile(
                            label: "Speech → visible p50",
                            value: DiagnosticsFormat.ms(report.volatile.p50Ms), unit: "ms")
                        StatTile(
                            label: "Speech → visible p95",
                            value: DiagnosticsFormat.ms(report.volatile.p95Ms), unit: "ms")
                        StatTile(
                            label: "Memory",
                            value: memoryBytes.map(DiagnosticsFormat.mb) ?? DiagnosticsFormat.reserved,
                            unit: memoryBytes != nil ? "MB" : nil)
                        // Reserved: wired when M3 lands its diagnostics debts.
                        StatTile(label: "Artifacts G3", value: DiagnosticsFormat.reserved)
                        StatTile(label: "Dropped chunks", value: "\(droppedChunks ?? 0)")
                        StatTile(label: "STT errors", value: DiagnosticsFormat.reserved)
                    }
                    // The postmortem line survives the tile redesign: excluded
                    // (negative-latency) samples stay surfaced, never silently
                    // absorbed into the percentile counts.
                    Text(eventCounts(report))
                        .font(MachineType.number(9))
                        .foregroundStyle(DesignTokens.textTertiary)
                }
            } else {
                Text("No active meeting.")
                    .foregroundStyle(DesignTokens.textSecondary)
            }
        }
        .task { await pollLoop() }
    }

    private func eventCounts(_ report: LatencyReport) -> String {
        func side(_ label: String, _ stats: LatencyReport.Stats) -> String {
            let excluded = stats.excludedNegativeCount > 0 ? " (\(stats.excludedNegativeCount) excluded)" : ""
            return "\(label) \(stats.count) events\(excluded)"
        }
        return side("Volatile", report.volatile) + " · " + side("Final", report.final)
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            report = coordinator.currentRecorder?.report()
            memoryBytes = MemoryFootprint.currentBytes()
            droppedChunks = coordinator.currentDroppedChunks
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

/// Number formatting for the stat tiles — pure and pinned by test (check 12).
enum DiagnosticsFormat {
    /// Unwired tile placeholder.
    static let reserved = "—"

    /// Milliseconds with one decimal, per the mockup ("32.9", "85.4").
    static func ms(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Whole megabytes ("212").
    static func mb(_ bytes: UInt64) -> String {
        String(bytes / 1_048_576)
    }
}
