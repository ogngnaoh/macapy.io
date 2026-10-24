import AppKit
import SwiftUI

/// A permission-first setup surface. Merely opening it reads local readiness;
/// microphone access and speech downloads each require their own action.
struct SetupView: View {
    let coordinator: AppShellCoordinator
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var installTask: Task<Void, Never>?
    @State private var preferredName = ""
    @FocusState private var nameFocused: Bool

    private var model: OnboardingModel { coordinator.setup }
    private var blocked: Bool { model.activity.sessionActive || model.activity.isBusy }

    var body: some View {
        VStack(spacing: 0) {
            masthead
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s5) {
                    setupSection("audio sources") {
                        Picker("audio sources", selection: Bindable(model).captureMode) {
                            ForEach(CaptureMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .disabled(coordinator.session.isActive)
                        Text("system audio includes everything playing on this Mac. macapy never joins a call or stores audio.")
                            .font(UIType.small)
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                    setupSection("microphone") {
                        HStack(spacing: DesignTokens.Space.s3) {
                            Chip(text: microphoneLabel, style: model.microphone == .allowed ? .approved : .quiet)
                            if model.microphone == .unknown {
                                Button("allow microphone") { Task { await model.requestMicrophone() } }
                                    .buttonStyle(PrimaryButtonStyle())
                                    .disabled(coordinator.session.isActive)
                            } else if model.microphone == .denied {
                                Button("open System Settings") { openMicrophoneSettings() }
                                    .buttonStyle(SubtleButtonStyle())
                            }
                        }
                        Text("the microphone is used only after you start a meeting. Reopen setup to check any permission changes.")
                            .font(UIType.small)
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                    setupSection("local transcription") {
                        HStack(spacing: DesignTokens.Space.s3) {
                            Chip(text: model.speechReady ? "installed · English (US)" : "English (US)",
                                 style: model.speechReady ? .approved : .quiet)
                            if model.isInstalling {
                                ProgressView().controlSize(.small)
                                Button("cancel") { installTask?.cancel() }
                                    .buttonStyle(SubtleButtonStyle())
                            } else if !model.speechReady {
                                Button("install speech support") {
                                    installTask = Task { await model.installSpeech() }
                                }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(blocked)
                            }
                        }
                        Text("downloads speech support from Apple during setup. Once installed, transcription runs on this Mac without a network connection.")
                            .font(UIType.small)
                            .foregroundStyle(DesignTokens.textSecondary)
                        if let message = model.installationMessage {
                            Text(message)
                                .font(UIType.small)
                                .foregroundStyle(DesignTokens.statusWarning)
                                .accessibilityLabel(message)
                        }
                    }
                    setupSection("your name · optional") {
                        TextField("name used in meetings", text: $preferredName)
                            .textFieldStyle(.plain)
                            .padding(DesignTokens.Space.s2)
                            .background(DesignTokens.sunken)
                            .overlay(Rectangle().stroke(nameFocused ? DesignTokens.accent : DesignTokens.hairlineStrong))
                            .focused($nameFocused)
                            .accessibilityLabel("preferred name, optional")
                        Text("helps the optional copilot recognize questions addressed to you. Change it anytime in settings.")
                            .font(UIType.small)
                            .foregroundStyle(DesignTokens.textSecondary)
                        HStack(alignment: .top, spacing: DesignTokens.Space.s3) {
                            Text("AI is optional. Transcription and history need no key. Enabling AI sends meeting text to your configured provider; audio stays on this Mac.")
                                .font(UIType.small)
                                .foregroundStyle(DesignTokens.textSecondary)
                            Button("AI settings") { openSettings() }
                                .buttonStyle(SubtleButtonStyle())
                                .fixedSize()
                        }
                    }
                }
                .padding(DesignTokens.Space.s5)
            }
            footer
        }
        .frame(width: 660, height: 700)
        .background(DesignTokens.bg)
        .task {
            await model.refresh()
            let ai = coordinator.liveAISettingsModel()
            await ai.load()
            preferredName = ai.settings.preferredName ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .onDisappear { installTask?.cancel() }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text("setup").font(UIType.title)
            Text("choose your audio, then prepare local speech.")
                .font(UIType.compactReading)
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .foregroundStyle(DesignTokens.text)
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairlineStrong).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.canFinish ? "ready for a meeting" : "finish the required steps above")
                    .font(UIType.bodySemibold)
                Text(coordinator.session.isActive
                     ? "finish the current meeting before changing setup."
                     : "start a meeting from the menu bar.")
                    .font(UIType.small)
                    .foregroundStyle(DesignTokens.textSecondary)
                Button("explore a sample meeting") { openWindow(id: WindowID.sample) }
                    .buttonStyle(.plain)
                    .font(UIType.small)
                    .foregroundStyle(DesignTokens.accent)
            }
            Spacer()
            Button(model.isComplete ? "done" : "finish setup") {
                Task {
                    await coordinator.liveAISettingsModel().setPreferredName(preferredName)
                    if model.finish() { dismissWindow(id: WindowID.setup) }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canFinish || model.activity.sessionActive)
            .keyboardShortcut(.defaultAction)
        }
        .padding(DesignTokens.Space.s4)
        .overlay(alignment: .top) { Rectangle().fill(DesignTokens.hairlineStrong).frame(height: 1) }
    }

    private var microphoneLabel: String {
        switch model.microphone {
        case .unknown: "permission needed"
        case .allowed: "allowed"
        case .denied: "access denied"
        }
    }

    private func setupSection<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text(title).font(UIType.heading).foregroundStyle(DesignTokens.text)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension Notification.Name {
    static let macapyOpenSetup = Notification.Name("io.macapy.app.openSetup")
}
