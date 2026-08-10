import AppKit
import SwiftUI

/// Menu bar dropdown — native menu furniture (system styling applies inside
/// NSMenu; Design tokens can't and shouldn't reach in here). Copy follows the
/// design's quiet-confident voice and sentence case; a disabled state line
/// heads the menu while a session runs.
struct MenuBarMenu: View {
    let coordinator: AppShellCoordinator
    @Environment(\.openWindow) private var openWindow

    private var sessionActive: Bool {
        coordinator.session.isCapturing || coordinator.session.isPaused
    }

    var body: some View {
        if sessionActive, let startedAt = coordinator.session.startedAt {
            // Snapshot at menu-open; menus don't tick.
            Text(
                "\(coordinator.session.isPaused ? "Paused" : "Capturing") · "
                    + ElapsedTimeFormat.string(
                        seconds: Int(Date().timeIntervalSince(startedAt)))
            )
            Divider()
        }

        Button(sessionActive ? "Stop meeting" : "Start meeting") {
            coordinator.toggleSession()
        }
        .keyboardShortcut("m", modifiers: [.option, .command])

        if sessionActive {
            Button(coordinator.session.isPaused ? "Resume capture" : "Pause capture") {
                coordinator.togglePause()
            }
            .keyboardShortcut("p", modifiers: [.option, .command])

            Button("Catch up") { coordinator.requestCatchUp() }
                .keyboardShortcut("c", modifiers: [.option, .command])
                .disabled(!coordinator.copilot.canCatchUp)

            Button("Ask") { coordinator.requestAsk() }
                .keyboardShortcut("k", modifiers: [.option, .command])
                .disabled(
                    coordinator.copilot.availability == .disabled
                        || coordinator.copilot.availability == .setupRequired
                )
        }

        // Applies to the *next* meeting only (slice-04 doc decision 9) —
        // disabled while a meeting is already running so it can't look like
        // it retroactively changes the one in progress.
        Toggle("Ephemeral meeting", isOn: Bindable(coordinator).ephemeralNextMeeting)
            .disabled(sessionActive)

        Divider()

        Button("History") {
            openWindow(id: WindowID.history)
        }
        .keyboardShortcut("y")

        SettingsLink()

        Divider()

        Button("Quit macapy") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
