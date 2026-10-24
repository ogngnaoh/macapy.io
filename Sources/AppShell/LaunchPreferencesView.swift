import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LaunchPreferencesView: View {
    let model: LaunchPreferencesModel
    let shortcuts: ShortcutPreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            SectionHead(title: "startup")
            Toggle("launch macapy at login", isOn: Binding(
                get: { model.isEnabled },
                set: { value in Task { await model.setEnabled(value) } }
            ))
            .toggleStyle(.checkbox)
            .font(UIType.body)
            .disabled(model.isChanging || model.status == .unavailable)
            FormNote("opens the menu-bar app when you sign in. Capture starts only when you start a meeting.")
            if model.status == .requiresApproval {
                FormNote("macOS needs your approval in Login Items before launch at login is enabled.")
            } else if model.status == .unavailable {
                FormNote("launch at login is unavailable for this installation. Use a packaged macapy app and reopen settings.")
            }
            if let message = model.message {
                Text(message).font(UIType.small).foregroundStyle(DesignTokens.statusWarning)
            }
            if model.status == .requiresApproval || model.message != nil {
                Button("open Login Items") { model.openSystemSettings() }.buttonStyle(SubtleButtonStyle())
            }
            Divider()
            SectionHead(title: "global shortcuts")
            FormNote("choose a letter and modifiers. Conflicts leave working shortcuts unchanged. Letters use physical US keyboard positions.")
            ForEach(ShortcutAction.allCases) { action in
                HStack {
                    Text(action.title.lowercased()).font(UIType.body).frame(maxWidth: .infinity, alignment: .leading)
                    Picker("modifiers for \(action.title)", selection: Binding(
                        get: { shortcuts.binding(for: action).modifiers },
                        set: { value in
                            var binding = shortcuts.binding(for: action)
                            binding.modifiers = value
                            shortcuts.set(action, binding: binding)
                        }
                    )) {
                        ForEach(ShortcutModifiers.allCases) { Text($0.display).tag($0) }
                    }
                    .labelsHidden().frame(width: 100)
                    Picker("key for \(action.title)", selection: Binding(
                        get: { shortcuts.binding(for: action).letter },
                        set: { value in
                            var binding = shortcuts.binding(for: action)
                            binding.letter = value
                            shortcuts.set(action, binding: binding)
                        }
                    )) {
                        ForEach(ShortcutBinding.letters, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 65)
                }
            }
            if let message = shortcuts.message {
                Text(message).font(UIType.small).foregroundStyle(DesignTokens.statusWarning)
            }
            Button("reset shortcuts") { shortcuts.reset() }.buttonStyle(SubtleButtonStyle())
        }
        .foregroundStyle(DesignTokens.text)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }
}

struct SanitizedDiagnosticsExportView: View {
    let model: SanitizedDiagnosticsExportModel
    @State private var showingReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            SectionHead(title: "diagnostic report")
            FormNote("counters and app/macOS versions only. No meeting text, request bodies, credentials, file paths, or identifiers. Nothing is uploaded.")
            Button("review diagnostic report…") { showingReport = true }
                .buttonStyle(SubtleButtonStyle())
        }
        .sheet(isPresented: $showingReport) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                Text("diagnostic report").font(UIType.heading)
                Text("review the complete JSON before saving a local copy.").font(UIType.compactReading)
                if let report = model.report {
                    ScrollView {
                        Text(String(decoding: report, as: UTF8.self))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(DesignTokens.Space.s3)
                    .background(DesignTokens.sunken)
                    .overlay(Rectangle().stroke(DesignTokens.hairlineStrong))
                } else if model.isPreparing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let message = model.message { Text(message).font(UIType.small) }
                HStack {
                    Spacer()
                    Button("close") { showingReport = false }.keyboardShortcut(.cancelAction)
                        .buttonStyle(SubtleButtonStyle())
                    Button("save JSON…", action: save).disabled(model.report == nil)
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            .foregroundStyle(DesignTokens.text)
            .padding(DesignTokens.Space.s5)
            .frame(width: 580, height: 550)
            .background(DesignTokens.surface)
            .task { await model.prepare() }
            .onDisappear { model.clear() }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "macapy-diagnostics.json"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.save(to: url) }
    }
}
