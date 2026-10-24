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
        coordinator.session.isActive
    }

    var body: some View {
        if coordinator.session.isPreparing {
            Text("preparing · capture has not started")
            Divider()
        } else if sessionActive, let startedAt = coordinator.session.startedAt {
            // Snapshot at menu-open; menus don't tick.
            Text(
                "\(coordinator.session.isPaused ? "paused" : "capturing") · "
                    + ElapsedTimeFormat.string(
                        seconds: Int(Date().timeIntervalSince(startedAt)))
            )
            Divider()
        }

        Button(sessionActive ? "stop meeting" : "start meeting") {
            if !sessionActive && !coordinator.setup.isComplete {
                openWindow(id: WindowID.setup)
            } else {
                coordinator.toggleSession()
            }
        }
        .keyboardShortcut(coordinator.shortcuts.binding(for: .startStop).keyEquivalent, modifiers: coordinator.shortcuts.binding(for: .startStop).eventModifiers)
        .disabled(coordinator.terminationInProgress || coordinator.contentDeletionInProgress || (!sessionActive && coordinator.setup.activity.isBusy))

        if sessionActive {
            Button(coordinator.session.isPaused ? "resume capture" : "pause capture") {
                coordinator.togglePause()
            }
            .keyboardShortcut(coordinator.shortcuts.binding(for: .pauseResume).keyEquivalent, modifiers: coordinator.shortcuts.binding(for: .pauseResume).eventModifiers)
            .disabled(coordinator.session.isPreparing)

            Button("catch up") { coordinator.requestCatchUp() }
                .keyboardShortcut(coordinator.shortcuts.binding(for: .catchUp).keyEquivalent, modifiers: coordinator.shortcuts.binding(for: .catchUp).eventModifiers)
                .disabled(!coordinator.copilot.canCatchUp)

            Button("ask") { coordinator.requestAsk() }
                .keyboardShortcut(coordinator.shortcuts.binding(for: .ask).keyEquivalent, modifiers: coordinator.shortcuts.binding(for: .ask).eventModifiers)
                .disabled(!coordinator.copilot.canAsk)

            Button("dismiss copilot") { coordinator.requestDismissCopilot() }
                .keyboardShortcut(coordinator.shortcuts.binding(for: .dismiss).keyEquivalent, modifiers: coordinator.shortcuts.binding(for: .dismiss).eventModifiers)
                .disabled(!coordinator.copilot.canDismiss)
        }

        // Applies to the *next* meeting only (slice-04 doc decision 9) —
        // disabled while a meeting is already running so it can't look like
        // it retroactively changes the one in progress.
        Toggle("ephemeral meeting", isOn: Bindable(coordinator).ephemeralNextMeeting)
            .disabled(sessionActive)

        Divider()

        Button("history") {
            openWindow(id: WindowID.history)
        }
        .keyboardShortcut("y")

        Button("sample meeting") { openWindow(id: WindowID.sample) }
        Button("memory & documents") { openWindow(id: WindowID.memory) }
        Button("pre-meeting briefs") { openWindow(id: WindowID.briefs) }

        Button("setup…") { openWindow(id: WindowID.setup) }

        Button("outgoing ai text…") { openWindow(id: WindowID.requests) }

        SettingsLink()

        Divider()

        Button("quit macapy") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
