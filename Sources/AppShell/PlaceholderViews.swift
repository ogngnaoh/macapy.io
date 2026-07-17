import SwiftUI

// HistoryPlaceholderView is gone — HistoryView.swift (slice 4) is the real
// past-meetings list + read-only transcript detail.

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
