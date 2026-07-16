import SwiftUI

/// Verification surface only — the real past-meetings list arrives with
/// persistence in slice 4.
struct HistoryPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "No meetings yet",
            systemImage: "clock",
            description: Text("Past meetings will appear here once persistence lands (slice 4).")
        )
        .frame(minWidth: 480, minHeight: 320)
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        Form {
            Text("Settings arrive with the provider layer (M2).")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 160)
    }
}
