import SwiftUI

/// The app's entire scene graph; the app target's `App` body is just this.
/// Menu bar extra is always present; the history and settings windows are
/// regular windows that flip the activation policy while open. No window
/// opens at launch (accessory app).
@MainActor
public struct AppShellScenes: Scene {
    @State private var coordinator = AppShellCoordinator()

    public init() {}

    public var body: some Scene {
        MenuBarExtra("macapy", systemImage: "waveform") {
            MenuBarMenu(coordinator: coordinator)
        }

        Window("History", id: WindowID.history) {
            Group {
                if let store = coordinator.historyStore() {
                    HistoryView(store: store)
                } else {
                    ContentUnavailableView(
                        "History Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Couldn't open the meeting database.")
                    )
                    .frame(minWidth: 480, minHeight: 320)
                }
            }
            .regularWindowPresence(coordinator.activationPolicy)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsPlaceholderView()
                .regularWindowPresence(coordinator.activationPolicy)
        }
    }
}

enum WindowID {
    static let history = "history"
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
