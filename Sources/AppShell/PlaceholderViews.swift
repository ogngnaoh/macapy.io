import AgentKit
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
/// the recorder, memory footprint, G2/G3, and pipeline counters. Polls on a
/// short timer: capture-facing sources are plain lock-protected classes, not
/// `@Observable`, so polling surfaces fresh numbers without making capture
/// await an observation bridge.
struct DiagnosticsSectionView: View {
    let coordinator: AppShellCoordinator

    @State private var snapshot: AppShellCoordinator.DiagnosticsSnapshot?

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10, alignment: .topLeading), count: 3)

    var body: some View {
        Group {
            if let snapshot, snapshot.hasMeeting, let report = snapshot.speech {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    LazyVGrid(columns: Self.columns, spacing: 10) {
                        StatTile(
                            label: "Speech → visible p50",
                            value: DiagnosticsFormat.ms(report.volatile.p50Ms), unit: "ms")
                        StatTile(
                            label: "Speech → visible p95",
                            value: DiagnosticsFormat.ms(report.volatile.p95Ms), unit: "ms")
                        StatTile(
                            label: DiagnosticsFormat.suggestionP95Label,
                            value: snapshot.suggestion.count > 0
                                ? DiagnosticsFormat.ms(snapshot.suggestion.p95Ms)
                                : DiagnosticsFormat.reserved,
                            unit: snapshot.suggestion.count > 0 ? "ms" : nil)
                        StatTile(
                            label: "Memory",
                            value: snapshot.memoryBytes.map(DiagnosticsFormat.mb)
                                ?? DiagnosticsFormat.reserved,
                            unit: snapshot.memoryBytes != nil ? "MB" : nil)
                        StatTile(
                            label: "Artifacts G3",
                            value: snapshot.artifactG3Seconds.map(DiagnosticsFormat.seconds)
                                ?? DiagnosticsFormat.reserved,
                            unit: snapshot.artifactG3Seconds != nil ? "s" : nil)
                        StatTile(label: "Dropped chunks", value: "\(snapshot.droppedChunks)")
                        StatTile(label: "STT errors", value: "\(snapshot.sttErrorCount)")
                    }
                    // The postmortem line survives the tile redesign: excluded
                    // (negative-latency) samples stay surfaced, never silently
                    // absorbed into the percentile counts.
                    Text(eventCounts(report))
                        .font(MachineType.number(9))
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text(suggestionCounts(snapshot.suggestion))
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

    private func suggestionCounts(_ report: SuggestionLatencyRecorder.Report) -> String {
        let excluded = report.excludedNegativeCount > 0
            ? " (\(report.excludedNegativeCount) excluded)"
            : ""
        return "Suggestions \(report.count) events\(excluded) · \(report.cancelledCount) cancelled"
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
            snapshot = await coordinator.diagnosticsSnapshot()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

/// Number formatting for the stat tiles — pure and pinned by test (check 12).
enum DiagnosticsFormat {
    /// Unwired tile placeholder.
    static let reserved = "—"
    static let suggestionP95Label = "Suggestion p95"

    /// Milliseconds with one decimal, per the mockup ("32.9", "85.4").
    static func ms(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Whole megabytes ("212").
    static func mb(_ bytes: UInt64) -> String {
        String(bytes / 1_048_576)
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
