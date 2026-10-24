import SwiftUI

struct ResetPreferencesView: View {
    let makeModel: @MainActor () -> ResetPreferencesModel
    @State private var model: ResetPreferencesModel?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text("reset preferences").font(UIType.bodySemibold)
            Text("after deleting meeting data, separately reset settings, API keys, shortcuts, launch at login, and local budget counters.")
                .font(UIType.compactReading)
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("review preferences reset…") { model = makeModel() }
                .buttonStyle(SubtleButtonStyle())
        }
        .sheet(item: $model) { presented in
            ResetPreferencesSheet(model: presented, onDismiss: { model = nil })
        }
    }
}

struct ResetPreferencesSheet: View {
    @Bindable var model: ResetPreferencesModel
    let onDismiss: () -> Void
    @FocusState private var entryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            Text("reset preferences")
                .font(UIType.heading)
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                    explanation("delete meeting data first", "use ‘delete all meeting data’ before this reset. This action does not delete meeting content for you.")
                    explanation("cleared", "provider and app settings, saved API keys, setup preferences, shortcuts, and anonymous local budget counters. Launch at login is turned off.")
                    explanation("kept", "installed shared speech and speaker models, macOS permissions, exported files, and existing Calendar or Reminders items.")
                    Text(ResetPreferencesModel.accountingDisclosure)
                        .font(UIType.compactReading)
                        .lineSpacing(3)
                        .foregroundStyle(DesignTokens.statusWarning)
                        .padding(DesignTokens.Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DesignTokens.statusWarningSurface)
                    if let message = model.message {
                        Text(message)
                            .font(UIType.compactReading)
                            .lineSpacing(3)
                            .foregroundStyle(model.didComplete ? DesignTokens.text : DesignTokens.statusRejected)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("reset-preferences-result")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.didComplete {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    Text("type RESET to confirm.").font(UIType.compactReading)
                    TextField("RESET", text: $model.entry)
                        .textFieldStyle(.plain)
                        .font(MachineType.number(13))
                        .padding(DesignTokens.Space.s3)
                        .background(DesignTokens.sunken)
                        .overlay(Rectangle().stroke(entryFocused ? DesignTokens.accent : DesignTokens.hairlineStrong))
                        .disabled(model.isResetting)
                        .focused($entryFocused)
                        .accessibilityLabel("type RESET to confirm preferences reset")
                        .onSubmit { Task { await model.confirm() } }
                }
            }
            HStack(spacing: DesignTokens.Space.s3) {
                Spacer()
                if model.didComplete {
                    Button("done", action: onDismiss)
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("cancel", action: onDismiss)
                        .buttonStyle(SubtleButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isResetting)
                    Button(model.isResetting ? "resetting…" : "reset preferences") {
                        Task { await model.confirm() }
                    }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(!model.canReset)
                }
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 560, height: 620)
        .foregroundStyle(DesignTokens.text)
        .background(DesignTokens.surface)
        .interactiveDismissDisabled(model.isResetting)
        .onAppear { entryFocused = true }
    }

    private func explanation(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(text)
                .font(UIType.compactReading)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
