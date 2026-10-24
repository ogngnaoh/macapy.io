import AppKit
import SwiftUI

/// The app's entire scene graph; the app target's `App` body is just this.
/// Menu bar extra is always present; the history and settings windows are
/// regular windows that flip the activation policy while open. No window
/// opens at launch after setup has been completed.
@MainActor
public struct AppShellScenes: Scene {
    private static let sampleLaunch = ProcessInfo.processInfo.arguments.contains("--sample")
    // Lazy, app-lifetime ownership also keeps the delegate and State aligned
    // if SwiftUI reconstructs the Scene value. Sample never reads this value.
    private static let productionOwner = AppShellCoordinator(
        makeDatabase: AppShellCoordinator.productionDatabase,
        storagePreflight: { try await MeetingStoragePreflight.production() })
    @State private var coordinator: AppShellCoordinator?
    @State private var sampleActivation = ActivationPolicyController()

    public init() {
        // --sample never constructs production capture, credentials, storage,
        // hotkeys or setup. The sample scene has its own isolated composition.
        let owner = Self.sampleLaunch ? nil : Self.productionOwner
        _coordinator = State(initialValue: owner)
        MacapyApplicationDelegate.lifecycle = owner?.applicationLifecycle()
    }

    public var body: some Scene {
        // Brand mark variant A ("cluster") as a monochrome template glyph —
        // it stays template in every session state (slice-01 decision; the
        // panel itself is the capture indicator).
        MenuBarExtra {
            if let coordinator { MenuBarMenu(coordinator: coordinator) }
            else { SampleMenu() }
        } label: {
            MenuBarLabel()
        }

        Window("history", id: WindowID.history) {
            Group {
                if let coordinator, let model = coordinator.historySearchModel(),
                   let store = coordinator.historyStore() {
                    HistoryView(
                        model: model,
                        store: store,
                        makeDetailModel: { coordinator.meetingDetailModel(for: $0) }
                    )
                } else {
                    EmptyStateView(
                        title: "history unavailable",
                        message: "couldn't open the meeting database."
                    )
                    .frame(minWidth: 480, minHeight: 320)
                }
            }
            .regularWindowPresence(coordinator?.activationPolicy ?? sampleActivation)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("set up macapy", id: WindowID.setup) {
            Group {
                if let coordinator { SetupView(coordinator: coordinator) }
            }
            .regularWindowPresence(coordinator?.activationPolicy ?? sampleActivation)
        }
        .defaultLaunchBehavior(coordinator?.setup.isComplete == false ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        Window("macapy — sample", id: WindowID.sample) {
            SampleView()
                .regularWindowPresence(coordinator?.activationPolicy ?? sampleActivation)
        }
        .defaultLaunchBehavior(Self.sampleLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 1200, height: 760)

        Window("outgoing ai text", id: WindowID.requests) {
            Group {
                if let coordinator {
                    RequestInspectorView(inspector: coordinator.requestInspector, isStandalone: true)
                }
            }
            .regularWindowPresence(coordinator?.activationPolicy ?? sampleActivation)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 900, height: 650)

        Window("memory & documents", id: WindowID.memory) {
            Group {
                if let model = coordinator?.memoryWorkspaceModel() { MemoryWorkspaceView(model: model) }
                else { EmptyStateView(title: "memory unavailable", message: "open a saved local meeting to use memory and documents.") }
            }.regularWindowPresence(coordinator?.activationPolicy ?? sampleActivation)
        }
        .defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)
        .defaultSize(width: 1120, height: 760)

        Window("pre-meeting briefs", id: WindowID.briefs) {
            Group {
                if let model = coordinator?.briefWorkspaceModel() { BriefWorkspaceView(model: model) }
                else { EmptyStateView(title: "briefs unavailable", message: "the local database could not be opened.") }
            }.regularWindowPresence(coordinator?.activationPolicy ?? sampleActivation)
        }
        .defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)
        .defaultSize(width: 1060, height: 740)

        Settings {
            Group {
                if let coordinator { SettingsWindowView(coordinator: coordinator) }
                else { Text("settings are unavailable in the isolated sample.").padding(30) }
            }
            .regularWindowPresence(coordinator?.activationPolicy ?? sampleActivation)
        }
    }
}

enum WindowID {
    static let history = "history"
    static let setup = "setup"
    static let sample = "sample"
    static let requests = "outgoing-ai-text"
    static let memory = "memory"
    static let briefs = "briefs"
}

/// Flips the activation policy while the attached window's content is visible.
private struct RegularWindowPresence: ViewModifier {
    let policy: ActivationPolicyController

    func body(content: Content) -> some View {
        content
            .onAppear { policy.regularWindowAppeared() }
            .onDisappear { policy.regularWindowDisappeared() }
    }
}

extension View {
    func regularWindowPresence(_ policy: ActivationPolicyController) -> some View {
        modifier(RegularWindowPresence(policy: policy))
    }
}

/// The menu bar label stays mounted while its menu is closed, so floating
/// AppKit panels can route setup without relying on an expanded menu.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: SignalMark.menuBarImage)
            .onReceive(NotificationCenter.default.publisher(for: .macapyOpenSetup)) { _ in
                openWindow(id: WindowID.setup)
            }
    }
}

private struct SampleMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("sample mode · scripted ai")
        Button("open sample") { openWindow(id: WindowID.sample) }
        Divider()
        Button("quit macapy") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
