import Foundation
import os

/// App-lifetime owner of the shell's moving parts. All session mutations flow
/// through here so panel visibility stays in lockstep with session state.
@MainActor
final class AppShellCoordinator {
    let session = SessionController()
    let activationPolicy = ActivationPolicyController()
    private let panel = FloatingPanelController()
    private var hotKey: HotKey?
    private let log = Logger(subsystem: "io.macapy.app", category: "AppShell")

    init() {
        hotKey = HotKey.startStopMeeting { [weak self] in
            self?.toggleSession()
        }
    }

    func toggleSession() {
        session.toggle()
        syncPanel()
    }

    private func syncPanel() {
        if session.isCapturing {
            log.info("session started")
            panel.show(session: session)
        } else {
            log.info("session stopped")
            panel.hide()
        }
    }
}
