import AppKit
import SwiftUI

struct MenuBarMenu: View {
    let coordinator: AppShellCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(coordinator.session.isCapturing ? "Stop Meeting" : "Start Meeting") {
            coordinator.toggleSession()
        }
        .keyboardShortcut("m", modifiers: [.option, .command])

        Divider()

        Button("Open History") {
            openWindow(id: WindowID.history)
        }

        SettingsLink()

        Divider()

        Button("Quit macapy") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
