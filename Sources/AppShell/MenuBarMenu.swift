import AppKit
import SwiftUI

struct MenuBarMenu: View {
    let coordinator: AppShellCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(coordinator.session.isCapturing || coordinator.session.isPaused ? "Stop Meeting" : "Start Meeting") {
            coordinator.toggleSession()
        }
        .keyboardShortcut("m", modifiers: [.option, .command])

        if coordinator.session.isCapturing || coordinator.session.isPaused {
            Button(coordinator.session.isPaused ? "Resume Meeting" : "Pause Meeting") {
                coordinator.togglePause()
            }
            .keyboardShortcut("p", modifiers: [.option, .command])
        }

        // Applies to the *next* meeting only (slice-04 doc decision 9) —
        // disabled while a meeting is already running so it can't look like
        // it retroactively changes the one in progress.
        Toggle("Ephemeral Meeting", isOn: Bindable(coordinator).ephemeralNextMeeting)
            .disabled(coordinator.session.isCapturing || coordinator.session.isPaused)

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
